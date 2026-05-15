<script setup>
import { computed, onMounted, ref, watch } from 'vue'
import { GChart } from 'vue-google-charts'
import { useChartTooltip } from './composables/useChartTooltip.js'
import AppSelect from './components/AppSelect.vue'

const { createTooltip } = useChartTooltip()

// Constants
const plans = [
  { value: 'V1', label: 'Võrk 1' },
  { value: 'V2', label: 'Võrk 2' },
  { value: 'V4', label: 'Võrk 4' },
  { value: 'V5', label: 'Võrk 5' }
]
const intervals = [
  { value: '15min', label: '15 minutit' },
  { value: '1h', label: '1 tund' }
]
const blueColors = ['#1e40af', '#2563eb', '#3b82f6', '#60a5fa', '#93c5fd', '#bfdbfe']
const greenColors = ['#065f46', '#047857', '#059669', '#10b981', '#34d399', '#6ee7b7']

// Refs
const selectedPlan = ref(plans.find(x => x.value === (new URLSearchParams(window.location.search).get('plan') || 'V1')))
const selectedInterval = ref(intervals.find(x => x.value === (new URLSearchParams(window.location.search).get('interval') || '15min')))
const selectedLowest = ref(new URLSearchParams(window.location.search).get('lowest') || null)
const marginal = ref(parseFloat(new URLSearchParams(window.location.search).get('marginal') || '0'))
const prices = ref()

// Computed
const is1h = computed(() => selectedInterval.value.value === '1h')

const options = computed(() => ({
  bar: { groupWidth: '75%' },
  chartArea: {
    left: 30,
    top: 5,
    bottom: 60,
    width: '100%',
    height: '75%'
  },
  focusTarget: 'category',
  fontName: 'ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji"',
  fontSize: 13,
  isStacked: true,
  legend: { position: 'none' },
  tooltip: { isHtml: true },
  hAxis: {
    slantedText: false,
    slantedTextAngle: 0
  }
}))

const data = computed(() => {
  if (!prices.value) return

  const { startIndex, endIndex } = selectedLowest.value ? lowest.value.find(x => x.value === selectedLowest.value) : {}
  const marginalValue = marginal.value || 0
  const hasSelection = startIndex >= 0 && endIndex >= 0

  const header = [
    'Aeg',
    { type: 'string', role: 'tooltip', p: { html: true } },
    'Müüja marginaal',
    { role: 'style' },
    'Elektriaktsiis',
    { role: 'style' },
    'Varustuskindluse tasu',
    { role: 'style' },
    'Taastuvenergia tasu',
    { role: 'style' },
    'Elektri edastamine',
    { role: 'style' },
    'Elektri hind',
    { role: 'style' }
  ]

  const rows = prices.value.map((x, idx) => {
    const time = x.at(0)
    const priceData = [x.at(1), x.at(2), x.at(3), x.at(4), x.at(5)]
    const isSelected = hasSelection && idx >= startIndex && idx <= endIndex
    const colors = isSelected ? greenColors : blueColors

    return [
      formatLabelForChart(time),
      createTooltip(time, priceData, marginalValue, colors, is1h.value),
      marginalValue,
      colors.at(0),
      priceData.at(0),
      colors.at(1),
      priceData.at(1),
      colors.at(2),
      priceData.at(2),
      colors.at(3),
      priceData.at(3),
      colors.at(4),
      priceData.at(4),
      colors.at(5)
    ]
  })

  return [header, ...rows]
})

const lowest = computed(() => {
  if (!prices.value) return null

  const multiplier = is1h.value ? 1 : 4

  return [
    { value: '1h', ...findLowestTimeSpan(prices.value, 1 * multiplier) },
    { value: '2h', ...findLowestTimeSpan(prices.value, 2 * multiplier) },
    { value: '3h', ...findLowestTimeSpan(prices.value, 3 * multiplier) },
    { value: '4h', ...findLowestTimeSpan(prices.value, 4 * multiplier) }
  ]
})

// Watchers
watch(() => selectedPlan.value, (val) => {
  getPrices()

  const params = new URLSearchParams({
    plan: val.value,
    interval: selectedInterval.value.value,
    lowest: selectedLowest.value || '',
    marginal: marginal.value.toString()
  })
  window.history.replaceState({}, '', `?${params.toString()}`)
})

watch(() => selectedInterval.value, (val) => {
  getPrices()

  const params = new URLSearchParams({
    plan: selectedPlan.value.value,
    interval: val.value,
    lowest: selectedLowest.value || '',
    marginal: marginal.value.toString()
  })
  window.history.replaceState({}, '', `?${params.toString()}`)
})

watch(() => selectedLowest.value, (val) => {
  console.log(val)
  const params = new URLSearchParams({
    plan: selectedPlan.value.value,
    interval: selectedInterval.value.value,
    lowest: val || '',
    marginal: marginal.value.toString()
  })
  window.history.replaceState({}, '', `?${params.toString()}`)
})

watch(() => marginal.value, (val) => {
  const params = new URLSearchParams({
    plan: selectedPlan.value.value,
    interval: selectedInterval.value.value,
    lowest: selectedLowest.value || '',
    marginal: val.toString()
  })
  window.history.replaceState({}, '', `?${params.toString()}`)
})

// Lifecycle
onMounted(() => {
  getPrices()
  setInterval(() => { getPrices() }, 15 * 60 * 1000)
})

// Functions
function formatLabelForChart (label) {
  // For 15min interval, only show labels on full hours and remove :00
  if (!is1h.value) {
    if (!label.endsWith(':00')) {
      return ''
    }
    return label.slice(0, -3)
  }

  // For 1h interval, remove :00
  if (label.endsWith(':00')) {
    return label.slice(0, -3)
  }

  return label
}

async function getPrices () {
  const interval = is1h.value ? '' : '15min/'
  const response = await fetch(`https://borsihind.s3.eu-central-1.amazonaws.com/${interval}${selectedPlan.value.value}.json`)
  const responseJson = await response.json()

  const now = new Date()
  const currentHour = now.getHours()
  const currentMinute = now.getMinutes()
  // Round down to nearest 15min interval (0, 15, 30, 45)
  const currentInterval15 = Math.floor(currentMinute / 15) * 15

  // Filter data based on current time before processing
  prices.value = responseJson.filter((x) => {
    const priceYear = x.at(0)
    const priceMonth = x.at(1)
    const priceDay = x.at(2)
    const priceHour = x.at(3)
    const priceMinute = x.at(4)

    // Create date objects for comparison
    const priceDate = new Date(priceYear, priceMonth - 1, priceDay, priceHour, priceMinute)
    const currentDate = is1h.value
      ? new Date(now.getFullYear(), now.getMonth(), now.getDate(), currentHour, 0)
      : new Date(now.getFullYear(), now.getMonth(), now.getDate(), currentHour, currentInterval15)

    // Keep entries that are at or after the current time
    return priceDate >= currentDate
  }).map((x) => [
    x.at(3).toString().padStart(2, '0') + ':' + x.at(4).toString().padStart(2, '0'),
    x.at(8) * 100, // excise
    x.at(9) * 100, // supply security fee
    x.at(7) * 100, // renewable tax
    x.at(6) * 100, // grid transmission
    x.at(5) * 100, // electricity price
    x.at(0), // year
    x.at(1), // month
    x.at(2) // day
  ])
}

function findLowestTimeSpan (prices, span) {
  if (prices.length === 0) return {}

  const marginalValue = marginal.value || 0
  const pricesSum = prices.map((x) => x.at(1) + x.at(2) + x.at(3) + x.at(4) + x.at(5) + marginalValue)

  let lowestSum = Infinity
  let lowestSumIndex = -1

  for (let i = 0; i < pricesSum.length - span + 1; i++) {
    const sum = pricesSum.slice(i, i + span).reduce((acc, val) => acc + val, 0)

    if (sum < lowestSum) {
      lowestSum = sum
      lowestSumIndex = i
    }
  }

  // Not enough data for the requested span
  if (lowestSumIndex === -1) return {}

  // Calculate end time based on interval
  const minutesPerUnit = is1h.value ? 60 : 15

  const startTime = prices.at(lowestSumIndex).at(0)
  const [startHours, startMinutes] = startTime.split(':').map(Number)

  const totalMinutes = span * minutesPerUnit
  const endTime = new Date()
  endTime.setHours(startHours, startMinutes + totalMinutes, 0, 0)

  const endTimeStr = endTime.getHours().toString().padStart(2, '0') + ':' + endTime.getMinutes().toString().padStart(2, '0')

  return {
    start: prices.at(lowestSumIndex).at(0),
    startIndex: lowestSumIndex,
    end: endTimeStr,
    endIndex: lowestSumIndex + span - 1,
    price: lowestSum / span
  }
}
</script>

<template>
  <header class="w-full flex items-start justify-between gap-4">
    <h1 class="text-2xl font-bold text-stone-900/80 tracking-wide whitespace-nowrap">
      Elektri börsihind
      <span class="block italic text-sm font-thin">by <a
        class="hover:underline"
        href="mailto:argo@roots.ee?subject=Elektri börsihind"
      >Argo Roots</a></span>
    </h1>
    <a
      href="https://apps.apple.com/ee/app/borsihind/id6766868176"
      target="_blank"
      rel="noopener"
      aria-label="Lae alla App Store'ist"
    >
      <img
        src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/et-ee?releaseDate=1700000000"
        alt="Lae alla App Store'ist"
        class="h-10"
      >
    </a>
  </header>

  <main class="flex flex-col gap-8 md:gap-20">
    <GChart
      v-if="data"
      class="h-60 md:h-96"
      type="ColumnChart"
      :data="data"
      :options="options"
      :resize-debounce="500"
    />

    <div
      v-if="lowest"
      class="grid grid-cols-2 md:grid-cols-4 gap-4 lg:gap-20 justify-between"
    >
      <div
        v-for="x in lowest"
        :key="x.index"
        class="p-4 flex flex-col gap-2 items-center cursor-pointer border hover:border-green-300 rounded-lg"
        :class="{ 'border-green-300 bg-green-50': selectedLowest === x.value, 'border-transparent': selectedLowest !== x.value }"
        @click="selectedLowest = selectedLowest !== x.value ? x.value : null"
      >
        <div
          class="font-bold"
          :class="{ 'text-green-600': selectedLowest === x.value, 'text-blue-400': selectedLowest !== x.value }"
        >
          {{ x.value }}
        </div>

        {{ x.start }} – {{ x.end }}

        <div
          v-if="x.price"
          class="mt-1 py-1 px-2 text-xs text-green-600 border rounded"
          :class="{ 'font-bold border-transparent bg-transparent': selectedLowest === x.value, 'border-green-300 bg-green-50': selectedLowest !== x.value }"
        >
          {{ x.price.toFixed(2) }}
        </div>
      </div>
    </div>

    <div class="flex flex-col sm:flex-row gap-4 items-center justify-center">
      <AppSelect
        v-model="selectedInterval"
        :options="intervals"
        label="Intervall: "
      />

      <AppSelect
        v-model="selectedPlan"
        :options="plans"
        label="Elektrilevi võrguteenus: "
      />

      <div class="relative w-full sm:w-auto">
        <div class="flex items-center rounded-lg border bg-white h-[38px] px-3 focus-within:border-indigo-500 focus-within:ring-2 focus-within:ring-white focus-within:ring-opacity-75 focus-within:ring-offset-2 focus-within:ring-offset-blue-300 sm:text-sm">
          <label class="mr-2">Marginaal:</label>
          <input
            v-model.number="marginal"
            type="number"
            step="0.01"
            class="w-20 focus:outline-none bg-transparent"
          >
        </div>
      </div>
    </div>

    <div class="pb-2 italic text-sm text-center">
      Hinnad on koos käibemaksuga, sentides kilovatt-tunni kohta.
    </div>
  </main>
</template>
