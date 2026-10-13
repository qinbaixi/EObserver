<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch, type Component } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRouter } from 'vue-router'
import { NModal, NInput, NIcon, NSpin, useThemeVars } from 'naive-ui'
import {
  SearchOutline, ServerOutline, GitNetworkOutline, GridOutline, AppsOutline,
  MoonOutline, SunnyOutline, MedkitOutline, AddCircleOutline,
} from '@vicons/ionicons5'
import { pages } from '../router'
import { client } from '../api/ws'
import { useNodes } from '../stores/nodes'
import { useTheme } from '../stores/theme'
import { useUi } from '../stores/ui'
import type { AppInfo, EtsTable, MnesiaTable, ProcessPage, ProcessRow } from '../api/types'
import StatusDot from './StatusDot.vue'

// Ctrl+K / ⌘K search over pages, nodes, actions and the current node's
// processes, tables and applications. The node is only asked while the
// palette is open and something is typed, and only through the existing
// bounded requests: one node.processes page of 20 per (debounced) query,
// and the ETS / Mnesia / application lists once per opening.

type Group = 'pages' | 'nodes' | 'processes' | 'tables' | 'apps' | 'actions'

interface Item {
  key: string
  group: Group
  title: string
  subtitle?: string
  icon?: Component
  status?: 'connecting' | 'connected' | 'disconnected' | 'failed'
  tag?: string
  score: number
  run: () => void
}

// Short groups first so the (up to 20) processes do not push them out of view.
const GROUPS: Group[] = ['pages', 'nodes', 'actions', 'apps', 'tables', 'processes']
const LIMIT: Record<Group, number> = { pages: 20, nodes: 8, processes: 20, tables: 10, apps: 10, actions: 10 }
const PROC_LIMIT = 20
const DEBOUNCE_MS = 250

const { t } = useI18n()
const router = useRouter()
const nodes = useNodes()
const theme = useTheme()
const ui = useUi()

const query = ref('')
const q = computed(() => query.value.trim())
const active = ref(0)
const listEl = ref<HTMLElement | null>(null)
const node = computed(() =>
  nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)

// Substring match scores highest (earlier is better). Otherwise a fuzzy
// match: the query's characters in order, each either right after the
// previous one or at the start of a word (so "mlq" finds mnesia_lock_queue
// and "内分配" finds 内存分配器). -1 means no match.
const isBoundary = (s: string, i: number) =>
  i === 0 || /[\s_:./<>-]/.test(s[i - 1]) || /[^\x00-\x7f]/.test(s[i])

function fuzzy(s: string, n: string): number {
  let from = 0
  let prev = -2
  let jumps = 0
  for (const c of n) {
    let j = s.indexOf(c, from)
    while (j >= 0 && j !== prev + 1 && !isBoundary(s, j)) j = s.indexOf(c, j + 1)
    if (j < 0) return -1
    if (j !== prev + 1) jumps++
    prev = j
    from = j + 1
  }
  return Math.max(1, 50 - jumps * 5)
}

function score(needle: string, ...texts: (string | null | undefined)[]): number {
  if (!needle) return 0
  const n = needle.toLowerCase()
  const compact = n.replace(/\s+/g, '')
  let best = -1
  for (const raw of texts) {
    if (!raw) continue
    const s = raw.toLowerCase()
    const at = s.indexOf(n)
    if (at === 0) best = Math.max(best, 100)
    else if (at > 0) best = Math.max(best, 90 - Math.min(at, 30))
    else if (compact) best = Math.max(best, fuzzy(s, compact))
  }
  return best
}

// --- remote sources ---------------------------------------------------------

// Takes one update of a topic and unsubscribes (like a paused page's
// manual refresh). The returned function cancels it if still waiting.
function once<T>(topic: string, params: Record<string, unknown>,
                 onData: (d: T) => void, onError: () => void): () => void {
  let done = false
  const unsub = client.subscribe(topic, params, 60000,
    (d) => { if (!done) { done = true; unsub(); onData(d) } },
    () => { if (!done) { done = true; unsub(); onError() } })
  return () => { if (!done) { done = true; unsub() } }
}

const procs = ref<ProcessRow[]>([])
const procLoading = ref(false)
let procCancel: (() => void) | null = null
let procTimer: number | undefined

function stopProcs() {
  clearTimeout(procTimer)
  procCancel?.()
  procCancel = null
}

watch([q, node, () => ui.paletteOpen], ([text, n, open]) => {
  stopProcs()
  procs.value = []
  procLoading.value = false
  if (!open || !text || !n) return
  procLoading.value = true
  procTimer = window.setTimeout(() => {
    procCancel = once<ProcessPage>('node.processes',
      { node: n, sort: 'name', order: 'asc', filter: text, offset: 0, limit: PROC_LIMIT },
      (d) => { procs.value = d.rows; procLoading.value = false },
      () => { procLoading.value = false })
  }, DEBOUNCE_MS)
})

// Table and application lists are fetched once per opening, on the first
// typed character, and filtered locally after that.
const ets = ref<EtsTable[]>([])
const mnesia = ref<MnesiaTable[]>([])
const apps = ref<AppInfo[]>([])
let listsFor: string | null = null
let listCancels: (() => void)[] = []

function stopLists() {
  listCancels.forEach((c) => c())
  listCancels = []
  listsFor = null
  ets.value = []
  mnesia.value = []
  apps.value = []
}

watch([q, node, () => ui.paletteOpen], ([text, n, open]) => {
  if (!open || n !== listsFor) stopLists()
  if (!open || !text || !n || listsFor === n) return
  listsFor = n
  listCancels.push(
    once<EtsTable[]>('node.ets', { node: n }, (d) => { ets.value = d }, () => {}),
    once<MnesiaTable[]>('node.mnesia', { node: n }, (d) => { mnesia.value = d }, () => {}),
  )
  let live = true
  listCancels.push(() => { live = false })
  client.request<AppInfo[]>('apps.list', { node: n })
    .then((d) => { if (live) apps.value = d })
    .catch(() => {})
})

onBeforeUnmount(() => { stopProcs(); stopLists() })

// --- results ----------------------------------------------------------------

function go(path: string, query: Record<string, string> = {}) {
  const n = nodes.current
  void router.push({ path, query: n ? { ...query, node: n } : query })
}

const items = computed<Item[]>(() => {
  const text = q.value
  const out: Item[] = []
  const add = (item: Omit<Item, 'score'>, s: number) => { if (s >= 0) out.push({ ...item, score: s }) }

  for (const p of pages) {
    add({ key: `page:${p.name}`, group: 'pages', title: p.meta.title, subtitle: p.meta.subtitle,
          icon: p.meta.icon, run: () => go(p.path) },
        score(text, p.meta.title, p.meta.subtitle, p.name))
  }
  for (const n of nodes.list) {
    add({ key: `node:${n.node}`, group: 'nodes', title: n.node, status: n.status,
          subtitle: t(`palette.status.${n.status}`),
          tag: n.node === nodes.current ? t('palette.current') : undefined,
          run: () => nodes.select(n.node) },
        score(text, n.node))
  }
  if (text) {
    for (const p of procs.value) {
      add({ key: `proc:${p.pid}`, group: 'processes', title: p.name ?? p.pid,
            subtitle: p.name ? `${p.pid} · ${p.current_function}` : `${p.initial_call} · ${p.current_function}`,
            icon: GitNetworkOutline, run: () => go('/processes', { pid: p.pid }) },
          // The node already filtered these; keep its order (named first).
          0)
    }
    for (const e of ets.value) {
      add({ key: `ets:${e.id}`, group: 'tables', title: e.name,
            subtitle: `ETS · ${e.owner_name ?? e.owner ?? ''}`, icon: GridOutline,
            run: () => go('/tables', { table: e.id }) },
          score(text, e.name, e.named ? null : e.id))
    }
    for (const m of mnesia.value) {
      add({ key: `mnesia:${m.id}`, group: 'tables', title: m.name, subtitle: `Mnesia · ${m.storage}`,
            icon: GridOutline, run: () => go('/tables', { tab: 'mnesia', table: m.id }) },
          score(text, m.name, m.record_name))
    }
    for (const a of apps.value) {
      add({ key: `app:${a.name}`, group: 'apps', title: a.name,
            subtitle: a.running ? `${a.vsn} · ${a.description}` : `${a.vsn} · ${t('palette.not_running')}`,
            icon: AppsOutline, run: () => go('/applications', { app: a.name }) },
          score(text, a.name, a.description))
    }
  }
  const themeTitle = theme.isDark ? t('palette.actions.theme_light') : t('palette.actions.theme_dark')
  add({ key: 'act:theme', group: 'actions', title: themeTitle, icon: theme.isDark ? SunnyOutline : MoonOutline,
        run: () => theme.setMode(theme.isDark ? 'light' : 'dark') },
      score(text, themeTitle, 'theme dark light 主题 深色 浅色'))
  if (node.value) {
    add({ key: 'act:health', group: 'actions', title: t('palette.actions.health'),
          subtitle: t('palette.actions.health_sub'), icon: MedkitOutline,
          run: () => go('/diagnosis', { run: '1' }) },
        score(text, t('palette.actions.health'), 'health check diagnosis 体检 诊断'))
  }
  add({ key: 'act:connect', group: 'actions', title: t('palette.actions.connect'),
        subtitle: t('palette.actions.connect_sub'), icon: AddCircleOutline, run: () => ui.openConnect() },
      score(text, t('palette.actions.connect'), 'connect add node 连接 添加 节点'))

  const sorted: Item[] = []
  for (const g of GROUPS) {
    const inGroup = out.filter((i) => i.group === g)
    if (text) inGroup.sort((a, b) => b.score - a.score)
    sorted.push(...inGroup.slice(0, LIMIT[g]))
  }
  return sorted
})

// Rows with group headers in front of the first item of each group.
const rows = computed(() => {
  const res: ({ header: Group } | { item: Item; index: number })[] = []
  let last: Group | null = null
  items.value.forEach((item, index) => {
    if (item.group !== last) { res.push({ header: item.group }); last = item.group }
    res.push({ item, index })
  })
  return res
})

watch(items, () => { active.value = Math.min(active.value, Math.max(items.value.length - 1, 0)) })
watch(q, () => { active.value = 0 })

function choose(item: Item | undefined) {
  if (!item) return
  ui.paletteOpen = false
  item.run()
}

function move(delta: number) {
  const n = items.value.length
  if (!n) return
  active.value = (active.value + delta + n) % n
  void nextTick(() => {
    listEl.value?.querySelector(`[data-index="${active.value}"]`)?.scrollIntoView({ block: 'nearest' })
  })
}

function onKey(e: KeyboardEvent) {
  // Enter while an input method is composing picks the candidate, not a row.
  if (e.isComposing) return
  if (e.key === 'ArrowDown') { e.preventDefault(); move(1) }
  else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1) }
  else if (e.key === 'Enter') { e.preventDefault(); choose(items.value[active.value]) }
}

// An open drawer traps focus too, so focus the input explicitly.
const inputRef = ref<InstanceType<typeof NInput> | null>(null)
function focusInput() {
  inputRef.value?.focus()
}
watch(() => ui.paletteOpen, (open) => {
  if (!open) return
  query.value = ''
  active.value = 0
  void nextTick(focusInput)
})

function onGlobalKey(e: KeyboardEvent) {
  if ((e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey && e.key.toLowerCase() === 'k') {
    e.preventDefault()
    ui.paletteOpen = !ui.paletteOpen
  }
}
onMounted(() => window.addEventListener('keydown', onGlobalKey))
onBeforeUnmount(() => window.removeEventListener('keydown', onGlobalKey))

const showSpinner = computed(() => procLoading.value && !!node.value)
const vars = useThemeVars()
const cssVars = computed(() => ({
  '--palette-bg': vars.value.modalColor,
  '--palette-text': vars.value.textColor2,
  '--palette-active': vars.value.hoverColor,
  '--palette-border': vars.value.dividerColor,
}))
</script>

<template>
  <NModal v-model:show="ui.paletteOpen" transform-origin="center" @after-enter="focusInput">
    <div class="palette" :style="cssVars" role="dialog" :aria-label="t('palette.open')">
      <NInput ref="inputRef" v-model:value="query" size="large" :placeholder="t('palette.placeholder')" clearable
              autofocus class="palette-input" @keydown="onKey">
        <template #prefix><NIcon :component="SearchOutline" /></template>
        <template #suffix><NSpin v-if="showSpinner" :size="14" /></template>
      </NInput>
      <div ref="listEl" class="palette-list">
        <template v-for="r in rows" :key="'header' in r ? `h:${r.header}` : r.item.key">
          <div v-if="'header' in r" class="palette-group">{{ t(`palette.groups.${r.header}`) }}</div>
          <div v-else class="palette-item" :class="{ active: r.index === active }" :data-index="r.index"
               @mousemove="active = r.index" @click="choose(r.item)">
            <span class="palette-icon">
              <StatusDot v-if="r.item.status" :status="r.item.status" />
              <NIcon v-else-if="r.item.icon" :component="r.item.icon" :size="16" />
              <NIcon v-else :component="ServerOutline" :size="16" />
            </span>
            <span class="palette-title" :class="{ mono: r.item.group !== 'pages' && r.item.group !== 'actions' }">
              {{ r.item.title }}
            </span>
            <span v-if="r.item.tag" class="palette-tag">{{ r.item.tag }}</span>
            <span v-if="r.item.subtitle" class="palette-sub">{{ r.item.subtitle }}</span>
          </div>
        </template>
        <div v-if="!items.length" class="palette-empty">{{ t('palette.empty') }}</div>
        <div v-if="q && !node" class="palette-note">{{ t('palette.no_node') }}</div>
      </div>
      <div class="palette-foot">{{ t('palette.hint') }}</div>
    </div>
  </NModal>
</template>

<style scoped>
.palette {
  align-self: flex-start;
  margin: 12vh auto auto;
  width: 640px;
  max-width: calc(100vw - 32px);
  background: var(--palette-bg);
  color: var(--palette-text);
  border-radius: 10px;
  box-shadow: 0 12px 48px rgba(0, 0, 0, 0.28);
  overflow: hidden;
  display: flex;
  flex-direction: column;
}
.palette-input {
  margin: 12px 12px 4px;
  width: auto;
}
.palette-list {
  max-height: min(60vh, 520px);
  overflow-y: auto;
  padding: 4px 8px 8px;
}
.palette-group {
  font-size: 12px;
  font-weight: 600;
  opacity: 0.55;
  padding: 10px 10px 4px;
}
.palette-item {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 7px 10px;
  border-radius: 6px;
  cursor: pointer;
  min-width: 0;
}
.palette-item.active {
  background: var(--palette-active);
}
.palette-icon {
  width: 18px;
  display: inline-flex;
  justify-content: center;
  flex: none;
  opacity: 0.8;
}
.palette-title {
  flex: none;
  max-width: 60%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.palette-tag {
  flex: none;
  font-size: 11px;
  line-height: 16px;
  padding: 0 6px;
  border-radius: 8px;
  border: 1px solid currentColor;
  opacity: 0.55;
}
.palette-sub {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 12px;
  opacity: 0.55;
}
.palette-empty, .palette-note {
  padding: 16px 10px;
  text-align: center;
  font-size: 13px;
  opacity: 0.6;
}
.palette-note {
  padding-top: 4px;
}
.palette-foot {
  font-size: 12px;
  opacity: 0.5;
  padding: 8px 16px;
  border-top: 1px solid var(--palette-border);
}
</style>
