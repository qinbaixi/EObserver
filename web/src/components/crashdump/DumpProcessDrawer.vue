<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import {
  NDrawer, NDrawerContent, NTabs, NTabPane, NTag, NButton, NEmpty, NSpin, NAlert,
} from 'naive-ui'
import { dumpRequest, isTerm, type DictItem, type DumpProcess, type DumpTerm, type StackItem } from '../../api/dump'
import { errorText } from '../../api/errors'
import { formatNumber } from '../../api/format'
import DumpTermBlock from './DumpTermBlock.vue'
import { formatValue, infoLabel, keyType, PID_RE, PORT_RE, refLink, useNav } from './cells'

// A process from the dump: its fields, then the message queue, dictionary
// and stack, each fetched page by page (they can be huge).
const props = defineProps<{ id: string; pid: string | null }>()
const emit = defineEmits<{ 'update:pid': [string | null] }>()
const { t, te } = useI18n()
const nav = useNav()

const PAGE = 50
type Part = 'messages' | 'dictionary' | 'stack'
const detail = ref<DumpProcess | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)
const tab = ref<'overview' | Part>('overview')
const history = ref<string[]>([])
const parts = reactive<Record<Part, { items: unknown[]; total: number; loading: boolean; error: string | null; loaded: boolean }>>({
  messages: { items: [], total: 0, loading: false, error: null, loaded: false },
  dictionary: { items: [], total: 0, loading: false, error: null, loaded: false },
  stack: { items: [], total: 0, loading: false, error: null, loaded: false },
})

const show = computed({
  get: () => props.pid !== null,
  set: (v) => { if (!v) { history.value = []; emit('update:pid', null) } },
})

function resetParts() {
  for (const p of Object.values(parts)) Object.assign(p, { items: [], total: 0, loading: false, error: null, loaded: false })
}

async function load() {
  const pid = props.pid
  if (!pid) return
  loading.value = true
  error.value = null
  try {
    const d = await dumpRequest<DumpProcess>('dump.process', { id: props.id, pid })
    if (props.pid !== pid) return
    detail.value = d
  } catch (e) {
    detail.value = null
    error.value = errorText(e)
  } finally {
    loading.value = false
  }
}

async function loadPart(part: Part, more = false) {
  const pid = props.pid
  const p = parts[part]
  if (!pid || p.loading) return
  p.loading = true
  try {
    const res = await dumpRequest<{ total: number; items: unknown[] }>('dump.process_part',
      { id: props.id, pid, part, offset: more ? p.items.length : 0, limit: PAGE })
    if (props.pid !== pid) return
    p.items = more ? [...p.items, ...res.items] : res.items
    p.total = res.total
    p.loaded = true
    p.error = null
  } catch (e) {
    p.error = errorText(e)
  } finally {
    p.loading = false
  }
}

watch(() => props.pid, () => {
  tab.value = 'overview'
  detail.value = null
  resetParts()
  void load()
}, { immediate: true })

watch(tab, (v) => { if (v !== 'overview' && !parts[v].loaded) void loadPart(v) })

function go(ref: string) {
  if (PID_RE.test(ref)) {
    if (ref === props.pid) return
    if (props.pid) history.value.push(props.pid)
    emit('update:pid', ref)
  } else if (PORT_RE.test(ref)) {
    nav.open({ kind: 'port', key: ref })
  }
}
function back() {
  const prev = history.value.pop()
  if (prev) emit('update:pid', prev)
}

const s = computed(() => detail.value?.summary ?? {})
const name = computed(() => String(s.value.name || s.value.registered_name || ''))
const state = computed(() => String(s.value.state ?? ''))
const stateType = computed(() => {
  const st = state.value.toLowerCase()
  return st === 'running' ? 'success' : st === 'garbing' || st === 'runnable' ? 'warning' : st === 'exiting' ? 'error' : 'default'
})

const notes = computed(() => (detail.value?.notes ?? []).filter((n) => te(`crashdump.proc.notes.${n}`)))
const info = computed(() => (detail.value?.info ?? []).filter((f) => f.value !== null && f.value !== undefined && f.value !== ''))

// The backend may type each field (text / int / bytes / pid); otherwise
// the type is guessed from the key.
function infoValue(key: string, v: unknown, type?: string) {
  if (isTerm(v)) return v.text
  const ty = type === 'int' || type === 'bytes' || type === 'words' || type === 'ms' ? type : type === 'text' ? 'text' : keyType(key)
  return formatValue(ty, v, nav.wordSize())
}

const groups = computed(() => {
  const d = detail.value
  if (!d) return []
  return [
    { key: 'links', items: d.links ?? [] },
    { key: 'monitors', items: d.monitors ?? [] },
    { key: 'monitored_by', items: d.monitored_by ?? [] },
  ]
})

const tabLabel = (part: Part) => {
  const n = detail.value?.parts?.[part]
  return t(`crashdump.proc.tabs.${part}`) + (typeof n === 'number' ? ` (${formatNumber(n)})` : '')
}

const STACK_TAG: Record<string, 'default' | 'info' | 'warning' | 'success'> = { frame: 'default', return: 'info', catch: 'warning', var: 'success' }
const asTerm = (v: unknown) => v as DumpTerm
const asDict = (v: unknown) => v as DictItem
const asStack = (v: unknown) => v as StackItem
</script>

<template>
  <NDrawer v-model:show="show" :width="760" placement="right">
    <NDrawerContent :native-scrollbar="false" closable>
      <template #header>
        <div class="head">
          <NButton v-if="history.length" size="tiny" quaternary @click="back">{{ t('crashdump.back') }}</NButton>
          <span class="mono">{{ pid }}</span>
          <NTag v-if="name" size="small" type="primary" :bordered="false">{{ name }}</NTag>
          <NTag v-if="state" size="small" :type="stateType" :bordered="false">{{ state }}</NTag>
        </div>
      </template>

      <NSpin v-if="loading && !detail" style="width: 100%; padding: 60px 0" />
      <NEmpty v-else-if="error === 'not_found'" :description="t('crashdump.proc.not_found')" style="padding: 60px 0" />
      <NAlert v-else-if="error" type="error">{{ error }}</NAlert>
      <NTabs v-else-if="detail" v-model:value="tab" type="line" animated>
        <NTabPane name="overview" :tab="t('crashdump.proc.tabs.overview')">
          <NAlert v-for="n in notes" :key="n" :type="n === 'garbing' ? 'warning' : 'info'" class="note-alert" :show-icon="true">
            {{ t(`crashdump.proc.notes.${n}`) }}
          </NAlert>
          <table class="kv">
            <tr v-for="f in info" :key="f.key">
              <td class="k">{{ infoLabel(f.key) }}</td>
              <td>
                <component :is="() => refLink(String(f.value), nav)" v-if="typeof f.value === 'string' && (PID_RE.test(f.value) || PORT_RE.test(f.value))" />
                <span v-else class="mono v">{{ infoValue(f.key, f.value, f.type) }}</span>
              </td>
            </tr>
            <tr v-if="detail.parent">
              <td class="k">{{ t('crashdump.proc.parent') }}</td>
              <td><component :is="() => refLink(String(detail!.parent), nav)" /></td>
            </tr>
          </table>
          <div v-for="g in groups" :key="g.key" class="group">
            <div class="group-title">{{ t(`crashdump.proc.${g.key}`) }} <span class="count">{{ g.items.length }}</span></div>
            <div v-if="g.items.length" class="chips">
              <NTag v-for="r in g.items" :key="r" size="small" class="mono"
                    :class="{ clickable: PID_RE.test(r) || PORT_RE.test(r) }" @click="go(r)">{{ r }}</NTag>
            </div>
            <div v-else class="none">{{ t('crashdump.none') }}</div>
          </div>
        </NTabPane>

        <NTabPane v-for="part in (['messages', 'dictionary', 'stack'] as const)" :key="part" :name="part" :tab="tabLabel(part)">
          <NAlert v-if="parts[part].error" type="error">{{ parts[part].error }}</NAlert>
          <NSpin v-else-if="!parts[part].loaded" style="width: 100%; padding: 40px 0" :description="t('crashdump.proc.loading')" />
          <NEmpty v-else-if="!parts[part].items.length" :description="t(`crashdump.proc.empty.${part}`)" style="padding: 40px 0" />
          <template v-else>
            <div v-if="part === 'messages'" class="terms">
              <div v-for="(m, i) in parts.messages.items" :key="i" class="msg">
                <span class="idx mono">{{ i + 1 }}</span>
                <DumpTermBlock :id="id" :term="asTerm(m)" class="grow" />
              </div>
            </div>
            <table v-else-if="part === 'dictionary'" class="kv">
              <tr v-for="(d, i) in parts.dictionary.items" :key="i">
                <td class="k"><DumpTermBlock :id="id" :term="asDict(d).key" inline /></td>
                <td><DumpTermBlock :id="id" :term="asDict(d).value" /></td>
              </tr>
            </table>
            <table v-else class="kv stack">
              <tr v-for="(f, i) in parts.stack.items" :key="i" :class="asStack(f).kind">
                <td class="mono addr">{{ asStack(f).addr }}</td>
                <td class="kind"><NTag size="tiny" :bordered="false" :type="STACK_TAG[asStack(f).kind] ?? 'default'">{{ t(`crashdump.proc.stack_kind.${asStack(f).kind}`) }}</NTag></td>
                <td class="v">
                  <DumpTermBlock v-if="asStack(f).term" :id="id" :term="asStack(f).term!" inline />
                  <span v-else class="mono">{{ asStack(f).text }}</span>
                </td>
              </tr>
            </table>
            <div v-if="parts[part].items.length < parts[part].total" class="load-more">
              <span class="count">{{ t('crashdump.proc.shown', { n: formatNumber(parts[part].items.length), total: formatNumber(parts[part].total) }) }}</span>
              <NButton size="small" :loading="parts[part].loading" @click="loadPart(part, true)">{{ t('crashdump.proc.more') }}</NButton>
            </div>
          </template>
        </NTabPane>
      </NTabs>
    </NDrawerContent>
  </NDrawer>
</template>

<style scoped>
.note-alert {
  margin-bottom: 10px;
}
.head {
  display: flex;
  align-items: center;
  gap: 8px;
}
.group {
  margin-top: 20px;
}
.group-title {
  font-weight: 600;
  margin-bottom: 8px;
}
.count, .none, .note {
  opacity: 0.55;
  font-size: 13px;
}
.note {
  margin-top: 20px;
}
.chips {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}
.clickable {
  cursor: pointer;
}
.clickable:hover {
  text-decoration: underline;
}
.kv {
  width: 100%;
  border-collapse: collapse;
  font-size: 13px;
}
.kv td {
  padding: 6px 8px;
  vertical-align: top;
  border-bottom: 1px solid rgba(128, 128, 128, 0.15);
}
.kv .k {
  width: 34%;
  opacity: 0.75;
  word-break: break-all;
}
.v {
  word-break: break-all;
  white-space: pre-wrap;
}
.terms {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.msg {
  display: flex;
  gap: 10px;
  align-items: flex-start;
}
.idx {
  flex: none;
  width: 40px;
  text-align: right;
  font-size: 12px;
  opacity: 0.45;
  padding-top: 8px;
}
.grow {
  flex: 1;
  min-width: 0;
}
.stack .addr {
  width: 150px;
  font-size: 12px;
  opacity: 0.5;
  white-space: nowrap;
}
.stack .kind {
  width: 70px;
}
.stack tr.return td, .stack tr.catch td {
  font-weight: 600;
}
.load-more {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-top: 12px;
}
</style>
