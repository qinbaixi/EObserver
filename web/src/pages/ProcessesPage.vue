<script setup lang="ts">
import { computed, h, onBeforeUnmount, ref, watch } from 'vue'
import {
  NDataTable, NInput, NSpace, NSelect, NTag, NIcon, NButton, NAlert,
  type DataTableColumns, type DataTableSortState,
} from 'naive-ui'
import { SearchOutline, PauseOutline, PlayOutline } from '@vicons/ionicons5'
import { client } from '../api/ws'
import { useNodes } from '../stores/nodes'
import type { ProcessPage, ProcessRow } from '../api/types'
import { formatBytes, formatNumber } from '../api/format'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'
import ProcessDrawer from '../components/ProcessDrawer.vue'

type SortKey = 'reds' | 'reductions' | 'memory' | 'message_queue_len' | 'name' | 'pid'

const nodes = useNodes()
const node = computed(() =>
  nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)

const filterInput = ref('')
const filter = ref('')
const sortKey = ref<SortKey>('reds')
const sortOrder = ref<'asc' | 'desc'>('desc')
const page = ref(1)
const pageSize = ref(50)
const interval = ref(2000)
const paused = ref(false)
const data = ref<ProcessPage | null>(null)
const error = ref<string | null>(null)
const selected = ref<string | null>(null)

let debounce: number | undefined
watch(filterInput, (v) => {
  clearTimeout(debounce)
  debounce = window.setTimeout(() => { filter.value = v.trim(); page.value = 1 }, 300)
})

const params = computed(() => ({
  node: node.value,
  sort: sortKey.value,
  order: sortOrder.value,
  filter: filter.value,
  offset: (page.value - 1) * pageSize.value,
  limit: pageSize.value,
}))

let stop: (() => void) | null = null
function subscribe(once = false) {
  stop?.()
  stop = null
  if (!node.value) return
  const unsub = client.subscribe('node.processes', params.value, interval.value, (d: ProcessPage) => {
    data.value = d
    error.value = null
    if (once) { unsub(); if (stop === unsub) stop = null }
  }, (e) => { error.value = e })
  stop = unsub
}

watch([params, interval], () => { if (!paused.value) subscribe() }, { immediate: true })
watch(paused, (p) => (p ? (stop?.(), (stop = null)) : subscribe()))
watch(() => nodes.current, () => { data.value = null; selected.value = null; page.value = 1 })
onBeforeUnmount(() => stop?.())

function refreshOnce() {
  subscribe(true)
}

function onSort(s: DataTableSortState | null) {
  if (!s || !s.order) {
    sortKey.value = 'reds'
    sortOrder.value = 'desc'
  } else {
    sortKey.value = s.columnKey as SortKey
    sortOrder.value = s.order === 'ascend' ? 'asc' : 'desc'
  }
  page.value = 1
}

function sorter(key: SortKey) {
  return {
    sorter: true as const,
    sortOrder: sortKey.value === key ? (sortOrder.value === 'asc' ? 'ascend' as const : 'descend' as const) : false as const,
  }
}

function queueClass(n: number) {
  return n >= 1000 ? 'q-bad' : n > 0 ? 'q-warn' : 'q-zero'
}

const columns = computed<DataTableColumns<ProcessRow>>(() => [
  {
    key: 'pid', title: 'PID', width: 120, ...sorter('pid'),
    render: (r) => h('span', { class: 'mono pid' }, r.pid),
  },
  {
    key: 'name', title: '名称 / 初始调用', minWidth: 220, ellipsis: { tooltip: true }, ...sorter('name'),
    render: (r) => r.name
      ? h('span', { class: 'name' }, r.name)
      : h('span', { class: 'mono muted' }, r.initial_call),
  },
  {
    key: 'reds', title: 'Reds', width: 110, align: 'right', ...sorter('reds'),
    render: (r) => h('span', { class: 'mono' }, r.reds == null ? '-' : formatNumber(r.reds)),
  },
  {
    key: 'reductions', title: 'Reductions', width: 140, align: 'right', ...sorter('reductions'),
    render: (r) => h('span', { class: 'mono muted' }, formatNumber(r.reductions)),
  },
  {
    key: 'memory', title: '内存', width: 110, align: 'right', ...sorter('memory'),
    render: (r) => h('span', { class: 'mono' }, formatBytes(r.memory)),
  },
  {
    key: 'message_queue_len', title: '消息队列', width: 110, align: 'right', ...sorter('message_queue_len'),
    render: (r) => h('span', { class: ['mono', queueClass(r.message_queue_len)] }, formatNumber(r.message_queue_len)),
  },
  {
    key: 'current_function', title: '当前函数', minWidth: 220, ellipsis: { tooltip: true },
    render: (r) => h('span', { class: 'mono muted' }, r.current_function),
  },
  {
    key: 'status', title: '状态', width: 100,
    render: (r) => h(NTag, {
      size: 'small', bordered: false,
      type: r.status === 'running' ? 'success' : r.status === 'runnable' ? 'warning'
        : r.status === 'exiting' ? 'error' : 'default',
    }, { default: () => r.status }),
  },
])

const pagination = computed(() => ({
  page: page.value,
  pageSize: pageSize.value,
  itemCount: data.value?.total ?? 0,
  pageSizes: [50, 100, 200],
  showSizePicker: true,
  prefix: ({ itemCount }: { itemCount?: number }) => `共 ${formatNumber(itemCount ?? 0)} 个`,
  onUpdatePage: (p: number) => { page.value = p },
  onUpdatePageSize: (s: number) => { pageSize.value = s; page.value = 1 },
}))

const rowProps = (r: ProcessRow) => ({
  style: 'cursor: pointer',
  onClick: () => { selected.value = r.pid },
})

const intervals = [
  { label: '每 1 秒', value: 1000 },
  { label: '每 2 秒', value: 2000 },
  { label: '每 5 秒', value: 5000 },
  { label: '每 10 秒', value: 10000 },
]
</script>

<template>
  <PageHeader title="进程" :subtitle="data ? `${formatNumber(data.process_count)} 个进程` : nodes.current ?? undefined">
    <NSpace align="center" :size="8">
      <NInput v-model:value="filterInput" clearable placeholder="按 PID、注册名、模块或函数过滤"
              style="width: 300px">
        <template #prefix><NIcon :component="SearchOutline" /></template>
      </NInput>
      <NSelect v-model:value="interval" :options="intervals" style="width: 110px" />
      <NButton secondary @click="paused = !paused">
        <template #icon><NIcon :component="paused ? PlayOutline : PauseOutline" /></template>
        {{ paused ? '继续' : '暂停' }}
      </NButton>
      <NButton v-if="paused" quaternary @click="refreshOnce">刷新</NButton>
    </NSpace>
  </PageHeader>
  <NodeGuard>
    <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
    <NDataTable remote :columns="columns" :data="data?.rows ?? []" :loading="!data && !error"
                :pagination="pagination" :row-key="(r: ProcessRow) => r.pid" :row-props="rowProps"
                size="small" :scroll-x="1100" @update:sorter="onSort" />
    <p class="note">Reds 是距上次刷新以来的 reductions 增量，可以看出当前最忙的进程。点击一行查看详情。</p>
    <ProcessDrawer v-if="node" v-model:pid="selected" :node="node" @killed="refreshOnce" />
  </NodeGuard>
</template>

<style scoped>
:deep(.muted) {
  opacity: 0.6;
}
:deep(.name) {
  font-weight: 600;
}
:deep(.q-zero) {
  opacity: 0.45;
}
:deep(.q-warn) {
  color: #f0a020;
  font-weight: 600;
}
:deep(.q-bad) {
  color: #d03050;
  font-weight: 700;
}
.note {
  font-size: 12px;
  opacity: 0.5;
  margin-top: 12px;
}
</style>
