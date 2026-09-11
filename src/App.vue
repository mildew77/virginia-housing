<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import L from 'leaflet'

const mapElement = ref(null)
const loading = ref(true)
const error = ref('')
const historicalLatestPeriod = ref('')
const forecastHorizonEndDates = ref([])
const historicalCoverage = ref({ total: 0, available: 0, missing: 0 })
const forecastCoverage = ref({ total: 0, available: 0, missing: 0 })
const affordabilityCoverage = ref({ total: 0, available: 0, missing: 0 })
const affordabilityHomeValueDate = ref('')
const recordsByZip = ref({})
const forecastRecordsByZip = ref({})
const affordabilityRecordsByZip = ref({})
const activeView = ref('affordability')
const selectedZip = ref('')
const historyLoading = ref(false)
const historyError = ref('')
const historyByZip = ref({})
const hoveredPoint = ref(null)
const historyPanel = ref(null)
const affordabilityPanel = ref(null)
const selectedAffordabilityZip = ref('')
const loanInterestRate = ref(7)
const downPaymentPercent = ref(20)
const homeInsuranceRate = ref(0.6)
const menuOpen = ref(false)
let map
let historyDataset
let boundaries

const legend = [
  { label: 'No Zillow data', color: '#111827' },
  { label: 'Below 0%', color: '#a51d2d' },
  { label: '0% to 1%', color: '#e6533c' },
  { label: '1% to 2%', color: '#f28d45' },
  { label: '2% to 3%', color: '#f6c453' },
  { label: '3% to 4%', color: '#a7d96d' },
  { label: '4% to 5%', color: '#57a86b' },
  { label: '5% to 6%', color: '#147a69' },
  { label: 'Above 6%', color: '#075160' },
]

const affordabilityLegend = [
  { label: 'No complete data', color: '#111827' },
  { label: 'Below 20% of income', color: '#075160' },
  { label: '20% to 28%', color: '#147a69' },
  { label: '28% to 36%', color: '#a7d96d' },
  { label: '36% to 43%', color: '#f6c453' },
  { label: '43% to 50%', color: '#e6533c' },
  { label: '50% or more', color: '#a51d2d' },
]
const pmiTiers = [
  { min: 3.5, max: 5, rate: 0.9 },
  { min: 5, max: 10, rate: 0.6 },
  { min: 10, max: 15, rate: 0.45 },
  { min: 15, max: 20, rate: 0.23 },
]

const activeLegend = computed(() => activeView.value === 'affordability'
  ? affordabilityLegend
  : legend.map((item, index) => index === 0 && activeView.value === 'projected'
  ? { ...item, label: 'No forecast data' }
  : item))
const activeRecords = computed(() => activeView.value === 'historical' ? recordsByZip.value : activeView.value === 'projected' ? forecastRecordsByZip.value : affordabilityRecordsByZip.value)
const coverage = computed(() => activeView.value === 'historical' ? historicalCoverage.value : activeView.value === 'projected' ? forecastCoverage.value : affordabilityCoverage.value)
const latestPeriod = computed(() => activeView.value === 'historical'
  ? historicalLatestPeriod.value
  : activeView.value === 'projected' ? forecastHorizonEndDates.value.at(-1) : affordabilityHomeValueDate.value)
const formattedPeriod = computed(() => latestPeriod.value
  ? new Intl.DateTimeFormat('en-US', { month: 'long', year: 'numeric', timeZone: 'UTC' })
    .format(new Date(`${latestPeriod.value}T00:00:00Z`))
  : 'the latest available month')

const seoContent = {
  affordability: {
    title: 'Virginia Home Affordability Map | ZIP-Code Mortgage Payments',
    description: 'Estimate monthly homeownership costs across Virginia ZIP codes using local Zillow home values, median income, estimated property tax, mortgage rate, insurance, and PMI inputs.',
  },
  historical: {
    title: 'Virginia Historical Home-Value Growth by ZIP Code',
    description: 'Explore five-year annualized Zillow Home Value Index growth and monthly price history for Virginia ZIP codes.',
  },
  projected: {
    title: 'Virginia Projected Home-Value Growth by ZIP Code',
    description: 'Explore Zillow’s projected home-value growth forecasts for Virginia ZIP codes and compare future appreciation rates.',
  },
  sources: {
    title: 'Virginia Home Value Data Sources & Methodology',
    description: 'Learn how Virginia Home Values combines Zillow, U.S. Census, property-tax, and Virginia ZIP-boundary data for its maps and affordability calculator.',
  },
}

function updatePageMetadata(view) {
  const content = seoContent[view] || seoContent.affordability
  document.title = content.title
  document.querySelector('meta[name="description"]')?.setAttribute('content', content.description)
  document.querySelector('meta[property="og:title"]')?.setAttribute('content', content.title)
  document.querySelector('meta[property="og:description"]')?.setAttribute('content', content.description)
  document.querySelector('meta[name="twitter:title"]')?.setAttribute('content', content.title)
  document.querySelector('meta[name="twitter:description"]')?.setAttribute('content', content.description)
}

const selectedRecord = computed(() => recordsByZip.value[selectedZip.value])
const selectedSeries = computed(() => {
  const monthlyValues = historyByZip.value[selectedZip.value]?.monthly_zhvi || {}
  return Object.entries(monthlyValues)
    .map(([date, value]) => ({ date, value }))
    .sort((left, right) => left.date.localeCompare(right.date))
})
const chart = computed(() => {
  const series = selectedSeries.value
  if (!series.length) return null
  const values = series.map((point) => point.value)
  const min = Math.min(...values)
  const max = Math.max(...values)
  const range = max - min || 1
  const width = 800
  const height = 270
  const left = 58
  const top = 20
  const right = 22
  const bottom = 38
  const chartWidth = width - left - right
  const chartHeight = height - top - bottom
  const data = series.map((point, index) => {
    const x = left + (index / Math.max(series.length - 1, 1)) * chartWidth
    const y = top + (1 - (point.value - min) / range) * chartHeight
    return { ...point, x, y }
  })
  const points = data.map((point) => `${point.x.toFixed(2)},${point.y.toFixed(2)}`).join(' ')
  const middle = series[Math.floor(series.length / 2)]
  return { min, max, points, data, width, height, left, right, top, bottom, chartWidth, chartHeight, labels: [series[0], middle, series.at(-1)] }
})
const chartTooltip = computed(() => {
  if (!hoveredPoint.value || !chart.value) return null
  const point = hoveredPoint.value
  const tooltipWidth = 162
  const tooltipHeight = 50
  const rectX = point.x > chart.value.width - tooltipWidth - 22 ? point.x - tooltipWidth - 12 : point.x + 12
  const rectY = Math.max(4, Math.min(point.y - tooltipHeight - 12, chart.value.height - chart.value.bottom - tooltipHeight))
  return { ...point, rectX, rectY, tooltipWidth, tooltipHeight }
})

function growthColor(rate) {
  if (rate === null || rate === undefined) return '#111827'
  if (rate < 0) return '#a51d2d'
  if (rate < 0.01) return '#e6533c'
  if (rate < 0.02) return '#f28d45'
  if (rate < 0.03) return '#f6c453'
  if (rate < 0.04) return '#a7d96d'
  if (rate < 0.05) return '#57a86b'
  if (rate < 0.06) return '#147a69'
  return '#075160'
}

function forecastColor(rate) {
  if (rate === null || rate === undefined) return '#111827'
  if (rate < 0) return '#a51d2d'
  if (rate < 1) return '#e6533c'
  if (rate < 2) return '#f28d45'
  if (rate < 3) return '#f6c453'
  if (rate < 4) return '#a7d96d'
  if (rate < 5) return '#57a86b'
  if (rate < 6) return '#147a69'
  return '#075160'
}

function affordabilityColor(ratio) {
  if (ratio === null || ratio === undefined) return '#111827'
  if (ratio < 0.2) return '#075160'
  if (ratio < 0.28) return '#147a69'
  if (ratio < 0.36) return '#a7d96d'
  if (ratio < 0.43) return '#f6c453'
  if (ratio < 0.5) return '#e6533c'
  return '#a51d2d'
}

function currentPmiRate() {
  const downPayment = Math.max(3.5, Math.min(100, Number(downPaymentPercent.value) || 3.5))
  const tier = pmiTiers.find((item) => downPayment >= item.min && downPayment < item.max)
  return tier ? tier.rate / 100 : 0
}

function normalizeDownPayment() {
  downPaymentPercent.value = Math.max(3.5, Math.min(100, Number(downPaymentPercent.value) || 3.5))
}

function affordabilityPayment(record) {
  const homeValue = record?.home_value
  const income = record?.median_household_income
  const taxRate = record?.effective_property_tax_rate
  if (!homeValue || !income || taxRate === null || taxRate === undefined) return null

  const downPayment = Math.max(3.5, Math.min(100, Number(downPaymentPercent.value) || 3.5)) / 100
  const loanAmount = homeValue * (1 - downPayment)
  const monthlyRate = Math.max(0, Number(loanInterestRate.value) || 0) / 100 / 12
  const numberOfPayments = 360
  const principalAndInterest = monthlyRate === 0
    ? loanAmount / numberOfPayments
    : loanAmount * (monthlyRate * (1 + monthlyRate) ** numberOfPayments) / ((1 + monthlyRate) ** numberOfPayments - 1)
  const monthlyPropertyTax = homeValue * taxRate / 12
  const monthlyInsurance = homeValue * Math.max(0, Number(homeInsuranceRate.value) || 0) / 100 / 12
  const pmiRate = downPayment < 0.2 ? currentPmiRate() : 0
  const monthlyPmi = loanAmount * pmiRate / 12
  const monthlyTotal = principalAndInterest + monthlyPropertyTax + monthlyInsurance + monthlyPmi
  return {
    homeValue,
    income,
    taxRate,
    loanAmount,
    principalAndInterest,
    monthlyPropertyTax,
    monthlyInsurance,
    monthlyPmi,
    pmiRate,
    monthlyTotal,
    incomeShare: monthlyTotal / (income / 12),
  }
}

const selectedAffordabilityRecord = computed(() => affordabilityRecordsByZip.value[selectedAffordabilityZip.value])
const selectedAffordabilityPayment = computed(() => affordabilityPayment(selectedAffordabilityRecord.value))

function selectAffordability(zip) {
  selectedAffordabilityZip.value = zip
  nextTick(() => affordabilityPanel.value?.scrollIntoView({ behavior: 'smooth', block: 'start' }))
}

function formatRate(rate) {
  return rate === null || rate === undefined
    ? 'No Data'
    : new Intl.NumberFormat('en-US', { style: 'percent', minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(rate)
}

function formatCurrency(value) {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(value)
}

function formatChartDate(value) {
  return new Intl.DateTimeFormat('en-US', { month: 'short', year: 'numeric', timeZone: 'UTC' })
    .format(new Date(`${value}T00:00:00Z`))
}

async function selectZip(zip) {
  selectedZip.value = zip
  hoveredPoint.value = null
  historyError.value = ''
  await nextTick()
  historyPanel.value?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  if (historyByZip.value[zip]) return
  historyLoading.value = true
  try {
    if (!historyDataset) {
      const response = await fetch('/data/virginia-zillow-monthly-home-values.json')
      if (!response.ok) throw new Error('The ZIP price history could not be loaded.')
      historyDataset = await response.json()
    }
    historyByZip.value = { ...historyByZip.value, [zip]: historyDataset.zip_code_data[zip] || { monthly_zhvi: {} } }
  } catch (cause) {
    historyError.value = cause instanceof Error ? cause.message : 'The ZIP price history could not be loaded.'
  } finally {
    historyLoading.value = false
  }
}

function updateChartHover(event) {
  if (!chart.value) return
  const bounds = event.currentTarget.getBoundingClientRect()
  const x = ((event.clientX - bounds.left) / bounds.width) * chart.value.width
  const index = Math.max(0, Math.min(
    chart.value.data.length - 1,
    Math.round(((x - chart.value.left) / chart.value.chartWidth) * (chart.value.data.length - 1)),
  ))
  hoveredPoint.value = chart.value.data[index]
}

function clearChartHover() {
  hoveredPoint.value = null
}

function closeMenu() {
  menuOpen.value = false
}

function switchView(view) {
  activeView.value = view
  selectedZip.value = ''
  selectedAffordabilityZip.value = ''
  closeMenu()
}

function tooltipHtml(record) {
  const growth = record.five_year_average_annual_growth_rate === null || record.five_year_average_annual_growth_rate === undefined
    ? '<strong class="no-data">No Data</strong>'
    : `<strong>${formatRate(record.five_year_average_annual_growth_rate)}</strong>`

  return `<div class="zip-tooltip">
    <span class="zip-tooltip__eyebrow">Virginia ZIP code</span>
    <h2>${record.zip_code}</h2>
    <dl>
      <div><dt>City</dt><dd>${record.city}</dd></div>
      <div><dt>County</dt><dd>${record.county_name}</dd></div>
      <div><dt>5-year avg. annual growth</dt><dd>${growth}</dd></div>
    </dl>
  </div>`
}

function forecastTooltipHtml(record) {
  const forecasts = Object.entries(record.forecast_growth_percent || {})
    .sort(([left], [right]) => left.localeCompare(right))
    .slice(1)
    .map(([date, value]) => `<div><dt>${formatChartDate(date)} forecast</dt><dd>${value === null || value === undefined ? 'No Data' : `${value.toFixed(1)}%`}</dd></div>`)
    .join('')

  return `<div class="zip-tooltip">
    <span class="zip-tooltip__eyebrow">Virginia ZIP code</span>
    <h2>${record.zip_code}</h2>
    <dl>
      <div><dt>City</dt><dd>${record.city || 'Unavailable'}</dd></div>
      <div><dt>County</dt><dd>${record.county_name || 'Unavailable'}</dd></div>
      ${forecasts || '<div><dt>Forecast</dt><dd class="no-data">No Data</dd></div>'}
    </dl>
  </div>`
}

function affordabilityTooltipHtml(record) {
  const payment = affordabilityPayment(record)
  const income = record?.median_household_income ? `${formatCurrency(record.median_household_income)} / year` : 'No Data'
  if (!payment) {
    return `<div class="zip-tooltip"><span class="zip-tooltip__eyebrow">Virginia ZIP code</span><h2>${record.zip_code}</h2><dl><div><dt>City</dt><dd>${record.city || 'Unavailable'}</dd></div><div><dt>County</dt><dd>${record.county_name || 'Unavailable'}</dd></div><div><dt>Annual median income</dt><dd>${income}</dd></div><div><dt>Affordability</dt><dd class="no-data">No complete data</dd></div></dl></div>`
  }
  return `<div class="zip-tooltip affordability-tooltip">
    <span class="zip-tooltip__eyebrow">Virginia ZIP code</span>
    <h2>${record.zip_code}</h2>
    <dl>
      <div><dt>City</dt><dd>${record.city || 'Unavailable'}</dd></div>
      <div><dt>County</dt><dd>${record.county_name || 'Unavailable'}</dd></div>
      <div><dt>Annual median income</dt><dd>${income}</dd></div>
      <div><dt>Principal &amp; interest</dt><dd>${formatCurrency(payment.principalAndInterest)}/mo</dd></div>
      <div><dt>Property tax</dt><dd>${formatCurrency(payment.monthlyPropertyTax)}/mo</dd></div>
      <div><dt>Insurance</dt><dd>${formatCurrency(payment.monthlyInsurance)}/mo</dd></div>
      <div><dt>PMI</dt><dd>${formatCurrency(payment.monthlyPmi)}/mo</dd></div>
      <div><dt>Total payment</dt><dd>${formatCurrency(payment.monthlyTotal)}/mo</dd></div>
      <div><dt>Share of income</dt><dd>${formatRate(payment.incomeShare)}</dd></div>
    </dl>
  </div>`
}

function forecastRate(record) {
  const dates = Object.keys(record?.forecast_growth_percent || {}).sort()
  return dates.length ? record.forecast_growth_percent[dates.at(-1)] : null
}

function buildMap() {
  if (!boundaries || !mapElement.value) return
  map?.remove()
  const isHistorical = activeView.value === 'historical'
  const isAffordability = activeView.value === 'affordability'
  const records = activeRecords.value
  map = L.map(mapElement.value, {
    attributionControl: false,
    boxZoom: true,
    doubleClickZoom: true,
    dragging: true,
    keyboard: true,
    scrollWheelZoom: true,
    touchZoom: true,
    zoomControl: true,
    zoomSnap: 0,
  })

  const layer = L.geoJSON(boundaries, {
    style(feature) {
      const record = records[String(feature.properties.ZIP_CODE).padStart(5, '0')]
      const rate = isHistorical
        ? record?.five_year_average_annual_growth_rate
        : isAffordability ? affordabilityPayment(record)?.incomeShare : forecastRate(record)
      return {
        color: '#ffffff',
        weight: 0.45,
        opacity: 0.8,
        fillColor: isHistorical ? growthColor(rate) : isAffordability ? affordabilityColor(rate) : forecastColor(rate),
        fillOpacity: 0.82,
      }
    },
    onEachFeature(feature, featureLayer) {
      const zip = String(feature.properties.ZIP_CODE).padStart(5, '0')
      const record = records[zip] || {
        zip_code: zip,
        city: feature.properties.PO_NAME || 'Unavailable',
        county_name: 'Unavailable',
      }
      featureLayer.bindTooltip(isHistorical ? tooltipHtml(record) : isAffordability ? affordabilityTooltipHtml(record) : forecastTooltipHtml(record), {
        className: 'home-value-tooltip',
        sticky: true,
        direction: 'top',
        offset: [0, -8],
      })
      featureLayer.on({
        mouseover() { featureLayer.setStyle({ weight: 1.4, color: '#18212f', fillOpacity: 0.96 }) },
        mouseout() { layer.resetStyle(featureLayer) },
        click() { isAffordability ? selectAffordability(zip) : selectZip(zip) },
      })
    },
  }).addTo(map)
  map.invalidateSize({ animate: false })
  map.fitBounds(layer.getBounds(), { padding: [22, 22], animate: false })
}

watch(activeView, async () => {
  updatePageMetadata(activeView.value)
  if (activeView.value === 'sources') {
    map?.remove()
    map = undefined
    return
  }
  await nextTick()
  buildMap()
})

watch([loanInterestRate, downPaymentPercent, homeInsuranceRate], () => {
  if (activeView.value === 'affordability') buildMap()
})

onMounted(async () => {
  updatePageMetadata(activeView.value)
  try {
    const [boundaryResponse, metadataResponse, forecastResponse, affordabilityResponse] = await Promise.all([
      fetch('/data/virginia-zip-boundaries.geojson'),
      fetch('/data/zip-metadata.json'),
      fetch('/data/virginia-zillow-home-value-forecast.json'),
      fetch('/data/virginia-home-affordability-data.json'),
    ])
    if (!boundaryResponse.ok || !metadataResponse.ok || !forecastResponse.ok || !affordabilityResponse.ok) throw new Error('The map data could not be loaded.')

    const [boundaryData, metadata, forecastData, affordabilityData] = await Promise.all([boundaryResponse.json(), metadataResponse.json(), forecastResponse.json(), affordabilityResponse.json()])
    boundaries = boundaryData
    recordsByZip.value = metadata.zip_codes
    forecastRecordsByZip.value = forecastData.zip_code_data
    affordabilityRecordsByZip.value = affordabilityData.zip_code_data
    const historicalRecords = Object.values(recordsByZip.value)
    const projectedRecords = Object.values(forecastRecordsByZip.value)
    historicalCoverage.value = {
      total: historicalRecords.length,
      available: historicalRecords.filter((record) => record.five_year_average_annual_growth_rate !== null && record.five_year_average_annual_growth_rate !== undefined).length,
      missing: historicalRecords.filter((record) => record.five_year_average_annual_growth_rate === null || record.five_year_average_annual_growth_rate === undefined).length,
    }
    forecastCoverage.value = {
      total: projectedRecords.length,
      available: projectedRecords.filter((record) => forecastRate(record) !== null && forecastRate(record) !== undefined).length,
      missing: projectedRecords.filter((record) => forecastRate(record) === null || forecastRate(record) === undefined).length,
    }
    const affordabilityRecords = Object.values(affordabilityRecordsByZip.value)
    affordabilityCoverage.value = {
      total: affordabilityRecords.length,
      available: affordabilityRecords.filter((record) => affordabilityPayment(record)).length,
      missing: affordabilityRecords.filter((record) => !affordabilityPayment(record)).length,
    }
    historicalLatestPeriod.value = historicalRecords.map((record) => record.growth_period_end).filter(Boolean).sort().at(-1)
    forecastHorizonEndDates.value = forecastData.forecast_horizon_end_dates || []
    affordabilityHomeValueDate.value = affordabilityRecords.map((record) => record.home_value_date).filter(Boolean).sort().at(-1)
    await nextTick()
    buildMap()
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : 'The map could not be loaded.'
  } finally {
    loading.value = false
  }
})

onBeforeUnmount(() => map?.remove())
</script>

<template>
  <header class="app-header">
    <a class="app-header__brand" href="#map-overview" @click="switchView('affordability')">Virginia Home Values</a>
    <button
      class="menu-toggle"
      type="button"
      :aria-expanded="menuOpen"
      aria-controls="app-navigation"
      @click="menuOpen = !menuOpen"
    >
      <span class="menu-toggle__icon" aria-hidden="true"><i></i><i></i><i></i></span>
      <span>{{ menuOpen ? 'Close menu' : 'Menu' }}</span>
    </button>
  </header>
  <div v-if="menuOpen" class="menu-backdrop" @click="closeMenu"></div>
  <nav id="app-navigation" class="app-menu" :class="{ 'app-menu--open': menuOpen }" aria-label="Application views">
    <p class="app-menu__label">Views</p>
    <a href="#map-overview" :class="{ 'app-menu__item--active': activeView === 'affordability' }" @click="switchView('affordability')">Home affordability</a>
    <a href="#map-overview" :class="{ 'app-menu__item--active': activeView === 'historical' }" @click="switchView('historical')">Historical home-value growth</a>
    <a href="#map-overview" :class="{ 'app-menu__item--active': activeView === 'projected' }" @click="switchView('projected')">Projected home-value growth</a>
    <a href="#data-sources" :class="{ 'app-menu__item--active': activeView === 'sources' }" @click="switchView('sources')">Data sources</a>
  </nav>
  <section v-if="activeView === 'sources'" id="data-sources" class="sources-page" aria-labelledby="sources-title">
    <div class="sources-page__hero">
      <p class="map-intro__eyebrow">Virginia home values</p>
      <h1 id="sources-title">Data sources &amp; methodology</h1>
      <p>This app combines publicly available housing, income, tax, and geographic data to compare Virginia ZIP-code areas. Figures are estimates for research and exploration—not appraisals, lending decisions, tax advice, or guarantees.</p>
    </div>
    <div class="sources-grid">
      <article class="source-card source-card--wide">
        <p class="source-card__eyebrow">Home values &amp; forecasts</p>
        <h2>Zillow Research</h2>
        <p>The historical map and ZIP price charts use the Zillow Home Value Index (ZHVI): a smoothed, seasonally adjusted estimate of a typical mid-tier home value—not a median closed-sale price. The projected map uses Zillow Home Value Forecast (ZHVF) growth.</p>
        <p>Zillow’s forecast model uses prior market behavior plus housing and economic indicators, such as mortgage rates, inventory, property taxes, income, population growth, and unemployment. A forecast is an estimate, not a guarantee.</p>
        <a href="https://www.zillow.com/research/data/" target="_blank" rel="noopener noreferrer">Zillow Research data ↗</a>
        <a href="https://zillow.zendesk.com/hc/en-us/articles/203512180-Zillow-Home-Value-Forecasts" target="_blank" rel="noopener noreferrer">Forecast methodology ↗</a>
        <p class="source-card__attribution">Data Provided by Zillow Group</p>
      </article>
      <article class="source-card">
        <p class="source-card__eyebrow">Household income</p>
        <h2>U.S. Census Bureau ACS</h2>
        <p>Median household income is from the 2024 American Community Survey 5-Year Estimates, table B19013. These are inflation-adjusted survey estimates covering 2020–2024.</p>
        <a href="https://data.census.gov/table/ACSDT5Y2024.B19013" target="_blank" rel="noopener noreferrer">ACS B19013 ↗</a>
      </article>
      <article class="source-card">
        <p class="source-card__eyebrow">Property taxes</p>
        <h2>ACS effective-tax estimate</h2>
        <p>The property-tax input is median real-estate taxes paid divided by median owner-occupied home value, using ACS tables B25103 and B25077. It is an effective tax-burden estimate, not a local statutory tax rate.</p>
        <a href="https://www.tax.virginia.gov/local-tax-rates" target="_blank" rel="noopener noreferrer">Virginia local tax rates ↗</a>
      </article>
      <article class="source-card">
        <p class="source-card__eyebrow">ZIP geography</p>
        <h2>Virginia open-data boundaries</h2>
        <p>Map polygons and the Virginia ZIP list come from the Virginia ZIP Codes ArcGIS Feature Service. Boundaries are generalized for browser performance.</p>
        <a href="https://services7.arcgis.com/Zb4O2iaRvsbTmu4i/ArcGIS/rest/services/VA_ZipCodes/FeatureServer/0" target="_blank" rel="noopener noreferrer">Virginia ZIP boundary service ↗</a>
      </article>
      <article class="source-card source-card--wide">
        <p class="source-card__eyebrow">How to read the results</p>
        <h2>Important geographic and calculation notes</h2>
        <p>USPS ZIP Codes and Census ZIP Code Tabulation Areas (ZCTAs) are not identical. Some ZIPs therefore do not have a corresponding income or property-tax estimate and appear black in the affordability map. The affordability calculator uses a 30-year fixed mortgage, your selected interest rate, down payment, and insurance rate. PMI below 20% down is an illustrative rate grid; actual PMI depends on the lender, loan, borrower, and property.</p>
        <a href="https://www.census.gov/programs-surveys/geography/guidance/geo-areas/zctas.html" target="_blank" rel="noopener noreferrer">Census ZIP Code Tabulation Area guidance ↗</a>
      </article>
      <article class="source-card source-card--wide">
        <p class="source-card__eyebrow">Site usage logging</p>
        <h2>Production access records</h2>
        <p>When this production site loads, it sends one background request that records the access time, IP address, browser user agent, and approximate location information supplied by CloudFront. Records are stored in the <code>virginia_home_logins</code> DynamoDB table and automatically expire after 90 days.</p>
      </article>
      <article class="source-card source-card--wide">
        <p class="source-card__eyebrow">Home affordability calculation</p>
        <h2>How each ZIP’s monthly payment is estimated</h2>
        <p>The calculator begins with the latest Zillow Home Value Index for the ZIP. Loan amount equals home value minus the selected down payment. Principal and interest use the standard fixed-rate mortgage formula over 360 monthly payments.</p>
        <div class="source-formula" aria-label="Home affordability formula">
          <span>Monthly total</span><b>=</b><span>Principal &amp; interest</span><b>+</b><span>Property tax</span><b>+</b><span>Insurance</span><b>+</b><span>PMI, when down payment is below 20%</span>
        </div>
        <p>Monthly property tax equals the ZIP’s estimated effective property-tax rate × home value ÷ 12. Monthly insurance equals the user-entered insurance rate × home value ÷ 12. For a down payment below 20%, PMI is calculated from the starting loan amount using the displayed illustrative PMI tier.</p>
        <div class="source-formula" aria-label="Income share formula">
          <span>Affordability share</span><b>=</b><span>Monthly total</span><b>÷</b><span>Median household income ÷ 12</span>
        </div>
        <p>The affordability map colors ZIPs by this resulting income share. It does not include utilities, maintenance, HOA fees, closing costs, income taxes, or other household debts.</p>
      </article>
    </div>
  </section>
  <template v-if="activeView !== 'sources'">
  <section id="map-overview" class="map-intro" aria-labelledby="map-title">
    <div>
      <p class="map-intro__eyebrow">Virginia housing market</p>
      <h1 id="map-title">{{ activeView === 'historical' ? 'Historical Home-value growth by ZIP code' : activeView === 'projected' ? 'Projected Home-value growth by ZIP code' : 'Home affordability by ZIP code' }}</h1>
      <p v-if="activeView === 'historical'">Each colored area is a Virginia ZIP code. Its color represents Zillow’s five-year average annual home-value growth rate, based on the latest monthly value compared with the same month five years earlier.</p>
      <p v-else-if="activeView === 'projected'">Each colored area is a Virginia ZIP code. Its color represents Zillow’s forecasted home-value change through the longest available forecast horizon.</p>
      <p v-else>Each colored area is a Virginia ZIP code. Its color represents the estimated monthly ownership payment as a share of median household income, using the inputs below.</p>
    </div>
    <ul class="map-intro__actions">
      <li><strong>Hover</strong><span>{{ activeView === 'historical' ? 'View city, county, ZIP, and growth rate.' : activeView === 'projected' ? 'View city, county, ZIP, and later forecast values.' : 'View the estimated payment and income share.' }}</span></li>
      <li><strong>Click</strong><span>{{ activeView === 'affordability' ? 'Open the ZIP’s detailed payment calculation below.' : 'Open the ZIP’s full monthly price history below.' }}</span></li>
      <li><strong>Pan &amp; zoom</strong><span>Explore areas in more detail.</span></li>
    </ul>
  </section>
  <section v-if="activeView === 'affordability'" class="affordability-controls" aria-label="Home affordability assumptions">
    <div>
      <p class="map-intro__eyebrow">Payment assumptions</p>
      <h2>Set your financing assumptions</h2>
      <p>Payments use a 30-year fixed mortgage and each ZIP’s latest Zillow home value, estimated effective property-tax rate, and median household income.</p>
    </div>
    <div class="affordability-controls__inputs">
      <label>Loan interest rate <input v-model.number="loanInterestRate" type="number" min="0" step="0.125" inputmode="decimal" /><span>%</span></label>
      <label>Down payment <input v-model.number="downPaymentPercent" type="number" min="3.5" max="100" step="0.5" inputmode="decimal" @change="normalizeDownPayment" /><span>%</span></label>
      <label>Home insurance rate <input v-model.number="homeInsuranceRate" type="number" min="0" step="0.05" inputmode="decimal" /><span>%</span></label>
    </div>
    <div class="pmi-grid" aria-label="Estimated annual PMI rate grid">
      <span class="pmi-grid__label">Estimated PMI rate</span>
      <span v-for="tier in pmiTiers" :key="tier.min" :class="{ 'pmi-grid__tier--active': downPaymentPercent >= tier.min && downPaymentPercent < tier.max }" class="pmi-grid__tier">{{ tier.min }}–{{ tier.max }}% down: {{ tier.rate }}%</span>
      <span :class="{ 'pmi-grid__tier--active': downPaymentPercent >= 20 }" class="pmi-grid__tier">20%+ down: none</span>
    </div>
  </section>
  <main class="map-page" aria-label="Virginia ZIP-code home value growth map">
    <div v-if="loading" class="map-status">Loading ZIP boundaries and home-value data…</div>
    <div v-else-if="error" class="map-status map-status--error">{{ error }}</div>
    <div ref="mapElement" class="map" :class="{ 'map--hidden': loading || error }"></div>
    <a class="map-data-attribution" href="https://www.zillow.com/research/data/" target="_blank" rel="noopener noreferrer">Data Provided by Zillow Group</a>
  </main>
  <section id="map-details" class="map-info" aria-label="Map information">
    <div class="info-card">
      <h1>{{ activeView === 'historical' ? 'Five-year average annual home-value growth' : activeView === 'projected' ? 'Projected home-value growth' : 'Monthly payment as a share of income' }}</h1>
      <p v-if="activeView === 'historical'">Annualized Zillow Home Value Index change from the same month five years earlier. Data through {{ formattedPeriod }}.</p>
      <p v-else-if="activeView === 'projected'">Forecasted Zillow Home Value Index change from the July 2026 base date through {{ formattedPeriod }}. Colors use the longest available forecast horizon.</p>
      <p v-else>Color represents the estimated all-in monthly payment divided by the ZIP’s monthly median household income. Home values through {{ formattedPeriod }}.</p>
      <p class="data-attribution"><a href="https://www.zillow.com/research/data/" target="_blank" rel="noopener noreferrer">Data Provided by Zillow Group</a></p>
      <ul class="legend">
        <li v-for="item in activeLegend" :key="item.label"><span :style="{ backgroundColor: item.color }"></span>{{ item.label }}</li>
      </ul>
    </div>
    <div class="info-card info-card--coverage">
      <h2>ZIP coverage</h2>
      <p v-if="activeView === 'historical'"><strong>{{ coverage.available }}</strong> of {{ coverage.total }} Virginia ZIP codes have five years of Zillow data. <strong>{{ coverage.missing }}</strong> ZIPs without a five-year rate appear black.</p>
      <p v-else-if="activeView === 'projected'"><strong>{{ coverage.available }}</strong> of {{ coverage.total }} Virginia ZIP codes have a Zillow forecast at the longest horizon. <strong>{{ coverage.missing }}</strong> ZIPs without that forecast appear black.</p>
      <p v-else><strong>{{ coverage.available }}</strong> of {{ coverage.total }} Virginia ZIP codes have complete home-value, income, and property-tax inputs. <strong>{{ coverage.missing }}</strong> ZIPs missing an input appear black.</p>
      <p class="fine-print">{{ activeView === 'historical' ? 'Hover a ZIP area for its city, county, ZIP code, and five-year average annual growth rate.' : activeView === 'projected' ? 'Hover a ZIP area for its city, county, ZIP code, and all later forecast values; the closest forecast is omitted.' : 'Hover or click a ZIP area to see principal and interest, property tax, insurance, PMI, total payment, and income share.' }}</p>
      <template v-if="activeView === 'projected'">
        <h3 class="forecast-method__title">How Zillow builds the forecast</h3>
        <p class="forecast-method">Zillow uses a statistical model trained on prior market behavior. Its inputs include housing signals such as mortgage rates, property taxes, construction costs, vacancies, delinquencies and homes for sale, along with household income, population growth and unemployment. It is a model-based estimate, not a guarantee.</p>
        <p class="fine-print"><a href="https://zillow.zendesk.com/hc/en-us/articles/203512180-Zillow-Home-Value-Forecasts" target="_blank" rel="noopener noreferrer">Read Zillow’s forecast methodology →</a></p>
      </template>
    </div>
  </section>
  <section v-if="activeView === 'affordability' && selectedAffordabilityRecord" ref="affordabilityPanel" class="affordability-result" aria-live="polite">
    <div>
      <p class="history-card__eyebrow">{{ selectedAffordabilityRecord.city }}, {{ selectedAffordabilityRecord.county_name }}</p>
      <h2>ZIP {{ selectedAffordabilityRecord.zip_code }} estimated monthly payment</h2>
      <p class="affordability-result__income">Annual median household income: <strong>{{ selectedAffordabilityRecord.median_household_income ? `${formatCurrency(selectedAffordabilityRecord.median_household_income)} / year` : 'No Data' }}</strong></p>
    </div>
    <p v-if="!selectedAffordabilityPayment" class="history-state">This ZIP is missing a home-value, income, or effective property-tax input needed for the calculation.</p>
    <template v-else>
      <div class="affordability-result__summary"><strong>{{ formatCurrency(selectedAffordabilityPayment.monthlyTotal) }}</strong><span>estimated total monthly payment · {{ formatRate(selectedAffordabilityPayment.incomeShare) }} of monthly median household income</span></div>
      <dl class="payment-breakdown">
        <div><dt>Home value</dt><dd>{{ formatCurrency(selectedAffordabilityPayment.homeValue) }}</dd></div>
        <div><dt>Loan amount</dt><dd>{{ formatCurrency(selectedAffordabilityPayment.loanAmount) }}</dd></div>
        <div><dt>Principal &amp; interest</dt><dd>{{ formatCurrency(selectedAffordabilityPayment.principalAndInterest) }} / month</dd></div>
        <div><dt>Property tax</dt><dd>{{ formatCurrency(selectedAffordabilityPayment.monthlyPropertyTax) }} / month</dd></div>
        <div><dt>Home insurance</dt><dd>{{ formatCurrency(selectedAffordabilityPayment.monthlyInsurance) }} / month</dd></div>
        <div><dt>PMI <span v-if="selectedAffordabilityPayment.pmiRate">({{ formatRate(selectedAffordabilityPayment.pmiRate) }} annual)</span></dt><dd>{{ formatCurrency(selectedAffordabilityPayment.monthlyPmi) }} / month</dd></div>
      </dl>
    </template>
  </section>
  <section v-if="selectedRecord" ref="historyPanel" class="history-card" aria-live="polite">
    <div class="history-card__header">
      <div>
        <p class="history-card__eyebrow">{{ selectedRecord.city }}, {{ selectedRecord.county_name }}</p>
        <h2>ZIP {{ selectedRecord.zip_code }} price history</h2>
      </div>
      <button type="button" aria-label="Close price history" @click="selectedZip = ''">×</button>
    </div>
    <p v-if="historyLoading" class="history-state">Loading monthly price history…</p>
    <p v-else-if="historyError" class="history-state history-state--error">{{ historyError }}</p>
    <p v-else-if="!selectedSeries.length" class="history-state">No Zillow price history is published for this ZIP code.</p>
    <template v-else-if="chart">
      <div class="history-stat"><strong>{{ formatCurrency(selectedSeries.at(-1).value) }}</strong><span>Latest Zillow Home Value Index</span></div>
      <svg class="history-chart" :viewBox="`0 0 ${chart.width} ${chart.height}`" role="img" :aria-label="`Monthly Zillow Home Value Index for ZIP ${selectedRecord.zip_code}`" @pointermove="updateChartHover" @pointerleave="clearChartHover">
        <line v-for="fraction in [0, .5, 1]" :key="fraction" :x1="chart.left" :x2="chart.width - chart.right" :y1="chart.top + fraction * chart.chartHeight" :y2="chart.top + fraction * chart.chartHeight" class="chart-grid" />
        <polyline :points="chart.points" class="chart-line" />
        <g v-if="chartTooltip" class="chart-hover">
          <line :x1="chartTooltip.x" :x2="chartTooltip.x" :y1="chart.top" :y2="chart.top + chart.chartHeight" />
          <circle :cx="chartTooltip.x" :cy="chartTooltip.y" r="4.5" />
          <rect :x="chartTooltip.rectX" :y="chartTooltip.rectY" :width="chartTooltip.tooltipWidth" :height="chartTooltip.tooltipHeight" rx="7" />
          <text :x="chartTooltip.rectX + 10" :y="chartTooltip.rectY + 19" class="chart-tooltip-date">{{ formatChartDate(chartTooltip.date) }}</text>
          <text :x="chartTooltip.rectX + 10" :y="chartTooltip.rectY + 37" class="chart-tooltip-value">{{ formatCurrency(chartTooltip.value) }}</text>
        </g>
        <text :x="chart.left - 10" :y="chart.top + 4" class="chart-value" text-anchor="end">{{ formatCurrency(chart.max) }}</text>
        <text :x="chart.left - 10" :y="chart.top + chart.chartHeight + 4" class="chart-value" text-anchor="end">{{ formatCurrency(chart.min) }}</text>
        <text v-for="(label, index) in chart.labels" :key="label.date" :x="chart.left + index * (chart.chartWidth / 2)" :y="chart.height - 10" class="chart-label" :text-anchor="index === 0 ? 'start' : index === 2 ? 'end' : 'middle'">{{ formatChartDate(label.date) }}</text>
      </svg>
      <p class="data-attribution history-attribution"><a href="https://www.zillow.com/research/data/" target="_blank" rel="noopener noreferrer">Data Provided by Zillow Group</a></p>
    </template>
  </section>
  </template>
  <footer class="loan-ad">
    <a href="https://www.rate.com/loan-officers/marshall-hawkins-1756757" target="_blank" rel="noopener noreferrer" aria-label="Visit Marshall Hawkins at Rate for Virginia home loans">
      <img class="loan-ad__photo" src="/marshall-hawkins.png" alt="Marshall Hawkins" />
      <span class="loan-ad__copy">
        <strong>Marshall Hawkins</strong>
        <span>VP of Mortgage Lending · NMLS 1756757</span>
      </span>
      <span class="loan-ad__cta">Need a home loan in Virginia?<b>Explore your options →</b></span>
    </a>
  </footer>
</template>
