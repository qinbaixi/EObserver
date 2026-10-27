<script setup lang="ts">
import { computed, provide, reactive, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { NTabs, NTabPane, NAlert, NDropdown, NButton, NIcon, NGrid, NGi, NCard, NTag } from 'naive-ui'
import { ChevronDown } from '@vicons/ionicons5'
import type { DumpInfo, DumpTarget } from '../../api/dump'
import { formatBytes } from '../../api/format'
import { useQueryRef } from '../../composables/useQueryRef'
import { NAV, type DumpNav } from './cells'
import DumpOverview from './DumpOverview.vue'
import DumpTable from './DumpTable.vue'
import DumpProgress from './DumpProgress.vue'
import DumpProcessDrawer from './DumpProcessDrawer.vue'
import DumpDetailDrawer from './DumpDetailDrawer.vue'
import DumpSearch from './DumpSearch.vue'

// One open dump: scan progress, then the overview and the detail tables.
// The tab, the open process and the open detail live in the URL.
const props = defineProps<{ info: DumpInfo }>()
const emit = defineEmits<{ cancel: [] }>()
const { t, te } = useI18n()

const MAIN = ['overview', 'processes', 'ports', 'ets', 'memory'] as const
const MORE = ['timers', 'schedulers', 'nodes', 'modules', 'funs', 'atoms', 'persistent_terms', 'hash_tables', 'index_tables', 'internal_tables'] as const
const ALL: readonly string[] = [...MAIN, ...MORE]

// Clicking a row opens this detail (kind for dump.detail, key column).
const DETAIL: Record<string, { kind: string; field?: string }> = {
  processes: { kind: 'process', field: 'pid' },
  ports: { kind: 'port', field: 'id' },
  ets: { kind: 'ets', field: 'table' },
  nodes: { kind: 'node', field: 'channel' },
  modules: { kind: 'module', field: 'name' },
  schedulers: { kind: 'scheduler', field: 'id' },
  timers: { kind: 'timer', field: 'owner' },
  allocators: { kind: 'allocator', field: 'name' },
}
const DETAIL_KINDS = new Set(['port', 'ets', 'node', 'module', 'scheduler', 'timer', 'allocator'])
const TAB_OF: Record<string, string> = {
  process: 'processes', port: 'ports', atom: 'atoms', fun: 'funs', timer: 'timers', scheduler: 'schedulers',
  persistent_term: 'persistent_terms', allocators: 'memory', memory: 'memory',
}

const tabRef = useQueryRef('tab')
const tab = computed({
  get: () => (ALL.includes(tabRef.value ?? '') ? tabRef.value! : 'overview'),
  set: (v: string) => { tabRef.value = v === 'overview' ? null : v },
})
const pid = useQueryRef('pid')
const objRef = useQueryRef('obj')
const obj = computed<DumpTarget | null>({
  get: () => {
    const v = objRef.value
    const i = v ? v.indexOf(':') : -1
    return v && i > 0 ? { kind: v.slice(0, i), key: v.slice(i + 1) } : null
  },
  set: (tg) => { objRef.value = tg ? `${tg.kind}:${tg.key}` : null },
})

const filters = reactive<Record<string, string>>({})
// A sort asked for from the overview ("all" next to a top list).
const sorts = reactive<Record<string, string>>({})
const wordSize = ref(8)

function open(tg: DumpTarget) {
  if (tg.kind === 'process' || tg.kind === 'pid') pid.value = tg.key
  else if (DETAIL_KINDS.has(tg.kind)) obj.value = { kind: tg.kind, key: tg.key }
  else {
    const to = TAB_OF[tg.kind] ?? (ALL.includes(tg.kind) ? tg.kind : null)
    if (to) {
      if (to !== 'memory') filters[to] = tg.key
      tab.value = to
    } else obj.value = { kind: tg.kind, key: tg.key }
  }
}

const nav: DumpNav = { open, wordSize: () => wordSize.value }
provide(NAV, nav)

function goTab(to: string, sort?: string) {
  tab.value = to
  if (sort) sorts[to] = sort
}

const moreOptions = computed(() => MORE.map((k) => ({ key: k, label: t(`crashdump.tabs.${k}`) })))
const inMore = computed(() => (MORE as readonly string[]).includes(tab.value))

const failText = computed(() => {
  const e = props.info.error
  if (!e) return t('crashdump.failed.text')
  return te(`crashdump.errors.${e}`) ? t(`crashdump.errors.${e}`) : String(e)
})

const scanning = computed(() => props.info.status === 'scanning')
const version = computed(() => props.info.status)
</script>

<template>
  <div class="dump-view">
    <DumpProgress v-if="scanning" :info="info" @cancel="emit('cancel')" />
    <NAlert v-else-if="info.status === 'failed'" type="error" :title="t('crashdump.failed.title')" class="banner">
      {{ failText }}
    </NAlert>
    <NAlert v-else-if="info.status === 'cancelled'" type="default" class="banner">{{ t('crashdump.cancelled') }}</NAlert>
    <NAlert v-if="info.truncated" type="warning" :title="t('crashdump.truncated.title')" class="banner">
      {{ t('crashdump.truncated.text', { at: formatBytes(info.scanned || info.size), tag: info.last_tag ?? '?' }) }}
    </NAlert>
    <NAlert v-if="info.skipped > 0 && !scanning" type="info" class="banner" :show-icon="true">
      {{ t('crashdump.skipped', { n: info.skipped }) }}
    </NAlert>

    <NTabs v-model:value="tab" type="line" animated display-directive="show:lazy" class="tabs">
      <template #suffix>
        <div class="suffix">
          <NDropdown trigger="click" :options="moreOptions" :value="tab" @select="(k: string) => (tab = k)">
            <NButton quaternary size="small" :type="inMore ? 'primary' : 'default'">
              {{ t('crashdump.tabs.more') }}
              <NIcon :component="ChevronDown" style="margin-left: 4px" />
            </NButton>
          </NDropdown>
          <DumpSearch :id="info.id" @go="open" />
        </div>
      </template>
      <NTabPane name="overview" :tab="t('crashdump.tabs.overview')">
        <DumpOverview :id="info.id" :info="info" @tab="goTab" />
      </NTabPane>
      <NTabPane v-for="k in MAIN.filter((x) => x !== 'overview' && x !== 'memory')" :key="k" :name="k" :tab="t(`crashdump.tabs.${k}`)">
        <DumpTable :id="info.id" :key="`${k}:${sorts[k] ?? ''}`" :kind="k" :sort="sorts[k] ?? null" :version="version" :filter="filters[k] ?? ''"
                   :detail="DETAIL[k] ?? null" />
      </NTabPane>
      <NTabPane name="memory" :tab="t('crashdump.tabs.memory')">
        <NGrid :cols="5" :x-gap="16" :y-gap="16" responsive="screen" item-responsive>
          <NGi span="5 l:2">
            <NCard size="small" :title="t('crashdump.memory.summary')">
              <DumpTable :id="info.id" kind="memory" :version="version" compact :page-size="25" />
            </NCard>
          </NGi>
          <NGi span="5 l:3">
            <NCard size="small" :title="t('crashdump.memory.allocators')">
              <DumpTable :id="info.id" kind="allocators" :version="version" compact :page-size="25" :detail="DETAIL.allocators" />
            </NCard>
          </NGi>
        </NGrid>
      </NTabPane>
      <NTabPane v-for="k in MORE" :key="k" :name="k" :tab="t(`crashdump.tabs.${k}`)" :tab-props="{ class: 'hidden-tab' }"
                :disabled="tab !== k">
        <DumpTable :id="info.id" :kind="k" :version="version" :filter="filters[k] ?? ''" :detail="DETAIL[k] ?? null">
          <NTag size="small" :bordered="false">{{ t(`crashdump.tabs.${k}`) }}</NTag>
          <span class="tab-note">{{ t(`crashdump.tab_notes.${k}`) }}</span>
        </DumpTable>
      </NTabPane>
    </NTabs>

    <DumpProcessDrawer :id="info.id" v-model:pid="pid" />
    <DumpDetailDrawer :id="info.id" v-model:target="obj" />
  </div>
</template>

<style scoped>
.banner {
  margin-bottom: 12px;
}
.suffix {
  display: flex;
  align-items: center;
  gap: 8px;
  padding-left: 12px;
}
.tab-note {
  font-size: 12px;
  opacity: 0.55;
}
/* The rarely used tables are reached from "More"; only the open one shows a tab. */
.tabs :deep(.hidden-tab:not(.n-tabs-tab--active)) {
  display: none;
}
.tabs :deep(.n-tabs-tab-wrapper:has(> .hidden-tab:not(.n-tabs-tab--active))) {
  display: none;
}
</style>
