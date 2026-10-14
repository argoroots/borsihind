import { S3Client, PutObjectCommand, PutObjectAclCommand, PutObjectTaggingCommand } from '@aws-sdk/client-s3'

const S3_REGION = 'eu-central-1'
const S3_BUCKET = 'borsihind'

async function getPrices () {
  const start = new Date()
  const currentDate = start.toISOString().substring(0, 10)
  const nextDate = new Date(start)
  nextDate.setDate(nextDate.getDate() + 1)
  const nextDateStr = nextDate.toISOString().substring(0, 10)

  const allEntries = []

  // Make request for current day
  try {
    const currentResponse = await fetch(`https://dataportal-api.nordpoolgroup.com/api/DayAheadPrices?currency=EUR&market=DayAhead&deliveryArea=EE&date=${currentDate}`)
    const currentData = await currentResponse.json()

    if (currentData?.multiAreaEntries) {
      allEntries.push(...currentData.multiAreaEntries)
    }
  } catch (error) {
    console.error('Error fetching prices for current day:', error)
  }

  // Make request for next day
  try {
    const nextResponse = await fetch(`https://dataportal-api.nordpoolgroup.com/api/DayAheadPrices?currency=EUR&market=DayAhead&deliveryArea=EE&date=${nextDateStr}`)
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

function getGridFee (date, service = 'V4') {
  const plans = {
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
  const holidays = ['2025-08-20', '2025-12-24', '2025-12-25', '2025-12-26', '2026-01-01', '2026-02-24', '2026-04-03', '2026-04-05', '2026-05-01', '2026-05-24', '2026-06-23', '2026-06-24', '2026-08-20', '2026-12-24', '2026-12-25', '2026-12-26', '2027-01-01', '2027-02-24', '2027-03-26', '2027-03-28', '2027-05-01', '2027-05-16', '2027-06-23', '2027-06-24', '2027-08-20', '2027-12-24', '2027-12-25', '2027-12-26']

  const day = date.getDay()
  const hours = date.getHours()
  const month = date.getMonth()
  const today = date.toISOString().substring(0, 10)
  const isOffDay = holidays.includes(today) || day === 0 || day === 6
  // V5 peak prices apply only November–March
  const isPeakSeason = month >= 10 || month <= 2

  switch (service) {
    case 'V1':
      return plans.V1.price
    case 'V5':
      if (isOffDay) {
        if (isPeakSeason && hours >= 16 && hours < 20) {
          return plans.V5.nightTop
        } else {
          return plans.V5.night
        }
      } else if (hours >= 22 || hours < 7) {
        return plans.V5.night
      } else if (isPeakSeason && [9, 10, 11, 16, 17, 18, 19].includes(hours)) {
        return plans.V5.dayTop
      } else {
        return plans.V5.day
      }
    default:
      if (isOffDay || hours >= 22 || hours < 7) {
        return plans[service].night
      } else {
        return plans[service].day
      }
  }
}

async function saveJSON (prices, plan, suffix = '') {
  const result = prices.map((p) => {
    const dt = changeTimeZone(new Date(p.deliveryStart), 'Europe/Tallinn')
    const price = Math.round(p.entryPerArea.EE * 1.24 / 1000 * 10000) / 10000
    const gridFee = getGridFee(dt, plan)
    const renewableTax = 0.0104
    const excise = 0.0026
    const supplyFee = 0.0094

    return [
      dt.getFullYear(),
      dt.getMonth() + 1,
      dt.getDate(),
      dt.getHours(),
      dt.getMinutes(),
      price,
      gridFee,
      renewableTax,
      excise,
      supplyFee
    ]
  })

  const jsonResult = JSON.stringify(result)
  const bucketName = S3_BUCKET
  const key = suffix ? `${suffix}/${plan}.json` : `${plan}.json`

  const s3Client = new S3Client({
    region: S3_REGION
  })

  await s3Client.send(new PutObjectCommand({
    Bucket: bucketName,
    Key: key,
    Body: jsonResult,
    ContentType: 'application/json'
  }))

  await s3Client.send(new PutObjectAclCommand({
    Bucket: bucketName,
    Key: key,
    ACL: 'public-read'
  }))

  await s3Client.send(new PutObjectTaggingCommand({
    Bucket: bucketName,
    Key: key,
    Tagging: {
      TagSet: [{ Key: 'Project', Value: 'borsihind' }]
    }
  }))
}

export const handler = async (event) => {
  try {
    console.log('Starting electricity price import...')

    const plans = ['V1', 'V2', 'V4', 'V5']
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

    for (const plan of plans) {
      await saveJSON(prices15min, plan, '15min')
      await saveJSON(pricesHourly, plan, '')
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
