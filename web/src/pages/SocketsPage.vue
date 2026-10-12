<script setup lang="ts">
import { computed, h, ref, toRef } from 'vue'
import { NDataTable, NTabs, NTabPane, NAlert, NTag, NEmpty, NInput, NIcon, type DataTableColumns } from 'naive-ui'
import { SearchOutline } from '@vicons/ionicons5'
import { useNodes } from '../stores/nodes'
import { useTopic } from '../composables/useTopic'
import type { InetRow, SocketRow } from '../api/types'
import { formatBytes } from '../api/format'
import PageHeader from '../components/PageHeader.vue'
import RefreshControl from '../components/RefreshControl.vue'
import NodeGuard from '../components/NodeGuard.vue'
import PortDrawer from '../components/PortDrawer.vue'
import ProcessDrawer from '../components/ProcessDrawer.vue'
import { term } from '../api/term'
import { useResizableTable } from '../api/table'

const nodes = useNodes()
const node = computed(() =>
  nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)
const hasSocket = computed(() => nodes.currentInfo?.summary?.features.socket ?? false)
const socketNode = computed(() => (hasSocket.value ? node.value : null))

const tab = ref<'inet' | 'socket'>('inet')
const inetNode = computed(() => (tab.value === 'inet' ? node.value : null))
const sockNode = computed(() => (tab.value === 'socket' ? socketNode.value : null))
const inet = useTopic<InetRow[]>('node.inet', toRef(inetNode), 3000)
const sockets = useTopic<SocketRow[]>('node.sockets', toRef(sockNode), 3000)
const active = computed(() => (tab.value === 'inet' ? inet : sockets))

const search = ref('')
const selectedPort = ref<string | null>(null)
const selectedPid = ref<string | null>(null)

function match(texts: (string | null)[]) {
  const q = search.value.trim().toLowerCase()
  return !q || texts.some((t) => (t ?? '').toLowerCase().includes(q))
}

const inetRows = computed(() => (inet.data.value ?? []).filter((r) => match([r.id, r.local, r.remote, r.connected])))
const socketRows = computed(() => (sockets.data.value ?? []).filter((r) => match([r.local, r.remote, r.owner])))

function pidLink(pid: string | null) {
  return pid
    ? h('a', { class: 'mono link', onClick: (e: Event) => { e.stopPropagation(); selectedPid.value = pid } }, pid)
    : '-'
}

const inetColumns: DataTableColumns<InetRow> = [
  { key: 'id', title: '端口', width: 120, render: (r) => h('span', { class: 'mono' }, r.id) },
  { key: 'protocol', title: '协议', width: 80,
    render: (r) => h(NTag, { size: 'small', bordered: false }, { default: () => r.protocol }) },
  { key: 'local', title: '本地地址', minWidth: 170, render: (r) => h('span', { class: 'mono' }, r.local ?? '-') },
  { key: 'remote', title: '远端地址', minWidth: 170,
    render: (r) => h('span', { class: r.remote ? 'mono' : 'mono muted' }, r.remote ?? (r.protocol === 'tcp' ? '监听中' : '-')) },
  { key: 'connected', title: term('所属进程'), width: 120, render: (r) => pidLink(r.connected) },
  { key: 'recv', title: '接收', width: 110, align: 'right',
    sorter: (a, b) => (a.stats.recv_oct ?? 0) - (b.stats.recv_oct ?? 0),
    render: (r) => h('span', { class: 'mono' }, formatBytes(r.stats.recv_oct ?? 0)) },
  { key: 'send', title: '发送', width: 110, align: 'right',
    sorter: (a, b) => (a.stats.send_oct ?? 0) - (b.stats.send_oct ?? 0),
    render: (r) => h('span', { class: 'mono' }, formatBytes(r.stats.send_oct ?? 0)) },
]

const socketColumns: DataTableColumns<SocketRow> = [
  { key: 'domain', title: '协议', width: 160,
    render: (r) => h('span', { class: 'mono' }, `${r.domain ?? '?'} / ${r.type ?? '?'} / ${r.protocol ?? '?'}`) },
  { key: 'local', title: '本地地址', minWidth: 170, render: (r) => h('span', { class: 'mono' }, r.local ?? '-') },
  { key: 'remote', title: '远端地址', minWidth: 170, render: (r) => h('span', { class: 'mono' }, r.remote ?? '-') },
  { key: 'owner', title: term('所属进程'), width: 120, render: (r) => pidLink(r.owner) },
  { key: 'state', title: '状态', minWidth: 160,
    render: (r) => h('span', { class: 'mono muted' }, [...r.rstates, ...r.wstates].join(', ') || '-') },
  { key: 'read', title: '读取', width: 110, align: 'right', sorter: (a, b) => a.read_bytes - b.read_bytes,
    render: (r) => h('span', { class: 'mono' }, formatBytes(r.read_bytes)) },
  { key: 'write', title: '写入', width: 110, align: 'right', sorter: (a, b) => a.write_bytes - b.write_bytes,
    render: (r) => h('span', { class: 'mono' }, formatBytes(r.write_bytes)) },
]

const inetRowProps = (r: InetRow) => ({ style: 'cursor: pointer', onClick: () => { selectedPort.value = r.id } })
const inetTable = useResizableTable(inetColumns)
const socketTable = useResizableTable(socketColumns)
</script>

<template>
  <PageHeader title="Sockets" :subtitle="nodes.current ?? undefined">
    <NInput v-model:value="search" clearable placeholder="按地址或进程过滤" style="width: 260px">
      <template #prefix><NIcon :component="SearchOutline" /></template>
    </NInput>
    <RefreshControl v-model:paused="active.paused.value" v-model:interval="active.interval.value"
                    @refresh="active.refresh" />
  </PageHeader>
  <NodeGuard>
    <NTabs v-model:value="tab" type="line">
      <NTabPane name="inet" tab="gen_tcp / gen_udp">
        <NAlert v-if="inet.error.value" type="error">{{ inet.error.value }}</NAlert>
        <NDataTable v-bind="inetTable" :data="inetRows" :loading="!inet.data.value && !inet.error.value"
                    size="small" :row-key="(r: InetRow) => r.id" :row-props="inetRowProps"
                    :pagination="{ pageSize: 50 }" />
      </NTabPane>
      <NTabPane name="socket" tab="socket 模块">
        <NEmpty v-if="!hasSocket" description="该节点的 OTP 版本不支持 socket:which_sockets/0" style="padding: 60px 0" />
        <template v-else>
          <NAlert v-if="sockets.error.value" type="error">{{ sockets.error.value }}</NAlert>
          <NDataTable v-bind="socketTable" :data="socketRows"
                      :loading="!sockets.data.value && !sockets.error.value" size="small"
                      :row-key="(r: SocketRow) => r.id" :pagination="{ pageSize: 50 }" />
        </template>
      </NTabPane>
    </NTabs>
    <template v-if="node">
      <PortDrawer v-model:port="selectedPort" :node="node" @open-pid="(p) => (selectedPid = p)" />
      <ProcessDrawer v-model:pid="selectedPid" :node="node" />
    </template>
  </NodeGuard>
</template>

<style scoped>
:deep(.muted) { opacity: 0.6; }
:deep(.link) { cursor: pointer; }
:deep(.link:hover) { text-decoration: underline; }
</style>
