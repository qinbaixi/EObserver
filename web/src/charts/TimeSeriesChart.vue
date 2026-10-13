<script setup lang="ts">
import './echarts'
import { computed } from 'vue'
import VChart from 'vue-echarts'
import { useChartTheme } from '../composables/useChartTheme'

export interface Series {
  name: string
  data: [number, number | null][]
}

const props = withDefaults(defineProps<{
  series: Series[]
  format: (v: number) => string
  stacked?: boolean
  yMax?: number
  yInterval?: number
  integer?: boolean
  windowMs: number
  height?: number
}>(), { stacked: false, yMax: undefined, yInterval: undefined, integer: false, height: 240 })

const t = useChartTheme()

function clock(ms: number) {
  const d = new Date(ms)
  return d.toTimeString().slice(0, 8)
}

const option = computed(() => {
  const th = t.value
  // The newest point of any series: overlaid nodes may have stopped early.
  const now = Math.max(0, ...props.series.map((s) => s.data.at(-1)?.[0] ?? 0)) || Date.now()
  const multi = props.series.length > 1
  return {
    animation: false,
    color: th.series,
    grid: { left: 8, right: 16, top: multi ? 36 : 12, bottom: 8, containLabel: true },
    legend: multi ? {
      top: 0, left: 0, icon: 'roundRect', itemWidth: 10, itemHeight: 10,
      textStyle: { color: th.text },
    } : undefined,
    tooltip: {
      trigger: 'axis',
      backgroundColor: th.tooltipBg,
      borderColor: th.axis,
      textStyle: { color: th.text },
      axisPointer: { type: 'line', lineStyle: { color: th.axis } },
      valueFormatter: (v: number | null) => (v == null ? '-' : props.format(v)),
    },
    xAxis: {
      type: 'time',
      min: now - props.windowMs,
      max: now,
      axisLine: { lineStyle: { color: th.axis } },
      axisTick: { show: false },
      axisLabel: { color: th.muted, formatter: clock, hideOverlap: true },
      splitLine: { show: false },
    },
    yAxis: {
      type: 'value',
      min: 0,
      max: props.yMax,
      interval: props.yInterval,
      minInterval: props.integer ? 1 : undefined,
      splitNumber: 4,
      axisLabel: { color: th.muted, formatter: props.format },
      splitLine: { lineStyle: { color: th.grid } },
    },
    series: props.series.map((s) => ({
      name: s.name,
      type: 'line',
      data: s.data,
      showSymbol: false,
      symbolSize: 8,
      lineStyle: { width: 2 },
      connectNulls: false,
      stack: props.stacked ? 'total' : undefined,
      areaStyle: props.stacked ? { opacity: 0.85 } : undefined,
      emphasis: { focus: 'series' },
    })),
  }
})
</script>

<template>
  <VChart :option="option" :style="{ height: `${height}px` }" autoresize />
</template>
