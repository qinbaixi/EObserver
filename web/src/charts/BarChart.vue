<script setup lang="ts">
import './echarts'
import { computed } from 'vue'
import VChart from 'vue-echarts'
import { useChartTheme } from '../composables/useChartTheme'

// Bars for a ranked or grouped list (the recon tools). Horizontal bars list
// the first category at the top and grow in height with the number of rows,
// so long names stay readable. Several series are drawn side by side, or on
// top of each other when they share a stack.
export interface BarSeries {
  name: string
  data: (number | null)[]
  color?: string
  // One color per bar (e.g. by scheduler type); overrides `color`.
  colors?: string[]
  stack?: string
}

const props = withDefaults(defineProps<{
  categories: string[]
  series: BarSeries[]
  format: (v: number) => string
  horizontal?: boolean
  height?: number
  yMax?: number
  yInterval?: number
  // Log value axis, for values spanning several orders of magnitude.
  log?: boolean
  // A dashed line at this value, labelled with averageLabel.
  average?: number | null
  averageLabel?: string
  legend?: boolean
  // Full text for the tooltip when the axis label is shortened.
  tooltipTitle?: (index: number) => string
}>(), {
  horizontal: false, height: undefined, yMax: undefined, yInterval: undefined, log: false, average: null, averageLabel: '',
  legend: undefined, tooltipTitle: undefined,
})
const emit = defineEmits<{ select: [index: number] }>()

const t = useChartTheme()
const showLegend = computed(() => props.legend ?? props.series.length > 1)
const shownHeight = computed(() => props.height
  ?? (props.horizontal
    ? Math.max(160, props.categories.length * (props.series.length > 1 && !props.series[0].stack ? 30 : 24) + (showLegend.value ? 64 : 36))
    : 260))

const option = computed(() => {
  const th = t.value
  const valueAxis = {
    type: props.log ? 'log' : 'value',
    min: props.log ? undefined : 0,
    max: props.yMax,
    interval: props.yInterval,
    splitNumber: 4,
    axisLabel: { color: th.muted, formatter: props.format, hideOverlap: true },
    splitLine: { lineStyle: { color: th.grid } },
  }
  const categoryAxis = {
    type: 'category',
    data: props.categories,
    inverse: props.horizontal,
    axisLine: { lineStyle: { color: th.axis } },
    axisTick: { show: false },
    axisLabel: props.horizontal
      ? { color: th.text, fontSize: 11, width: 220, overflow: 'truncate', interval: 0 }
      : { color: th.muted, fontSize: 11, hideOverlap: true },
    triggerEvent: true,
  }
  return {
    animation: false,
    color: th.series,
    grid: { left: 8, right: 24, top: showLegend.value ? 36 : 12, bottom: 8, containLabel: true },
    legend: showLegend.value ? {
      top: 0, left: 0, icon: 'roundRect', itemWidth: 10, itemHeight: 10,
      textStyle: { color: th.text },
    } : undefined,
    tooltip: {
      trigger: 'axis',
      axisPointer: { type: 'shadow' },
      backgroundColor: th.tooltipBg,
      borderColor: th.axis,
      textStyle: { color: th.text },
      formatter: (ps: { dataIndex: number; marker: string; seriesName: string; value: number | null }[]) => {
        const i = ps[0]?.dataIndex ?? 0
        const title = props.tooltipTitle ? props.tooltipTitle(i) : props.categories[i]
        // With several series, a missing value means "not in this series".
        const shown = props.series.length > 1 ? ps.filter((p) => p.value != null) : ps
        const lines = shown.map((p) =>
          `${p.marker}${props.series.length > 1 ? `${p.seriesName}: ` : ''}<b>${p.value == null ? '-' : props.format(p.value)}</b>`)
        return [escape(title), ...lines].join('<br/>')
      },
    },
    xAxis: props.horizontal ? valueAxis : categoryAxis,
    yAxis: props.horizontal ? categoryAxis : valueAxis,
    series: props.series.map((s, si) => ({
      name: s.name,
      type: 'bar',
      stack: s.stack,
      barMaxWidth: 28,
      barGap: '10%',
      data: s.data.map((v, i) => (s.colors ? { value: v, itemStyle: { color: s.colors[i] } } : v)),
      itemStyle: {
        color: s.color,
        borderRadius: s.stack ? 0 : props.horizontal ? [0, 3, 3, 0] : [3, 3, 0, 0],
      },
      cursor: 'pointer',
      markLine: si === 0 && props.average != null ? {
        silent: true,
        symbol: 'none',
        lineStyle: { color: th.text, type: 'dashed', width: 1, opacity: 0.6 },
        label: {
          color: th.text,
          formatter: `${props.averageLabel} ${props.format(props.average)}`,
          position: props.horizontal ? 'end' : 'insideEndTop',
        },
        data: [props.horizontal ? { xAxis: props.average } : { yAxis: props.average }],
      } : undefined,
    })),
  }
})

function escape(s: string) {
  return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!)
}

// A click on a bar or on its axis label selects that row.
function onClick(e: { componentType: string; dataIndex?: number; value?: unknown }) {
  if (e.componentType === 'series' && e.dataIndex != null) emit('select', e.dataIndex)
  else if (e.componentType.endsWith('Axis') && typeof e.value === 'string') {
    const i = props.categories.indexOf(e.value)
    if (i >= 0) emit('select', i)
  }
}
</script>

<template>
  <VChart :option="option" :style="{ height: `${shownHeight}px`, width: '100%' }" autoresize @click="onClick" />
</template>
