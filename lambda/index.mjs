import { S3Client, PutObjectCommand, PutObjectAclCommand, PutObjectTaggingCommand } from '@aws-sdk/client-s3'

const S3_REGION = 'eu-central-1'
const S3_BUCKET = 'borsihind'
const S3_TAG = { Key: 'Project', Value: 'borsihind' }

const NORDPOOL_URL = 'https://dataportal-api.nordpoolgroup.com/api/DayAheadPrices?currency=EUR&market=DayAhead&deliveryArea=EE&date='
const TIME_ZONE = 'Europe/Tallinn'

const PLANS = ['V1', 'V2', 'V4', 'V5']

// VAT added to the Nord Pool price (fees below already include VAT)
const VAT_RATE = 0.24

// State fees, EUR/kWh with VAT
const RENEWABLE_FEE = 0.0104
const EXCISE = 0.0026
const SUPPLY_SECURITY_FEE = 0.0094

// Elektrilevi grid fees, EUR/kWh with VAT
const GRID_FEES = {
  V1: {
    price: 0.0957
  },
  V2: {
    day: 0.0753,
    night: 0.0435
  },
  V4: {
    day: 0.0458,
    night: 0.0260
  },
  V5: {
    day: 0.0656,
    dayTop: 0.1014,
    night: 0.0376,
    nightTop: 0.0588
  }
}

// Day tariff hours on working days: 7:00–22:00
const DAY_START_HOUR = 7
const DAY_END_HOUR = 22

// V5 peak prices apply only November–March (0-based months)
const V5_PEAK_MONTHS = [10, 11, 0, 1, 2]
const V5_DAY_PEAK_HOURS = [9, 10, 11, 16, 17, 18, 19]
const V5_OFF_DAY_PEAK_HOURS = [16, 17, 18, 19]

// Estonian public holidays, charged at night/off-day rates
const HOLIDAYS = ['2025-12-24', '2025-12-25', '2025-12-26', '2026-01-01', '2026-02-24', '2026-04-03', '2026-04-05', '2026-05-01', '2026-05-24', '2026-06-23', '2026-06-24', '2026-08-20', '2026-12-24', '2026-12-25', '2026-12-26', '2027-01-01', '2027-02-24', '2027-03-26', '2027-03-28', '2027-05-01', '2027-05-16', '2027-06-23', '2027-06-24', '2027-08-20', '2027-12-24', '2027-12-25', '2027-12-26']

async function getPrices () {
  const start = new Date()
  const currentDate = start.toISOString().substring(0, 10)
  const nextDate = new Date(start)
  nextDate.setDate(nextDate.getDate() + 1)
  const nextDateStr = nextDate.toISOString().substring(0, 10)

  const allEntries = []

  // Make request for current day
  try {
    const currentResponse = await fetch(`${NORDPOOL_URL}${currentDate}`)
    const currentData = await currentResponse.json()

    if (currentData?.multiAreaEntries) {
      allEntries.push(...currentData.multiAreaEntries)
    }
  } catch (error) {
    console.error('Error fetching prices for current day:', error)
  }

  // Make request for next day
  try {
    const nextResponse = await fetch(`${NORDPOOL_URL}${nextDateStr}`)
    const nextData = await nextResponse.json()

    if (nextData?.multiAreaEntries) {
      allEntries.push(...nextData.multiAreaEntries)
    }
  } catch (error) {
    console.error('Error fetching prices for next day')
  }

  return allEntries
}

// Drop slots that ended before the current slot of the given length
function filterPast (prices, slotMinutes) {
  const now = new Date()
  const roundedMinutes = Math.floor(now.getMinutes() / slotMinutes) * slotMinutes
  const currentSlot = new Date(now.getFullYear(), now.getMonth(), now.getDate(), now.getHours(), roundedMinutes)
  return prices.filter(entry => new Date(entry.deliveryStart) >= currentSlot)
}

function aggregateToHourly (prices) {
  const hourlyMap = new Map()

  prices.forEach(p => {
    const dt = new Date(p.deliveryStart)
    const hourKey = `${dt.getFullYear()}-${dt.getMonth()}-${dt.getDate()}-${dt.getHours()}`

    if (!hourlyMap.has(hourKey)) {
      hourlyMap.set(hourKey, { entries: [], deliveryStart: new Date(dt.getFullYear(), dt.getMonth(), dt.getDate(), dt.getHours(), 0) })
    }
    hourlyMap.get(hourKey).entries.push(p)
  })

  const hourlyPrices = []
  hourlyMap.forEach(({ entries, deliveryStart }) => {
    const avgPrice = entries.reduce((sum, e) => sum + e.entryPerArea.EE, 0) / entries.length
    hourlyPrices.push({
      deliveryStart: deliveryStart.toISOString(),
      entryPerArea: { EE: avgPrice }
    })
  })

  return hourlyPrices.sort((a, b) => new Date(a.deliveryStart) - new Date(b.deliveryStart))
}

function changeTimeZone (date, timeZone) {
  if (typeof date === 'string') {
    return new Date(
      new Date(date).toLocaleString('en-US', {
        timeZone
      })
    )
  }

  return new Date(
    date.toLocaleString('en-US', {
      timeZone
    })
  )
}

// Grid fee, EUR/kWh with VAT
function getGridFee (date, service = 'V4') {
  const day = date.getDay()
  const hours = date.getHours()
  const today = date.toISOString().substring(0, 10)
  const isOffDay = HOLIDAYS.includes(today) || day === 0 || day === 6
  const isNight = hours >= DAY_END_HOUR || hours < DAY_START_HOUR
  const isPeakSeason = V5_PEAK_MONTHS.includes(date.getMonth())

  switch (service) {
    case 'V1':
      return GRID_FEES.V1.price
    case 'V5':
      if (isOffDay) {
        if (isPeakSeason && V5_OFF_DAY_PEAK_HOURS.includes(hours)) {
          return GRID_FEES.V5.nightTop
        } else {
          return GRID_FEES.V5.night
        }
      } else if (isNight) {
        return GRID_FEES.V5.night
      } else if (isPeakSeason && V5_DAY_PEAK_HOURS.includes(hours)) {
        return GRID_FEES.V5.dayTop
      } else {
        return GRID_FEES.V5.day
      }
    default:
      if (isOffDay || isNight) {
        return GRID_FEES[service].night
      } else {
        return GRID_FEES[service].day
      }
  }
}

const round4 = (value) => Math.round(value * 10000) / 10000

// ISO 8601 UTC without milliseconds, e.g. 2026-10-14T06:30:00Z
const toUtcString = (date) => date.toISOString().replace(/\.\d{3}Z$/, 'Z')

// Price components (EUR/kWh, VAT included) for every slot
function computeSlots (prices, plan, slotMinutes) {
  return prices.map((p) => {
    const start = new Date(p.deliveryStart)
    const local = changeTimeZone(start, TIME_ZONE)
    // Nord Pool price is EUR/MWh without VAT
    const electricity = round4(p.entryPerArea.EE * (1 + VAT_RATE) / 1000)
    const transmission = getGridFee(local, plan)

    return {
      start,
      end: new Date(start.getTime() + slotMinutes * 60 * 1000),
      local,
      electricity,
      transmission,
      renewable: RENEWABLE_FEE,
      excise: EXCISE,
      supplySecurity: SUPPLY_SECURITY_FEE,
      total: round4(electricity + transmission + RENEWABLE_FEE + EXCISE + SUPPLY_SECURITY_FEE)
    }
  })
}

// v1: array of arrays, Europe/Tallinn wall-clock time, VAT included in every component
function formatV1 (slots) {
  return slots.map((s) => [
    s.local.getFullYear(),
    s.local.getMonth() + 1,
    s.local.getDate(),
    s.local.getHours(),
    s.local.getMinutes(),
    s.electricity,
    s.transmission,
    s.renewable,
    s.excise,
    s.supplySecurity
  ])
}

// v2: object with metadata, slot times in UTC, VAT included in every component
function formatV2 (slots, plan, slotMinutes, updatedAt) {
  return {
    version: 2,
    plan,
    interval: slotMinutes,
    currency: 'EUR',
    unit: 'EUR/kWh',
    vatIncluded: true,
    updatedAt: toUtcString(updatedAt),
    prices: slots.map((s) => ({
      start: toUtcString(s.start),
      end: toUtcString(s.end),
      electricity: s.electricity,
      transmission: s.transmission,
      renewable: s.renewable,
      excise: s.excise,
      supplySecurity: s.supplySecurity,
      total: s.total
    }))
  }
}

async function saveJSON (key, data) {
  const s3Client = new S3Client({
    region: S3_REGION
  })

  await s3Client.send(new PutObjectCommand({
    Bucket: S3_BUCKET,
    Key: key,
    Body: JSON.stringify(data),
    ContentType: 'application/json'
  }))

  await s3Client.send(new PutObjectAclCommand({
    Bucket: S3_BUCKET,
    Key: key,
    ACL: 'public-read'
  }))

  await s3Client.send(new PutObjectTaggingCommand({
    Bucket: S3_BUCKET,
    Key: key,
    Tagging: {
      TagSet: [S3_TAG]
    }
  }))
}

export const handler = async (event) => {
  try {
    console.log('Starting electricity price import...')

    const allPrices = await getPrices()
    // Average full hours before filtering, so the current hour isn't a partial average
    const pricesHourly = filterPast(aggregateToHourly(allPrices), 60)
    const prices15min = filterPast(allPrices, 15)

    if (prices15min.length === 0) {
      console.log('No prices data available, skipping file write')
      return {
        statusCode: 200,
        body: JSON.stringify({
          message: 'No data to save',
          timestamp: new Date().toISOString()
        })
      }
    }

    const updatedAt = new Date()

    for (const plan of PLANS) {
      const slots15min = computeSlots(prices15min, plan, 15)
      const slotsHourly = computeSlots(pricesHourly, plan, 60)

      await saveJSON(`15min/${plan}.json`, formatV1(slots15min))
      await saveJSON(`${plan}.json`, formatV1(slotsHourly))
      await saveJSON(`v2/15min/${plan}.json`, formatV2(slots15min, plan, 15, updatedAt))
      await saveJSON(`v2/1h/${plan}.json`, formatV2(slotsHourly, plan, 60, updatedAt))
    }

    return {
      statusCode: 200,
      body: JSON.stringify({
        message: 'Successfully imported electricity prices',
        timestamp: new Date().toISOString()
      })
    }
  } catch (error) {
    console.error('Error in Lambda handler:', error)
    return {
      statusCode: 500,
      body: JSON.stringify({
        message: 'Failed to import electricity prices',
        error: error.message,
        timestamp: new Date().toISOString()
      })
    }
  }
}
