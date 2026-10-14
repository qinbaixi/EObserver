<script setup lang="ts">
import { computed, h, onBeforeUnmount, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRoute, useRouter } from 'vue-router'
import {
  NButton, NAlert, NIcon, NDataTable, NTag, NRadioGroup, NRadioButton, NSwitch, NTooltip,
  NProgress, NGrid, NGi, NCard, type DataTableColumns,
} from 'naive-ui'
import { PlayOutline, StopOutline, ChatbubblesOutline } from '@vicons/ionicons5'
import { client } from '../../api/ws'
import { errorText } from '../../api/errors'
import { formatBytes, formatNumber } from '../../api/format'
import type { WindowItem, WindowReport } from '../../api/types'
import { useRecon } from '../../stores/recon'
import { useSettings } from '../../stores/settings'

const props = defineProps<{ node: string }>()
const emit = defineEmits<{ open: [pid: string] }>()
const { t } = useI18n()
const route = useRoute()
const router = useRouter()
const recon = useRecon()
const settings = useSettings()

const seconds = ref(10)
const continuous = ref(false)
const running = ref(false)
const left = ref(0)
const error = ref<string | null>(null)
const last = computed(() => recon.window[props.node] ?? null)
let ticker: number | undefined
let stopped = false

async function run() {
  stopped = false
  error.value = null
  do {
    running.value = true
    left.value = seconds.value
    clearInterval(ticker)
    ticker = window.setInterval(() => { left.value = Math.max(0, left.value - 1) }, 1000)
    try {
      const report = await client.request<WindowReport>('diag.window',
        { node: props.node, seconds: seconds.value }, seconds.value * 1000 + 60000)
      recon.window[props.node] = { report, at: Date.now() }
    } catch (e) {
      error.value = errorText(e)
      stopped = true
    } finally {
      clearInterval(ticker)
      running.value = false
    }
  } while (continuous.value && !stopped)
}

// Lets the current window finish; only the next one is not started.
function stop() {
  stopped = true
  continuous.value = false
}

watch(() => props.node, stop)
onBeforeUnmount(() => { stopped = true; clearInterval(ticker) })

type Metric = 'reductions' | 'memory' | 'message_queue_len'
const METRICS: Metric[] = ['reductions', 'memory', 'message_queue_len']
const fmt = (m: Metric, n: number) => (m === 'memory' ? formatBytes(n) : formatNumber(n))

function columns(m: Metric): DataTableColumns<WindowItem> {
  return [
    {
      key: 'pid', title: t('common.process'), minWidth: 200, ellipsis: { tooltip: true },
      render: (i) => h('span', null, [
        h('span', { class: 'mono pid' }, i.pid), ' ',
        i.name ? h('b', null, i.name) : h('span', { class: 'mono muted' }, i.initial_call),
        i.new ? h(NTag, { size: 'tiny', bordered: false, type: 'info', style: 'margin-left: 6px' }, { default: () => t('common.new') }) : null,
        !i.alive ? h(NTag, { size: 'tiny', bordered: false, style: 'margin-left: 6px' }, { default: () => t('common.exited') }) : null,
      ]),
    },
    {
      key: 'value', title: t('recon.window.growth'), width: 150, align: 'right',
      render: (i) => h('span', { class: 'mono grow' }, `+${fmt(m, i.value)}`),
    },
    {
      key: 'now', title: t('recon.window.now'), width: 150, align: 'right',
      render: (i) => h('span', { class: 'mono muted' }, fmt(m, i[m])),
    },
    ...(settings.readOnly ? [] : [{
      key: 'trace', title: '', width: 40, align: 'center' as const,
      render: (i: WindowItem) => i.alive ? h(NTooltip, null, {
        trigger: () => h(NButton, {
          quaternary: true, circle: true, size: 'tiny',
          onClick: (e: MouseEvent) => {
            e.stopPropagation()
            void router.push({ path: '/trace', query: { node: route.query.node, target: i.pid } })
          },
        }, { icon: () => h(NIcon, { component: ChatbubblesOutline }) }),
        default: () => t('common.trace'),
      }) : null,
    }]),
  ]
}

const rowProps = (i: WindowItem) => ({ style: 'cursor: pointer', onClick: () => emit('open', i.pid) })
</script>

<template>
  <div class="bar">
    <NRadioGroup v-model:value="seconds" size="small" :disabled="running">
      <NRadioButton v-for="s in [5, 10, 30, 60]" :key="s" :value="s">{{ t('recon.window.seconds', { n: s }) }}</NRadioButton>
    </NRadioGroup>
    <NTooltip>
      <template #trigger>
        <span class="switch"><NSwitch v-model:value="continuous" size="small" /> {{ t('recon.window.continuous') }}</span>
      </template>
      {{ t('recon.window.continuous_tip') }}
    </NTooltip>
    <NButton v-if="!running || !continuous" type="primary" :loading="running" @click="run">
      <template #icon><NIcon :component="PlayOutline" /></template>
      {{ t('common.start') }}
    </NButton>
    <NButton v-else @click="stop">
      <template #icon><NIcon :component="StopOutline" /></template>
      {{ t('common.stop') }}
    </NButton>
    <span v-if="running" class="muted">{{ t('recon.window.running', { n: left }) }}</span>
    <span v-else-if="last" class="muted">
      {{ t('recon.window.summary', { seconds: last.report.seconds.toFixed(1), created: formatNumber(last.report.created),
                                     exited: formatNumber(last.report.exited), count: formatNumber(last.report.process_count) }) }}
    </span>
    <span v-else class="muted">{{ t('recon.window.intro') }}</span>
  </div>
  <NProgress v-if="running" type="line" :percentage="Math.round(((seconds - left) * 100) / seconds)"
             :show-indicator="false" :height="3" style="margin-bottom: 12px" />
  <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
  <NGrid v-if="last" :cols="1" :x-gap="12" :y-gap="12">
    <NGi v-for="m in METRICS" :key="m">
      <NCard :title="t(`recon.window.${m}`)" size="small">
        <NDataTable :columns="columns(m)" :data="last.report[m]" size="small" :bordered="false"
                    :row-props="rowProps" :row-key="(i: WindowItem) => i.pid" max-height="360">
          <template #empty><span class="muted">{{ t('recon.window.empty') }}</span></template>
        </NDataTable>
      </NCard>
    </NGi>
  </NGrid>
  <p v-if="last" class="note">{{ t('recon.window.note') }}</p>
</template>

<style scoped>
.bar {
  display: flex;
  align-items: center;
  gap: 16px;
  flex-wrap: wrap;
  margin-bottom: 16px;
}
.switch {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 13px;
}
.muted {
  opacity: 0.6;
  font-size: 13px;
}
.note {
  font-size: 12px;
  opacity: 0.5;
  margin-top: 12px;
}
:deep(.muted) {
  opacity: 0.6;
}
:deep(.grow) {
  font-weight: 600;
}
</style>
