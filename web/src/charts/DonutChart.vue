<script setup lang="ts">
import './echarts'
import { computed } from 'vue'
import VChart from 'vue-echarts'
import { useChartTheme } from '../composables/useChartTheme'

// Share of a whole, e.g. ports by type. Slices past the palette repeat its
// colors; small slices only get a label in the tooltip.
const props = withDefaults(defineProps<{
  items: { name: string; value: number }[]
  format: (v: number) => string
  // Shown in the hole, e.g. the total.
  center?: string
  centerLabel?: string
  height?: number
}>(), { center: '', centerLabel: '', height: 300 })
const emit = defineEmits<{ select: [index: number] }>()

const t = useChartTheme()

const option = computed(() => {
  const th = t.value
  const total = props.items.reduce((s, i) => s + i.value, 0)
  return {
    animation: false,
    color: th.series,
    tooltip: {
      trigger: 'item',
      backgroundColor: th.tooltipBg,
      borderColor: th.axis,
      textStyle: { color: th.text },
      // Long names (e.g. a spawned executable's full path) wrap inside the
      // chart instead of running past its edge.
      confine: true,
      extraCssText: 'max-width: 320px; white-space: normal; word-break: break-all;',
      formatter: (p: { marker: string; name: string; value: number; percent: number }) =>
        `${p.marker}${escape(p.name)}<br/><b>${props.format(p.value)}</b> · ${p.percent.toFixed(1)}%`,
    },
    title: props.center ? {
      text: props.center,
      subtext: props.centerLabel,
      left: 'center',
      top: 'center',
      itemGap: 4,
      textStyle: { color: th.text, fontSize: 22, fontWeight: 600 },
      subtextStyle: { color: th.muted, fontSize: 12 },
    } : undefined,
    series: [{
      type: 'pie',
      radius: ['52%', '78%'],
      center: ['50%', '50%'],
      avoidLabelOverlap: true,
      minAngle: 1,
      itemStyle: { borderColor: th.surface, borderWidth: 2, borderRadius: 4 },
      label: { color: th.text, fontSize: 11, formatter: (p: { name: string }) => shortName(p.name) },
      labelLine: { lineStyle: { color: th.axis } },
      emphasis: { scale: true, scaleSize: 4 },
      data: props.items.map((i) => {
        const shown = total > 0 && i.value / total >= 0.04
        return { ...i, label: { show: shown }, labelLine: { show: shown } }
      }),
    }],
  }
})

function escape(s: string) {
  return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!)
}

// Long slice labels keep only the last path segment and stay short; the
// tooltip has the full name.
function shortName(name: string) {
  if (name.length <= 24) return name
  const base = name.split(/[\\/]/).filter(Boolean).pop() ?? name
  return base.length > 24 ? `${base.slice(0, 23)}…` : base
}

const onClick = (e: { dataIndex: number }) => emit('select', e.dataIndex)
</script>

<template>
  <VChart :option="option" :style="{ height: `${height}px`, width: '100%' }" autoresize
          @click="onClick" />
</template>
