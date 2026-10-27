<script setup lang="ts">
import { computed, h, nextTick, onMounted, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import {
  NDataTable, NSelect, NInput, NButton, NIcon, NTag, NTooltip, NEmpty, NModal, NCard, NSpace, NText,
  NDatePicker, NAlert, NSpin, NScrollbar, type DataTableColumns,
} from 'naive-ui'
import {
  SearchOutline, RefreshOutline, DownloadOutline, ArrowUpOutline, ArrowDownOutline,
  PlaySkipBackOutline, PlaySkipForwardOutline, DocumentTextOutline, ArchiveOutline,
} from '@vicons/ionicons5'
import { client } from '../../api/ws'
import { errorText } from '../../api/errors'
import { formatBytes, formatDateTime, formatNumber } from '../../api/format'
import type { LogFile, LogFileEntry, LogFilePage, LogFileSearch, LogLevel } from '../../api/types'
import { useNodes } from '../../stores/nodes'

const { t } = useI18n()
const nodes = useNodes()

// Entries kept in the browser; the far end is dropped beyond this.
const KEEP = 20000

const LEVELS: LogLevel[] = ['emergency', 'alert', 'critical', 'error', 'warning', 'notice', 'info', 'debug']
const SEVERITY = Object.fromEntries(LEVELS.map((l, i) => [l, i])) as Record<LogLevel, number>
const LEVEL_TYPE: Record<LogLevel, 'error' | 'warning' | 'info' | 'success' | 'default'> = {
  emergency: 'error', alert: 'error', critical: 'error', error: 'error',
  warning: 'warning', notice: 'info', info: 'success', debug: 'default',
}

const files = ref<LogFile[]>([])
const listing = ref(false)
const error = ref<string | null>(null)
const note = ref<string | null>(null)

const file = ref<LogFile | null>(null)
const entries = ref<LogFileEntry[]>([])
const start = ref(0)
const stop = ref(0)
const size = ref<number | null>(null)
const loading = ref(false)

const minLevel = ref<LogLevel>('debug')
const modules = ref<string[]>([])
const jumpAt = ref<number | null>(null)
const query = ref('')
const selected = ref<LogFileEntry | null>(null)
const highlight = ref<number | null>(null)

const node = computed(() => nodes.current)
const atStart = computed(() => start.value <= 0)
const atEnd = computed(() => size.value !== null && stop.value >= size.value)

// Files grouped by the file being written, its rotated copies under it.
const groups = computed(() => {
  const by = new Map<string, LogFile[]>()
  for (const f of files.value) {
    if (!by.has(f.base)) by.set(f.base, [])
    by.get(f.base)!.push(f)
  }
  const order = { lager: 0, crash_log: 1, logger: 2 }
  return [...by.entries()]
    .map(([base, fs]) => ({ base, source: fs[0].source, files: fs }))
    .sort((a, b) => order[a.source] - order[b.source] || baseName(a.base).localeCompare(baseName(b.base)))
})

const baseName = (p: string) => p.split(/[\\/]/).pop() ?? p

async function call<T>(method: string, params: Record<string, unknown>): Promise<T | null> {
  if (!node.value) return null
  error.value = null
  try {
    return await client.request<T>(method, { node: node.value, ...params } as never, 30000)
  } catch (e) {
    error.value = errorText(e)
    return null
  }
}

async function loadList() {
  listing.value = true
  const r = await call<LogFile[]>('logfile.list', {})
  listing.value = false
  if (!r) return
  files.value = r
  if (file.value) {
    const same = r.find((f) => f.path === file.value!.path)
    if (same) file.value = same
  }
}

function open(f: LogFile) {
  file.value = f
  entries.value = []
  highlight.value = null
  modules.value = []
  note.value = null
  if (f.gz) void read(0, 'fwd', 'replace')
  else void read(null, 'back', 'replace')
}

// mode: replace the list, put the page before it, or after it.
async function read(pos: number | null, dir: 'back' | 'fwd', mode: 'replace' | 'before' | 'after') {
  if (!file.value || loading.value) return
  loading.value = true
  const r = await call<LogFilePage>('logfile.read', { path: file.value.path, pos, dir })
  loading.value = false
  if (!r) return
  if (size.value !== null && r.size !== null && r.size < size.value && mode !== 'replace') {
    note.value = t('logs.files.rotated_away')
    void loadList()
  }
  size.value = r.size
  const page = r.entries
  if (mode === 'replace') {
    entries.value = page
    start.value = r.start
    stop.value = r.stop
  } else if (mode === 'before') {
    const cur = entries.value.slice()
    if (cur.length && cur[0].cont && page.length) {
      const last = page[page.length - 1]
      page[page.length - 1] = { ...last, text: `${last.text}\n${cur[0].text}` }
      cur.shift()
    }
    let all = page.concat(cur)
    if (all.length > KEEP) {
      stop.value = all[KEEP].pos
      all = all.slice(0, KEEP)
    }
    entries.value = all
    start.value = r.start
  } else {
    const cur = entries.value.slice()
    const add = page.slice()
    if (add.length && add[0].cont && cur.length) {
      const last = cur[cur.length - 1]
      cur[cur.length - 1] = { ...last, text: `${last.text}\n${add[0].text}` }
      add.shift()
    }
    let all = cur.concat(add)
    if (all.length > KEEP) {
      all = all.slice(all.length - KEEP)
      start.value = all[0].pos
    }
    entries.value = all
    stop.value = r.stop
  }
}

const table = ref<InstanceType<typeof NDataTable> | null>(null)
async function scrollTo(where: 'top' | 'bottom' | number) {
  await nextTick()
  if (where === 'top') table.value?.scrollTo({ top: 0 })
  else if (where === 'bottom') table.value?.scrollTo({ top: Number.MAX_SAFE_INTEGER })
  else table.value?.scrollTo({ index: where })
}

async function toStart() {
  await read(0, 'fwd', 'replace')
  void scrollTo('top')
}
async function toEnd() {
  await read(null, 'back', 'replace')
  void scrollTo('bottom')
}
async function older() {
  const before = entries.value.length
  await read(start.value, 'back', 'before')
  void scrollTo(Math.max(0, entries.value.length - before - 1))
}
async function newer() {
  await read(stop.value, 'fwd', 'after')
}

function pad(n: number) { return String(n).padStart(2, '0') }
function localStamp(ms: number) {
  const d = new Date(ms)
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
}

async function jump() {
  if (!file.value || jumpAt.value === null) return
  const r = await call<{ pos: number }>('logfile.seek', { path: file.value.path, time: localStamp(jumpAt.value) })
  if (!r) return
  await gotoPos(r.pos)
}

async function gotoPos(pos: number) {
  highlight.value = pos
  await read(pos, 'fwd', 'replace')
  void scrollTo('top')
}

// Search
const searching = ref(false)
const showHits = ref(false)
const hits = ref<LogFileEntry[]>([])
const hitsText = ref('')
const hitsDir = ref<'back' | 'fwd'>('back')
const hitsNext = ref<number | null>(null)
const scanned = ref(0)

async function search(dir: 'back' | 'fwd', more = false) {
  if (!file.value || !query.value) return
  if (!more) {
    hits.value = []
    scanned.value = 0
    hitsText.value = query.value
    hitsDir.value = file.value.gz ? 'fwd' : dir
    // From the edge of what is shown, in the direction searched.
    hitsNext.value = file.value.gz ? 0 : (dir === 'back' ? stop.value : start.value)
  }
  searching.value = true
  showHits.value = true
  const r = await call<LogFileSearch>('logfile.search', {
    path: file.value.path, pos: hitsNext.value, dir: hitsDir.value, text: hitsText.value,
  })
  searching.value = false
  if (!r) return
  hits.value = hits.value.concat(r.hits)
  hitsNext.value = r.next
  scanned.value += r.scanned
}

async function pickHit(e: LogFileEntry) {
  showHits.value = false
  await gotoPos(e.pos)
}

const downloadUrl = computed(() => (file.value && node.value
  ? `/download/logfile?node=${encodeURIComponent(node.value)}&path=${encodeURIComponent(file.value.path)}`
  : '#'))

const levelOptions = computed(() => LEVELS.map((l) => ({ label: t('logs.live.at_least', { level: l }), value: l })))
const moduleOptions = computed(() => {
  const seen = new Set<string>()
  for (const e of entries.value) if (e.module) seen.add(e.module)
  return [...seen].sort().map((m) => ({ label: m, value: m }))
})

const filtered = computed(() => {
  const max = SEVERITY[minLevel.value]
  const mods = new Set(modules.value)
  return entries.value.filter((e) =>
    (e.level === null ? max === SEVERITY.debug : SEVERITY[e.level] <= max)
    && (!mods.size || (e.module !== null && mods.has(e.module))))
})

const oneLine = (text: string) => text.replace(/\s+/g, ' ').trim()
// Drops the timestamp, level and pid the columns already show.
function body(e: LogFileEntry) {
  if (!e.t) return e.text
  const nl = e.text.indexOf('\n')
  const first = nl < 0 ? e.text : e.text.slice(0, nl)
  const m = /^\d{4}-\d\d-\d\d[ T]\S+\s+\[?[a-z]+\]?:?\s+(?:<[\d.]+>(?:@\S+)?\s+)?/.exec(first)
  return m ? e.text.slice(m[0].length) : e.text
}

const levelTag = (l: LogLevel | null) => (l
  ? h(NTag, { size: 'small', bordered: false, type: LEVEL_TYPE[l] }, { default: () => l })
  : null)

const columns = computed<DataTableColumns<LogFileEntry>>(() => [
  {
    key: 't', title: t('logs.live.time'), width: 200,
    render: (e) => h('span', { class: 'mono muted nowrap' }, e.t ?? ''),
  },
  { key: 'level', title: t('logs.live.min_level'), width: 100, render: (e) => levelTag(e.level) },
  {
    key: 'module', title: t('logs.live.module'), width: 150, ellipsis: { tooltip: true },
    render: (e) => h('span', { class: 'mono' }, e.module ?? ''),
  },
  {
    key: 'text', title: t('logs.live.message'), minWidth: 360, ellipsis: { tooltip: false },
    render: (e) => h('span', { class: 'mono' }, oneLine(body(e))),
  },
])

const rowProps = (e: LogFileEntry) => ({
  style: 'cursor: pointer',
  class: e.pos === highlight.value ? 'hit-row' : '',
  onClick: () => { selected.value = e },
})

const hitColumns = computed<DataTableColumns<LogFileEntry>>(() => [
  { key: 't', title: t('logs.live.time'), width: 215, render: (e) => h('span', { class: 'mono muted nowrap' }, e.t ?? '') },
  { key: 'level', title: t('logs.live.min_level'), width: 90, render: (e) => levelTag(e.level) },
  { key: 'text', title: t('logs.live.message'), ellipsis: { tooltip: false }, render: (e) => h('span', { class: 'mono' }, oneLine(body(e))) },
])
const hitRowProps = (e: LogFileEntry) => ({ style: 'cursor: pointer', onClick: () => pickHit(e) })

const position = computed(() => {
  if (!file.value) return ''
  if (size.value === null) return t('logs.files.position_gz', { from: formatBytes(start.value), to: formatBytes(stop.value) })
  return t('logs.files.position', { from: formatBytes(start.value), to: formatBytes(stop.value), size: formatBytes(size.value) })
})

const shown = ref<LogFileEntry | null>(null)
watch(selected, (e) => { if (e) shown.value = e })
const showDetail = computed({
  get: () => selected.value !== null,
  set: (v) => { if (!v) selected.value = null },
})

watch(node, () => {
  files.value = []
  file.value = null
  entries.value = []
  void loadList()
})
onMounted(loadList)
</script>

<template>
  <p class="note top">{{ t('logs.files.intro') }}</p>
  <NAlert v-if="error" type="error" :bordered="false" class="alert">{{ error }}</NAlert>
  <NAlert v-if="note" type="info" :bordered="false" class="alert" closable @close="note = null">{{ note }}</NAlert>
  <div class="files-layout">
    <div class="file-list">
      <div class="list-head">
        <NText strong>{{ t('logs.files.list') }}</NText>
        <NTooltip>
          <template #trigger>
            <NButton size="tiny" quaternary circle :loading="listing" @click="loadList">
              <template #icon><NIcon :component="RefreshOutline" /></template>
            </NButton>
          </template>
          {{ t('logs.files.refresh') }}
        </NTooltip>
      </div>
      <NScrollbar style="max-height: calc(100vh - 330px)">
        <NEmpty v-if="!listing && !files.length" size="small" :description="t('logs.files.none')" class="empty" />
        <div v-for="g in groups" :key="g.base" class="group">
          <div v-for="f in g.files" :key="f.path" class="file" :class="{ active: file?.path === f.path, rotated: f.index !== null }"
               :title="f.path" @click="open(f)">
            <NIcon :component="f.gz ? ArchiveOutline : DocumentTextOutline" class="file-icon" />
            <div class="file-main">
              <div class="file-name mono">{{ baseName(f.path) }}</div>
              <div class="file-meta">
                <template v-if="f.index === null">
                  <NTag size="tiny" :bordered="false" type="success">{{ t('logs.files.current') }}</NTag>
                  <NTag size="tiny" :bordered="false">{{ t(`logs.files.sources.${f.source}`) }}</NTag>
                  <NTag v-if="f.level" size="tiny" :bordered="false">{{ t('logs.files.level', { level: f.level }) }}</NTag>
                </template>
                <span>{{ f.size === null ? '' : formatBytes(f.size) }}</span>
                <span v-if="f.mtime">{{ formatDateTime(f.mtime) }}</span>
              </div>
            </div>
          </div>
        </div>
      </NScrollbar>
    </div>

    <div class="file-view">
      <NEmpty v-if="!file" :description="t('logs.files.pick')" class="empty big" />
      <template v-else>
        <div class="bar">
          <NSpace align="center" :size="8">
            <NSelect v-model:value="minLevel" :options="levelOptions" size="small" style="width: 150px" />
            <NSelect v-model:value="modules" :options="moduleOptions" multiple filterable clearable
                     :max-tag-count="1" size="small" :placeholder="t('logs.live.module')" style="width: 190px" />
            <NDatePicker v-if="!file.gz" v-model:value="jumpAt" type="datetime" size="small" clearable
                         :placeholder="t('logs.files.jump')" style="width: 200px" />
            <NButton v-if="!file.gz" size="small" :disabled="jumpAt === null" @click="jump">{{ t('logs.files.jump_go') }}</NButton>
          </NSpace>
          <NSpace align="center" :size="8">
            <NInput v-model:value="query" size="small" clearable :placeholder="t('logs.files.search')" style="width: 220px"
                    @keyup.enter="search('back')">
              <template #prefix><NIcon :component="SearchOutline" /></template>
            </NInput>
            <NButton size="small" :disabled="!query" :loading="searching" @click="search(file.gz ? 'fwd' : 'back')">
              {{ t('logs.files.search_go') }}
            </NButton>
            <NTooltip>
              <template #trigger>
                <NButton tag="a" :href="downloadUrl" download size="small" quaternary circle>
                  <template #icon><NIcon :component="DownloadOutline" /></template>
                </NButton>
              </template>
              {{ t('logs.files.download') }}
            </NTooltip>
          </NSpace>
        </div>
        <div class="nav">
          <NSpace align="center" :size="6">
            <NButton size="tiny" secondary :disabled="loading" @click="toStart">
              <template #icon><NIcon :component="PlaySkipBackOutline" /></template>{{ t('logs.files.start') }}
            </NButton>
            <NButton v-if="!file.gz" size="tiny" secondary :disabled="loading || atStart" @click="older">
              <template #icon><NIcon :component="ArrowUpOutline" /></template>
              {{ atStart ? t('logs.files.at_start') : t('logs.files.older') }}
            </NButton>
            <NButton size="tiny" secondary :disabled="loading || atEnd" @click="newer">
              <template #icon><NIcon :component="ArrowDownOutline" /></template>
              {{ atEnd ? t('logs.files.at_end') : t('logs.files.newer') }}
            </NButton>
            <NButton v-if="!file.gz" size="tiny" secondary :disabled="loading" @click="toEnd">
              <template #icon><NIcon :component="PlaySkipForwardOutline" /></template>{{ t('logs.files.end') }}
            </NButton>
            <NSpin v-if="loading" :size="14" />
          </NSpace>
          <NText depth="3" class="count">
            {{ position }} · {{ t('logs.live.shown', { shown: formatNumber(filtered.length), total: formatNumber(entries.length) }) }}
          </NText>
        </div>
        <p v-if="file.gz" class="note">{{ t('logs.files.gz_note') }}</p>
        <NDataTable ref="table" :columns="columns" :data="filtered" :row-key="(e: LogFileEntry) => e.pos"
                    :row-props="rowProps" size="small" virtual-scroll :max-height="'calc(100vh - 420px)'"
                    :min-height="240" :scroll-x="800" :loading="loading && !entries.length">
          <template #empty>
            <NEmpty :description="entries.length ? t('logs.live.empty_filtered') : t('logs.live.empty')" />
          </template>
        </NDataTable>
        <p class="note">{{ t('logs.live.detail_tip') }}</p>
      </template>
    </div>
  </div>

  <NModal v-model:show="showDetail">
    <NCard v-if="shown" closable style="width: min(900px, 94vw)" @close="selected = null">
      <template #header>
        <NSpace align="center" :size="8">
          <component :is="levelTag(shown.level)" />
          <span v-if="shown.module" class="mono">{{ shown.module }}</span>
          <span v-if="shown.pid" class="mono">{{ shown.pid }}</span>
          <NText depth="3" class="mono">{{ shown.t }}</NText>
        </NSpace>
      </template>
      <pre class="term">{{ shown.text }}</pre>
    </NCard>
  </NModal>

  <NModal v-model:show="showHits">
    <NCard closable style="width: min(1000px, 94vw)" :title="t('logs.files.search_title', { text: hitsText })"
           @close="showHits = false">
      <NText depth="3" class="count">
        {{ t('logs.files.search_count', { n: formatNumber(hits.length), bytes: formatBytes(scanned) }) }}
        <template v-if="hitsNext === null && !searching">
          · {{ t('logs.files.search_done', { edge: hitsDir === 'back' ? t('logs.files.edge_start') : t('logs.files.edge_end') }) }}
        </template>
      </NText>
      <NDataTable :columns="hitColumns" :data="hits" :row-props="hitRowProps" size="small" virtual-scroll
                  max-height="55vh" :loading="searching && !hits.length" class="hits">
        <template #empty><NEmpty :description="searching ? '' : t('logs.files.search_none')" /></template>
      </NDataTable>
      <template #footer>
        <NSpace justify="space-between" align="center">
          <NText depth="3" class="count">{{ t('logs.files.search_tip') }}</NText>
          <NButton v-if="hitsNext !== null" size="small" :loading="searching" @click="search(hitsDir, true)">
            {{ t('logs.files.search_more') }}
          </NButton>
        </NSpace>
      </template>
    </NCard>
  </NModal>
</template>

<style scoped>
.files-layout {
  display: flex;
  gap: 16px;
  align-items: flex-start;
}
.file-list {
  flex: 0 0 280px;
  min-width: 0;
  border-radius: 8px;
  background: rgba(128, 128, 128, 0.06);
  padding: 8px;
}
.list-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 2px 6px 8px;
}
.group + .group {
  margin-top: 6px;
  padding-top: 6px;
  border-top: 1px solid rgba(128, 128, 128, 0.15);
}
.file {
  display: flex;
  gap: 8px;
  padding: 6px 8px;
  border-radius: 6px;
  cursor: pointer;
}
.file.rotated {
  padding-left: 22px;
}
.file:hover {
  background: rgba(128, 128, 128, 0.1);
}
.file.active {
  background: rgba(128, 128, 128, 0.18);
}
.file-icon {
  margin-top: 3px;
  opacity: 0.7;
}
.file-main {
  min-width: 0;
}
.file-name {
  font-size: 13px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.file-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 4px 6px;
  align-items: center;
  font-size: 11.5px;
  opacity: 0.7;
  margin-top: 2px;
}
.file-view {
  flex: 1 1 auto;
  min-width: 0;
}
.bar {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  align-items: center;
  gap: 8px 16px;
  margin-bottom: 8px;
}
.nav {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  align-items: center;
  gap: 8px;
  margin-bottom: 8px;
}
.count {
  font-size: 12px;
}
.note {
  font-size: 12px;
  opacity: 0.6;
  margin: 8px 0 0;
}
.note.top {
  margin: 0 0 10px;
}
.alert {
  margin-bottom: 10px;
}
.empty {
  padding: 24px 8px;
}
.empty.big {
  padding: 80px 0;
}
.hits {
  margin-top: 8px;
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
:deep(.hit-row td) {
  background: rgba(240, 160, 32, 0.16) !important;
}
@media (max-width: 900px) {
  .files-layout {
    flex-direction: column;
  }
  .file-list {
    flex-basis: auto;
    width: 100%;
  }
}
</style>
