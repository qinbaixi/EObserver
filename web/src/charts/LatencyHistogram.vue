<script setup lang="ts">
// Latency distribution of one kind of call. The node's buckets (8 per
// doubling) are merged into 2 per doubling, gaps included, so the bars
// read as an even log scale.
import './echarts'
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import VChart from 'vue-echarts'
import { useChartTheme } from '../composables/useChartTheme'
import { formatLatency } from '../api/trace'

const props = withDefaults(defineProps<{
  hist: { low: number; high: number; count: number }[]
  height?: number
}>(), { height: 220 })

const { t } = useI18n()
const th = useChartTheme()

const bins = computed(() => {
  const counts = new Map<number, number>()
  for (const { low: lo, high: hi, count: n } of props.hist) {
    const j = Math.max(0, Math.floor(2 * Math.log2(Math.max(1, (lo + hi) / 2))))
    counts.set(j, (counts.get(j) ?? 0) + n)
  }
  if (!counts.size) return []
  const js = [...counts.keys()]
  const out: { low: number; high: number; n: number }[] = []
  for (let j = Math.min(...js); j <= Math.max(...js); j++) {
    out.push({
      low: j === 0 ? 0 : Math.round(2 ** (j / 2)),
      high: Math.round(2 ** ((j + 1) / 2)),
      n: counts.get(j) ?? 0,
    })
  }
  return out
})

const option = computed(() => {
  const c = th.value
  return {
    animation: false,
    grid: { left: 8, right: 16, top: 12, bottom: 8, containLabel: true },
    tooltip: {
      trigger: 'axis',
      axisPointer: { type: 'shadow' },
      backgroundColor: c.tooltipBg,
      borderColor: c.axis,
      textStyle: { color: c.text },
      formatter: (ps: { dataIndex: number }[]) => {
        const b = bins.value[ps[0].dataIndex]
        return `${formatLatency(b.low)} – ${formatLatency(b.high)}<br/>${t('trace.stats.count')}: ${b.n}`
      },
    },
    xAxis: {
      type: 'category',
      data: bins.value.map((b) => formatLatency(b.low)),
      axisLine: { lineStyle: { color: c.axis } },
      axisTick: { show: false },
      axisLabel: { color: c.muted, hideOverlap: true },
    },
    yAxis: {
      type: 'value',
      minInterval: 1,
      splitNumber: 4,
      axisLabel: { color: c.muted },
      splitLine: { lineStyle: { color: c.grid } },
    },
    series: [{
      type: 'bar',
      data: bins.value.map((b) => b.n),
      barCategoryGap: '20%',
      itemStyle: { color: c.series[0], borderRadius: [3, 3, 0, 0] },
    }],
  }
})
</script>

<template>
  <VChart :option="option" autoresize :style="{ height: `${height}px`, width: '100%' }" />
</template>
