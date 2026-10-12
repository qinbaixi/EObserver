<script setup lang="ts">
import './echarts'
import { computed } from 'vue'
import VChart from 'vue-echarts'
import { useChartTheme } from '../composables/useChartTheme'
import type { LoadPoint } from '../api/types'

// One row per scheduler, one column per sample, colour = utilisation.
// Scales to any scheduler count, unlike one line per scheduler.
const props = withDefaults(defineProps<{
  points: LoadPoint[]
  types: string[]
  height?: number
}>(), { height: 240 })

const t = useChartTheme()

const LABEL: Record<string, string> = { normal: 'S', dirty_cpu: 'DC', dirty_io: 'DIO' }

const model = computed(() => {
  const pts = props.points.filter((p) => p.schedulers)
  const ids = pts.at(-1)?.schedulers?.filter((s) => props.types.includes(s.type)) ?? []
  const rows = ids.map((s) => `${LABEL[s.type]}${s.id}`)
  const rowIndex = new Map(ids.map((s, i) => [s.id, i]))
  const times = pts.map((p) => p.time)
  const data: [number, number, number][] = []
  pts.forEach((p, x) => {
    for (const s of p.schedulers!) {
      const y = rowIndex.get(s.id)
      if (y !== undefined) data.push([x, y, Math.round(s.util * 1000) / 10])
    }
  })
  return { rows, times, data }
})

const option = computed(() => {
  const th = t.value
  const m = model.value
  return {
    animation: false,
    grid: { left: 8, right: 16, top: 8, bottom: 40, containLabel: true },
    tooltip: {
      backgroundColor: th.tooltipBg,
      borderColor: th.axis,
      textStyle: { color: th.text },
      formatter: (p: { value: [number, number, number] }) => {
        const [x, y, v] = p.value
        const time = new Date(m.times[x]).toTimeString().slice(0, 8)
        return `${m.rows[y]} · ${time}<br/><b>${v.toFixed(1)}%</b>`
      },
    },
    xAxis: {
      type: 'category',
      data: m.times,
      axisLabel: { show: false },
      axisTick: { show: false },
      axisLine: { lineStyle: { color: th.axis } },
    },
    yAxis: {
      type: 'category',
      data: m.rows,
      inverse: true,
      axisTick: { show: false },
      axisLine: { show: false },
      axisLabel: { color: th.muted, fontSize: 11, interval: m.rows.length > 16 ? 'auto' : 0 },
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
      data: m.data,
      itemStyle: { borderColor: th.surface, borderWidth: 1 },
      emphasis: { itemStyle: { borderColor: th.text, borderWidth: 1 } },
      progressive: 0,
    }],
  }
})
</script>

<template>
  <VChart :option="option" :style="{ height: `${height}px` }" autoresize />
</template>
