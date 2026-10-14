<script setup lang="ts">
import './echarts'
import { computed } from 'vue'
import VChart from 'vue-echarts'
import { useChartTheme } from '../composables/useChartTheme'

// A grid of ratios (0..1), one row per `rows` entry and one column per
// `cols` entry, e.g. carrier usage per allocator type × instance. Missing
// cells stay empty.
const props = withDefaults(defineProps<{
  rows: string[]
  cols: string[]
  // [col index, row index, ratio]
  cells: [number, number, number][]
  tooltip: (col: number, row: number) => string
  height?: number
}>(), { height: undefined })

const t = useChartTheme()
const shownHeight = computed(() => props.height ?? Math.max(180, props.rows.length * 26 + 70))

const option = computed(() => {
  const th = t.value
  return {
    animation: false,
    grid: { left: 8, right: 16, top: 8, bottom: 44, containLabel: true },
    tooltip: {
      backgroundColor: th.tooltipBg,
      borderColor: th.axis,
      textStyle: { color: th.text },
      formatter: (p: { value: [number, number, number] }) => props.tooltip(p.value[0], p.value[1]),
    },
    xAxis: {
      type: 'category',
      data: props.cols,
      axisTick: { show: false },
      axisLine: { lineStyle: { color: th.axis } },
      axisLabel: { color: th.muted, fontSize: 11, hideOverlap: true },
    },
    yAxis: {
      type: 'category',
      data: props.rows,
      inverse: true,
      axisTick: { show: false },
      axisLine: { show: false },
      axisLabel: { color: th.text, fontSize: 11, interval: 0 },
    },
    visualMap: {
      min: 0,
      max: 100,
      calculable: false,
      orient: 'horizontal',
      left: 'center',
      bottom: 0,
      itemHeight: 160,
      itemWidth: 10,
      text: ['100%', '0%'],
      textStyle: { color: th.muted },
      inRange: { color: th.ramp },
    },
    series: [{
      type: 'heatmap',
      data: props.cells.map(([x, y, v]) => [x, y, Math.round(v * 1000) / 10]),
      // Text on the darker end of the ramp needs the other color to stay readable.
      label: {
        show: props.cols.length <= 24,
        fontSize: 10,
        formatter: (p: { value: [number, number, number] }) =>
          `{${p.value[2] >= 60 ? 'hi' : 'lo'}|${Math.round(p.value[2])}}`,
        rich: {
          hi: { fontSize: 10, color: th.dark ? 'rgba(0,0,0,0.82)' : '#fff' },
          lo: { fontSize: 10, color: th.text },
        },
      },
      itemStyle: { borderColor: th.surface, borderWidth: 1 },
      emphasis: { itemStyle: { borderColor: th.text, borderWidth: 1 } },
      progressive: 0,
    }],
  }
})
</script>

<template>
  <VChart :option="option" :style="{ height: `${shownHeight}px`, width: '100%' }" autoresize />
</template>
