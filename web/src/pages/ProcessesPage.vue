<script setup lang="ts">
import { useQueryRef } from '../composables/useQueryRef'
import { computed, h, onBeforeUnmount, ref, watch } from 'vue'
import {
  NDataTable, NInput, NSpace, NTag, NIcon, NAlert, NButton, NDropdown, NTooltip,
  useDialog, useMessage, type DropdownOption,
  type DataTableColumns, type DataTableSortState,
} from 'naive-ui'
import { SearchOutline, CloseCircleOutline } from '@vicons/ionicons5'
import { client } from '../api/ws'
import { useNodes } from '../stores/nodes'
import { useSettings } from '../stores/settings'
import { errorText } from '../api/errors'
import type { ProcessPage, ProcessRow } from '../api/types'
import { formatBytes, formatNumber } from '../api/format'
import PageHeader from '../components/PageHeader.vue'
import RefreshControl from '../components/RefreshControl.vue'
import NodeGuard from '../components/NodeGuard.vue'
import ProcessDrawer from '../components/ProcessDrawer.vue'
import { term } from '../api/term'
import { useResizableTable } from '../api/table'

type SortKey = 'reds' | 'reductions' | 'memory' | 'message_queue_len' | 'name' | 'pid'

const nodes = useNodes()
const settings = useSettings()
const dialog = useDialog()
const message = useMessage()
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
const selected = useQueryRef('pid')

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
watch(() => nodes.current, () => { data.value = null; page.value = 1 })
onBeforeUnmount(() => stop?.())

// Manual refresh (and after a kill): one update while paused, otherwise
// restart the live subscription so the next update comes right away.
function refreshOnce() {
  subscribe(paused.value)
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

function kill(r: ProcessRow) {
  const n = node.value
  if (!n) return
  dialog.error({
    title: '杀死进程',
    content: `向 ${r.pid}${r.name ? `（${r.name}）` : ''} 发送 kill 退出信号？这会影响目标节点上正在运行的系统。`,
    positiveText: '杀死',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await client.request('process.kill', { node: n, pid: r.pid })
        message.success(`已杀死 ${r.pid}`)
        refreshOnce()
      } catch (e) {
        message.error(errorText(e))
      }
    },
  })
}

// Right-click menu on a row.
const menu = ref<{ x: number; y: number; row: ProcessRow } | null>(null)
const menuOptions = computed<DropdownOption[]>(() => [
  { key: 'open', label: '查看详情' },
  { key: 'copy', label: '复制 PID' },
  ...(settings.readOnly ? [] : [{ type: 'divider', key: 'd' }, { key: 'kill', label: '杀死进程…' }]),
])
function onMenu(key: string) {
  const row = menu.value?.row
  menu.value = null
  if (!row) return
  if (key === 'open') selected.value = row.pid
  else if (key === 'copy') void navigator.clipboard?.writeText(row.pid).then(() => message.success('已复制'))
  else if (key === 'kill') kill(row)
}

const columns = computed<DataTableColumns<ProcessRow>>(() => [
  {
    key: 'pid', title: 'PID', width: 120, ...sorter('pid'),
    render: (r) => h('span', { class: 'mono pid' }, r.pid),
  },
  {
    key: 'name', title: term('名称 / 初始调用'), minWidth: 220, ellipsis: { tooltip: true }, ...sorter('name'),
    render: (r) => r.name
      ? h('span', { class: 'name' }, r.name)
      : h('span', { class: 'mono muted' }, r.initial_call),
  },
  {
    key: 'reds', title: term('Reds'), width: 110, align: 'right', ...sorter('reds'),
    render: (r) => h('span', { class: 'mono' }, r.reds == null ? '-' : formatNumber(r.reds)),
  },
  {
    key: 'reductions', title: term('Reductions'), width: 140, align: 'right', ...sorter('reductions'),
    render: (r) => h('span', { class: 'mono muted' }, formatNumber(r.reductions)),
  },
  {
    key: 'memory', title: term('内存', '进程占用的总内存，包括堆、栈、消息队列和内部结构。'), width: 110, align: 'right', ...sorter('memory'),
    render: (r) => h('span', { class: 'mono' }, formatBytes(r.memory)),
  },
  {
    key: 'message_queue_len', title: term('消息队列'), width: 110, align: 'right', ...sorter('message_queue_len'),
    render: (r) => h('span', { class: ['mono', queueClass(r.message_queue_len)] }, formatNumber(r.message_queue_len)),
  },
  {
    key: 'current_function', title: term('当前函数'), minWidth: 220, ellipsis: { tooltip: true },
    render: (r) => h('span', { class: 'mono muted' }, r.current_function),
  },
  {
    key: 'status', title: term('状态'), width: 100,
    render: (r) => h(NTag, {
      size: 'small', bordered: false,
      type: r.status === 'running' ? 'success' : r.status === 'runnable' ? 'warning'
        : r.status === 'exiting' ? 'error' : 'default',
    }, { default: () => r.status }),
  },
  ...(settings.readOnly ? [] : [{
    key: 'actions', title: '', width: 48, align: 'center' as const, fixed: 'right' as const,
    render: (r: ProcessRow) => h(NTooltip, null, {
      trigger: () => h(NButton, {
        quaternary: true, circle: true, size: 'tiny', type: 'error', class: 'kill-btn',
        onClick: (e: MouseEvent) => { e.stopPropagation(); kill(r) },
      }, { icon: () => h(NIcon, { component: CloseCircleOutline }) }),
      default: () => '杀死进程',
    }),
  }]),
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
  onContextmenu: (e: MouseEvent) => {
    e.preventDefault()
    menu.value = { x: e.clientX, y: e.clientY, row: r }
  },
})

const procTable = useResizableTable(columns)
</script>

<template>
  <PageHeader title="进程" :subtitle="data ? `${formatNumber(data.process_count)} 个进程` : nodes.current ?? undefined">
    <NSpace align="center" :size="8">
      <NInput v-model:value="filterInput" clearable placeholder="按 PID、注册名、模块或函数过滤"
              style="width: 300px">
        <template #prefix><NIcon :component="SearchOutline" /></template>
      </NInput>
      <RefreshControl v-model:paused="paused" v-model:interval="interval" @refresh="refreshOnce" />
    </NSpace>
  </PageHeader>
  <NodeGuard>
    <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
    <NDataTable remote v-bind="procTable" :data="data?.rows ?? []" :loading="!data && !error"
                :pagination="pagination" :row-key="(r: ProcessRow) => r.pid" :row-props="rowProps"
                size="small" @update:sorter="onSort" />
    <p class="note">Reds 是距上次刷新以来的 reductions 增量，可以看出当前最忙的进程。点击一行查看详情，右键可复制 PID{{ settings.readOnly ? '' : '或杀死进程' }}。</p>
    <NDropdown trigger="manual" placement="bottom-start" :show="!!menu" :x="menu?.x" :y="menu?.y"
               :options="menuOptions" @select="onMenu" @clickoutside="menu = null" />
    <ProcessDrawer v-if="node" v-model:pid="selected" :node="node" @killed="refreshOnce" />
  </NodeGuard>
</template>

<style scoped>
:deep(.kill-btn) {
  opacity: 0;
  transition: opacity 0.15s;
}
:deep(tr:hover .kill-btn),
:deep(.kill-btn:focus-visible) {
  opacity: 1;
}
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
