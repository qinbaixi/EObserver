<script setup lang="ts">
import { useRoute, useRouter, type LocationQueryRaw } from 'vue-router'
import { useQueryRef } from '../composables/useQueryRef'
import { computed, h, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import {
  NDataTable, NInput, NIcon, NAlert, NTag, NTabs, NTabPane, NSwitch, NSpace, NEmpty,
  type DataTableColumns,
} from 'naive-ui'
import { SearchOutline } from '@vicons/ionicons5'
import { useNodes } from '../stores/nodes'
import { useTopic } from '../composables/useTopic'
import type { EtsTable, MnesiaTable } from '../api/types'
import { formatBytes, formatNumber } from '../api/format'
import PageHeader from '../components/PageHeader.vue'
import RefreshControl from '../components/RefreshControl.vue'
import NodeGuard from '../components/NodeGuard.vue'
import ProcessDrawer from '../components/ProcessDrawer.vue'
import TableRowsDrawer from '../components/TableRowsDrawer.vue'
import { term } from '../api/term'
import { useResizableTable } from '../api/table'

const { t } = useI18n()
const nodes = useNodes()
const node = computed(() =>
  nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)

const route = useRoute()
const router = useRouter()
const tab = computed<'ets' | 'mnesia'>({
  get: () => (route.query.tab === 'mnesia' ? 'mnesia' : 'ets'),
  set: (v) => {
    const query: Record<string, unknown> = { ...route.query, tab: v === 'ets' ? undefined : v }
    delete query.table
    void router.replace({ query: query as LocationQueryRaw })
  },
})
const etsNode = computed(() => (tab.value === 'ets' ? node.value : null))
const mnesiaNode = computed(() => (tab.value === 'mnesia' ? node.value : null))
const ets = useTopic<EtsTable[]>('node.ets', etsNode, 5000)
const mnesia = useTopic<MnesiaTable[]>('node.mnesia', mnesiaNode, 5000)
const active = computed(() => (tab.value === 'ets' ? ets : mnesia))

const search = ref('')
const showSystem = ref(false)
const selectedPid = useQueryRef('pid')
const openedId = useQueryRef('table')
const openedTitle = computed(() => {
  const id = openedId.value
  const list: { id: string; name: string }[] = (tab.value === 'ets' ? ets.data.value : mnesia.data.value) ?? []
  return list.find((x) => x.id === id)?.name ?? id ?? undefined
})

const match = (q: string, ...texts: (string | null)[]) =>
  !q || texts.some((t) => t?.toLowerCase().includes(q))

const etsRows = computed(() => {
  const q = search.value.trim().toLowerCase()
  return (ets.data.value ?? []).filter((x) =>
    (showSystem.value || !x.system) && match(q, x.name, x.id, x.owner, x.owner_name))
})
const hiddenSystem = computed(() => (ets.data.value ?? []).filter((x) => x.system).length)

const mnesiaRows = computed(() => {
  const q = search.value.trim().toLowerCase()
  return (mnesia.data.value ?? []).filter((x) => match(q, x.name, x.record_name))
})
const mnesiaOff = computed(() => mnesia.error.value?.includes('not_running') ?? false)

const num = (a: number, b: number) => a - b
const mono = (text: string | number) => h('span', { class: 'mono' }, text)

const etsColumns = computed<DataTableColumns<EtsTable>>(() => [
  { key: 'name', title: t('procs.tables.col.table'), minWidth: 220, ellipsis: { tooltip: true },
    sorter: (a, b) => a.name.localeCompare(b.name),
    render: (r) => h('span', { class: 'mono' }, [
      h('b', null, r.name),
      r.named ? null : h('span', { class: 'muted' }, ` ${r.id}`),
    ]) },
  { key: 'type', title: t('procs.tables.col.type'), width: 110,
    render: (r) => h(NTag, { size: 'small', bordered: false }, { default: () => r.type }) },
  { key: 'size', title: term('对象数'), width: 110, align: 'right', sorter: (a, b) => num(a.size, b.size),
    render: (r) => mono(formatNumber(r.size)) },
  { key: 'memory', title: term('内存', t('procs.tables.memory_tip'), 'ets'), width: 110, align: 'right', sorter: (a, b) => num(a.memory, b.memory),
    defaultSortOrder: 'descend', render: (r) => mono(formatBytes(r.memory)) },
  { key: 'owner', title: term('所属进程'), minWidth: 200, ellipsis: { tooltip: true },
    render: (r) => r.owner
      ? h('a', { class: 'mono link', onClick: (e: Event) => { e.stopPropagation(); selectedPid.value = r.owner } },
          r.owner_name ?? r.owner)
      : '-' },
  { key: 'protection', title: term('访问'), width: 100,
    render: (r) => h(NTag, { size: 'small', bordered: false, type: r.protection === 'private' ? 'warning' : r.protection === 'public' ? 'success' : 'default' },
      { default: () => r.protection }) },
  { key: 'keypos', title: term('keypos'), width: 80, align: 'right', render: (r) => mono(r.keypos) },
  { key: 'opts', title: term('选项'), width: 200,
    render: (r) => h(NSpace, { size: 4 }, () => [
      r.read_concurrency ? h(NTag, { size: 'tiny', bordered: false }, { default: () => 'read_conc' }) : null,
      r.write_concurrency !== 'false' ? h(NTag, { size: 'tiny', bordered: false }, { default: () => `write_conc` }) : null,
      r.compressed ? h(NTag, { size: 'tiny', bordered: false }, { default: () => 'compressed' }) : null,
    ]) },
])

const mnesiaColumns = computed<DataTableColumns<MnesiaTable>>(() => [
  { key: 'name', title: t('procs.tables.col.table'), minWidth: 200, sorter: (a, b) => a.name.localeCompare(b.name),
    render: (r) => h('b', { class: 'mono' }, r.name) },
  { key: 'storage', title: term('存储'), width: 140,
    render: (r) => h(NTag, { size: 'small', bordered: false, type: r.storage === 'ram_copies' ? 'info' : 'success' },
      { default: () => r.storage }) },
  { key: 'type', title: t('procs.tables.col.type'), width: 100, render: (r) => r.type },
  { key: 'size', title: t('procs.tables.col.records'), width: 110, align: 'right', sorter: (a, b) => num(a.size, b.size),
    render: (r) => mono(formatNumber(r.size)) },
  { key: 'memory', title: term('内存', t('procs.tables.memory_tip')), width: 110, align: 'right', sorter: (a, b) => num(a.memory, b.memory),
    render: (r) => mono(formatBytes(r.memory)) },
  { key: 'record_name', title: t('procs.tables.col.record'), width: 140, render: (r) => mono(r.record_name) },
  { key: 'attributes', title: t('procs.tables.col.fields'), minWidth: 240, ellipsis: { tooltip: true },
    render: (r) => h('span', { class: 'mono muted' }, r.attributes.join(', ')) },
  { key: 'where_to_read', title: term('读取节点'), width: 280, ellipsis: { tooltip: true },
    render: (r) => h('span', { class: 'mono muted' }, r.where_to_read) },
])

const etsRowProps = (r: EtsTable) => ({
  style: 'cursor: pointer',
  onClick: () => { openedId.value = r.id },
})
const mnesiaRowProps = (r: MnesiaTable) => ({
  style: 'cursor: pointer',
  onClick: () => { openedId.value = r.id },
})

const subtitle = computed(() => {
  if (tab.value === 'ets' && ets.data.value) return t('procs.tables.ets_count', { n: formatNumber(etsRows.value.length) }, etsRows.value.length)
  if (tab.value === 'mnesia' && mnesia.data.value) return t('procs.tables.mnesia_count', { n: formatNumber(mnesiaRows.value.length) }, mnesiaRows.value.length)
  return nodes.current ?? undefined
})
const etsTable = useResizableTable(etsColumns)
const mnesiaTable = useResizableTable(mnesiaColumns)
</script>

<template>
  <PageHeader :title="t('procs.tables.title')" :subtitle="subtitle">
    <NSpace align="center" :size="16">
      <label v-if="tab === 'ets'" class="toggle">
        <NSwitch v-model:value="showSystem" size="small" />
        <span>{{ hiddenSystem ? t('procs.tables.show_system_n', { n: hiddenSystem }) : t('procs.tables.show_system') }}</span>
      </label>
      <NInput v-model:value="search" clearable :placeholder="t('procs.tables.filter')" style="width: 260px">
        <template #prefix><NIcon :component="SearchOutline" /></template>
      </NInput>
      <RefreshControl v-model:paused="active.paused.value" v-model:interval="active.interval.value"
                      @refresh="active.refresh" />
    </NSpace>
  </PageHeader>
  <NodeGuard>
    <NTabs v-model:value="tab" type="line" animated>
      <NTabPane name="ets" tab="ETS">
        <NAlert v-if="ets.error.value" type="error" style="margin-bottom: 12px">{{ ets.error.value }}</NAlert>
        <NDataTable v-bind="etsTable" :data="etsRows" :loading="!ets.data.value && !ets.error.value"
                    size="small" :row-key="(r: EtsTable) => r.id" :row-props="etsRowProps" :pagination="{ pageSize: 50 }" />
      </NTabPane>
      <NTabPane name="mnesia" tab="Mnesia">
        <NEmpty v-if="mnesiaOff" :description="t('procs.tables.no_mnesia')" style="padding: 64px 0" />
        <template v-else>
          <NAlert v-if="mnesia.error.value" type="error" style="margin-bottom: 12px">{{ mnesia.error.value }}</NAlert>
          <NDataTable v-bind="mnesiaTable" :data="mnesiaRows"
                      :loading="!mnesia.data.value && !mnesia.error.value" size="small"
                      :row-key="(r: MnesiaTable) => r.id" :row-props="mnesiaRowProps" :pagination="{ pageSize: 50 }" />
        </template>
      </NTabPane>
    </NTabs>
    <template v-if="node">
      <TableRowsDrawer v-model:table="openedId" :node="node" :kind="tab"
                       :title="openedTitle" />
      <ProcessDrawer v-model:pid="selectedPid" :node="node" />
    </template>
  </NodeGuard>
</template>

<style scoped>
.toggle { display: flex; align-items: center; gap: 8px; font-size: 13px; cursor: pointer; }
:deep(.muted) { opacity: 0.6; }
:deep(.link) { cursor: pointer; }
:deep(.link:hover) { text-decoration: underline; }
</style>
