<script setup lang="ts">
import { computed, h, nextTick, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import {
  NDataTable, NSelect, NInput, NButton, NIcon, NTag, NTooltip, NSwitch, NEmpty, NModal, NCard,
  NSpace, NText, type DataTableColumns,
} from 'naive-ui'
import { SearchOutline, PauseOutline, PlayOutline, TrashOutline, DownloadOutline } from '@vicons/ionicons5'
import { formatNumber } from '../../api/format'
import { formatTime } from '../../api/trace'
import type { LogLevel, LogLine } from '../../api/types'
import { useLogs } from '../../stores/logs'

const { t } = useI18n()
const logs = useLogs()

const LEVELS: LogLevel[] = ['emergency', 'alert', 'critical', 'error', 'warning', 'notice', 'info', 'debug']
const SEVERITY = Object.fromEntries(LEVELS.map((l, i) => [l, i])) as Record<LogLevel, number>

const minLevel = ref<LogLevel>('notice')
const modules = ref<string[]>([])
const search = ref('')
const follow = ref(true)
const selected = ref<LogLine | null>(null)

const levelOptions = computed(() => LEVELS.map((l) => ({ label: t('logs.live.at_least', { level: l }), value: l })))
const moduleOptions = computed(() => {
  const seen = new Set<string>()
  for (const l of logs.lines) if (l.module) seen.add(l.module)
  return [...seen].sort().map((m) => ({ label: m, value: m }))
})

// Reports are printed indented; drop the indentation all lines share.
function dedent(text: string): string {
  const lines = text.split('\n')
  const indents = lines.filter((l) => l.trim()).map((l) => l.length - l.trimStart().length)
  const cut = indents.length ? Math.min(...indents) : 0
  return cut ? lines.map((l) => l.slice(cut)).join('\n') : text
}
const oneLine = (text: string) => text.replace(/\s+/g, ' ').trim()

const filtered = computed(() => {
  const max = SEVERITY[minLevel.value]
  const mods = new Set(modules.value)
  const q = search.value.trim().toLowerCase()
  return logs.lines.filter((l) =>
    SEVERITY[l.level] <= max
    && (!mods.size || (l.module !== null && mods.has(l.module)))
    && (!q || l.text.toLowerCase().includes(q)))
})

const LEVEL_TYPE: Record<LogLevel, 'error' | 'warning' | 'info' | 'success' | 'default'> = {
  emergency: 'error', alert: 'error', critical: 'error', error: 'error',
  warning: 'warning', notice: 'info', info: 'success', debug: 'default',
}

const levelTag = (l: LogLevel) =>
  h(NTag, { size: 'small', bordered: false, type: LEVEL_TYPE[l] }, { default: () => l })

const columns = computed<DataTableColumns<LogLine>>(() => [
  {
    key: 't', title: t('logs.live.time'), width: 124,
    render: (l) => h('span', { class: 'mono muted nowrap' }, formatTime(l.t)),
  },
  { key: 'level', title: t('logs.live.min_level'), width: 100, render: (l) => levelTag(l.level) },
  ...(logs.status?.lager
    ? [{
        key: 'source', title: t('logs.live.source'), width: 76,
        render: (l: LogLine) => h('span', { class: 'mono muted' }, l.source ?? ''),
      }]
    : []),
  {
    key: 'module', title: t('logs.live.module'), width: 160, ellipsis: { tooltip: true },
    render: (l) => h('span', { class: 'mono' }, l.module ?? ''),
  },
  {
    key: 'text', title: t('logs.live.message'), minWidth: 360, ellipsis: { tooltip: false },
    render: (l) => h('span', { class: 'mono' }, oneLine(l.text)),
  },
])

const rowProps = (l: LogLine) => ({ style: 'cursor: pointer', onClick: () => { selected.value = l } })

const table = ref<InstanceType<typeof NDataTable> | null>(null)
watch(() => filtered.value.length, async () => {
  if (!follow.value) return
  await nextTick()
  table.value?.scrollTo({ top: Number.MAX_SAFE_INTEGER })
})

function exportText() {
  const text = filtered.value.map((l) =>
    `${formatTime(l.t)} [${l.level}]${l.source === 'lager' ? ' (lager)' : ''} ${l.module ?? '-'} ${l.pid ?? ''}\n${dedent(l.text)}`).join('\n')
  const blob = new Blob([text + '\n'], { type: 'text/plain;charset=utf-8' })
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = `logs-${logs.node ?? 'node'}-${new Date().toISOString().replace(/[:.]/g, '-')}.txt`
  a.click()
  setTimeout(() => URL.revokeObjectURL(a.href), 1000)
}

// The modal keeps showing the last line while it fades out.
const shown = ref<LogLine | null>(null)
watch(selected, (l) => { if (l) shown.value = l })
const showDetail = computed({
  get: () => selected.value !== null,
  set: (v) => { if (!v) selected.value = null },
})
</script>

<template>
  <div class="bar">
    <NSpace align="center" :size="8">
      <NSelect v-model:value="minLevel" :options="levelOptions" size="small" style="width: 160px" />
      <NSelect v-model:value="modules" :options="moduleOptions" multiple filterable clearable
               :max-tag-count="2" size="small" :placeholder="t('logs.live.module')" style="width: 240px" />
      <NInput v-model:value="search" size="small" clearable :placeholder="t('logs.live.search')" style="width: 220px">
        <template #prefix><NIcon :component="SearchOutline" /></template>
      </NInput>
    </NSpace>
    <NSpace align="center" :size="8">
      <NText depth="3" class="count">
        {{ t('logs.live.shown', { shown: formatNumber(filtered.length), total: formatNumber(logs.lines.length) }) }}
      </NText>
      <label class="follow"><NSwitch v-model:value="follow" size="small" /> {{ t('logs.live.follow') }}</label>
      <NButton size="small" :type="logs.paused ? 'primary' : 'default'" secondary @click="logs.paused = !logs.paused">
        <template #icon><NIcon :component="logs.paused ? PlayOutline : PauseOutline" /></template>
        {{ logs.paused ? t('logs.live.resume') : t('logs.live.pause') }}
      </NButton>
      <NTooltip>
        <template #trigger>
          <NButton size="small" quaternary circle :disabled="!filtered.length" @click="exportText">
            <template #icon><NIcon :component="DownloadOutline" /></template>
          </NButton>
        </template>
        {{ t('logs.live.export') }}
      </NTooltip>
      <NTooltip>
        <template #trigger>
          <NButton size="small" quaternary circle @click="logs.clearLines()">
            <template #icon><NIcon :component="TrashOutline" /></template>
          </NButton>
        </template>
        {{ t('logs.live.clear') }}
      </NTooltip>
    </NSpace>
  </div>
  <p v-if="logs.paused" class="note paused">{{ t('logs.live.paused') }}</p>
  <NDataTable ref="table" :columns="columns" :data="filtered" :row-key="(l: LogLine) => l.seq"
              :row-props="rowProps" size="small" virtual-scroll :max-height="'calc(100vh - 360px)'"
              :min-height="240" :scroll-x="800">
    <template #empty>
      <NEmpty :description="logs.lines.length ? t('logs.live.empty_filtered') : t('logs.live.empty')" />
    </template>
  </NDataTable>
  <p class="note">{{ t('logs.live.detail_tip') }}</p>

  <NModal v-model:show="showDetail">
    <NCard v-if="shown" closable style="width: min(900px, 94vw)" @close="selected = null">
      <template #header>
        <NSpace align="center" :size="8">
          <component :is="levelTag(shown.level)" />
          <NTag v-if="shown.source === 'lager'" size="small" :bordered="false">lager</NTag>
          <span v-if="shown.module" class="mono">{{ shown.module }}</span>
          <span v-if="shown.pid" class="mono">{{ shown.pid }}</span>
          <NText depth="3" class="mono">{{ formatTime(shown.t) }}</NText>
        </NSpace>
      </template>
      <pre class="term">{{ dedent(shown.text) }}</pre>
    </NCard>
  </NModal>
</template>

<style scoped>
.bar {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  align-items: center;
  gap: 8px 16px;
  margin-bottom: 10px;
}
.follow {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 13px;
  white-space: nowrap;
}
.count {
  font-size: 12px;
}
.note {
  font-size: 12px;
  opacity: 0.6;
  margin: 8px 0 0;
}
.note.paused {
  margin: 0 0 8px;
  opacity: 0.9;
}
.term {
  margin: 0;
  padding: 10px 12px;
  border-radius: 6px;
  background: rgba(128, 128, 128, 0.1);
  font-family: 'JetBrains Mono', 'SFMono-Regular', Menlo, Consolas, monospace;
  font-size: 12.5px;
  white-space: pre-wrap;
  word-break: break-all;
  max-height: 60vh;
  overflow: auto;
}
:deep(.muted) {
  opacity: 0.6;
}
:deep(.nowrap) {
  white-space: nowrap;
}
</style>
