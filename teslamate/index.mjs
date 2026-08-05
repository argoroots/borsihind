import fs from 'node:fs'
import path from 'node:path'
import pg from 'pg'

const PLANS = ['V1', 'V2', 'V4', 'V5']
const KEEP_MS = 48 * 60 * 60 * 1000

const VORK = process.env.VORK ?? 'V1'
const MARGINAL = parseFloat(process.env.MARGINAL ?? '0')
const INTERVAL = process.env.INTERVAL === '15min' ? '15min' : '1h'
const GEOFENCE_ID = parseInt(process.env.GEOFENCE_ID)
const DATA_DIR = process.env.DATA_DIR ?? './data'

const SLOT_MS = (INTERVAL === '15min' ? 15 : 60) * 60 * 1000
const PRICES_FILE = path.join(DATA_DIR, 'prices.json')

if (!PLANS.includes(VORK)) {
  console.error(`VORK must be one of: ${PLANS.join(', ')}`)
  process.exit(1)
}

if (!Number.isInteger(GEOFENCE_ID)) {
  console.error('GEOFENCE_ID environment variable is required')
  process.exit(1)
}

const pool = new pg.Pool(
  process.env.DATABASE_URL
    ? { connectionString: process.env.DATABASE_URL }
    : {
        host: process.env.DATABASE_HOST ?? 'database',
        port: parseInt(process.env.DATABASE_PORT ?? '5432'),
        user: process.env.DATABASE_USER ?? 'teslamate',
        password: process.env.DATABASE_PASS,
        database: process.env.DATABASE_NAME ?? 'teslamate'
      }
)

let prices = {}

function loadPrices () {
  fs.mkdirSync(DATA_DIR, { recursive: true })

  try {
    const loaded = JSON.parse(fs.readFileSync(PRICES_FILE, 'utf8'))

    // Cached slots are only valid for the same interval and plan
    if (loaded.interval === INTERVAL && loaded.plan === VORK) {
      prices = loaded.prices
    }
  } catch {}
}

function savePrices () {
  fs.writeFileSync(PRICES_FILE, JSON.stringify({ interval: INTERVAL, plan: VORK, prices }))
}

const tallinnFormat = new Intl.DateTimeFormat('en-US', {
  timeZone: 'Europe/Tallinn',
  year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', second: '2-digit',
  hour12: false
})

function tallinnOffset (epochMs) {
  const parts = Object.fromEntries(tallinnFormat.formatToParts(epochMs).map((p) => [p.type, p.value]))

  return Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour % 24, parts.minute, parts.second) - epochMs
}

// Convert Europe/Tallinn wall-clock components to a UTC epoch (ms)
function tallinnToUtc (year, month, day, hour, minute) {
  let guess = Date.UTC(year, month - 1, day, hour, minute)

  for (let i = 0; i < 2; i++) {
    guess = Date.UTC(year, month - 1, day, hour, minute) - tallinnOffset(guess)
  }

  return guess
}

async function fetchPrices () {
  const suffix = INTERVAL === '15min' ? '15min/' : ''
  const response = await fetch(`https://borsihind.s3.eu-central-1.amazonaws.com/${suffix}${VORK}.json`)

  if (!response.ok) throw new Error(`Price API returned ${response.status}`)

  const rows = await response.json()
  const cutoff = Date.now() - KEEP_MS

  for (const x of rows) {
    const ts = tallinnToUtc(x.at(0), x.at(1), x.at(2), x.at(3), x.at(4))
    // electricity + grid + renewable tax + excise + supply security fee
    prices[ts] = Math.round((x.at(5) + x.at(6) + x.at(7) + x.at(8) + x.at(9)) * 10000) / 10000
  }

  for (const ts of Object.keys(prices)) {
    if (Number(ts) < cutoff) delete prices[ts]
  }

  savePrices()
}

async function processFinishedCharges () {
  const { rows: sessions } = await pool.query(`
    SELECT id, charge_energy_added, charge_energy_used
    FROM charging_processes
    WHERE geofence_id = $1 AND cost IS NULL AND end_date IS NOT NULL
      AND end_date > (NOW() AT TIME ZONE 'UTC') - INTERVAL '48 hours'
    ORDER BY end_date
  `, [GEOFENCE_ID])

  for (const session of sessions) {
    const result = await calculateCost(session)
    if (result === null) continue

    await pool.query(
      'UPDATE charging_processes SET cost = $1 WHERE id = $2',
      [result.cost, session.id]
    )

    console.log(`Charge ${session.id}: ${result.billable.toFixed(2)} kWh over ${result.slots} slots = ${result.cost.toFixed(2)} EUR`)
  }
}

async function calculateCost (session) {
  const { rows: samples } = await pool.query(`
    SELECT EXTRACT(EPOCH FROM date) * 1000 AS ts, charge_energy_added
    FROM charges
    WHERE charging_process_id = $1 AND charge_energy_added IS NOT NULL
    ORDER BY date
  `, [session.id])

  if (samples.length < 2) {
    console.error(`Charge ${session.id}: not enough samples, skipping`)
    return null
  }

  // Sum energy per price slot from the deltas between consecutive samples
  const slotEnergy = {}
  let total = 0

  for (let i = 1; i < samples.length; i++) {
    const delta = Math.max(0, samples[i].charge_energy_added - samples[i - 1].charge_energy_added)
    if (delta === 0) continue

    const slot = Math.floor(Number(samples[i].ts) / SLOT_MS) * SLOT_MS
    slotEnergy[slot] = (slotEnergy[slot] ?? 0) + delta
    total += delta
  }

  if (total === 0) return { cost: 0, billable: 0, slots: 0 }

  // Scale so the distributed energy matches what TeslaMate bills
  // (charge_energy_used includes charging losses)
  const billable = parseFloat(session.charge_energy_used) || parseFloat(session.charge_energy_added) || total
  const scale = billable / total

  let cost = 0

  for (const [slot, energy] of Object.entries(slotEnergy)) {
    const price = prices[slot]

    if (price === undefined) {
      console.error(`Charge ${session.id}: no price for slot ${new Date(Number(slot)).toISOString()}, will retry`)
      return null
    }

    cost += energy * scale * (price + MARGINAL)
  }

  return {
    cost: Math.round(cost * 100) / 100,
    billable,
    slots: Object.keys(slotEnergy).length
  }
}

function msUntilNextInterval () {
  const now = new Date()
  const minutes = INTERVAL === '15min' ? 15 : 60
  const next = new Date(now)
  next.setMinutes(Math.floor(now.getMinutes() / minutes) * minutes + minutes, 5, 0)

  return next - now
}

async function priceTick () {
  try {
    await fetchPrices()
  } catch (error) {
    console.error('Price fetch failed:', error.message)
  }

  setTimeout(priceTick, msUntilNextInterval())
}

async function chargeTick () {
  try {
    await processFinishedCharges()
  } catch (error) {
    console.error('Charge processing failed:', error.message)
  }

  setTimeout(chargeTick, 5 * 60 * 1000)
}

loadPrices()
console.log(`Starting: geofence ${GEOFENCE_ID}, plan ${VORK}, interval ${INTERVAL}, ${Object.keys(prices).length} cached prices`)
await priceTick()
await chargeTick()
