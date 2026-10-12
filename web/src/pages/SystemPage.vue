<script setup lang="ts">
import { computed, toRef } from 'vue'
import { NGrid, NGi, NCard, NTag, NSpace, NSkeleton } from 'naive-ui'
import { useNodes } from '../stores/nodes'
import { useTopic } from '../composables/useTopic'
import type { NodeSummary } from '../api/types'
import { formatBytes, formatDuration } from '../api/format'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'
import StatCard from '../components/StatCard.vue'
import UsageBar from '../components/UsageBar.vue'

const nodes = useNodes()
const connectedNode = computed(() =>
  nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)
const { data, error } = useTopic<NodeSummary>('node.summary', toRef(connectedNode), 2000)
const s = computed(() => data.value ?? nodes.currentInfo?.summary ?? null)

const systemRows = computed(() => s.value ? [
  { label: 'OTP 版本', value: s.value.otp_release },
  { label: 'ERTS 版本', value: s.value.erts_version },
  { label: '系统架构', value: s.value.system_architecture },
  { label: '字长', value: `${s.value.word_size * 8} 位` },
  { label: '运行时长', value: formatDuration(s.value.uptime_ms) },
] : [])

const cpuRows = computed(() => s.value ? [
  { label: '逻辑处理器', value: s.value.logical_processors },
  { label: '调度器（在线/总数）', value: `${s.value.schedulers_online} / ${s.value.schedulers}` },
  { label: 'Dirty CPU 调度器', value: s.value.dirty_cpu_schedulers },
  { label: 'Dirty IO 调度器', value: s.value.dirty_io_schedulers },
  { label: '总内存', value: formatBytes(s.value.memory_total) },
] : [])
</script>

<template>
  <PageHeader title="系统概览" :subtitle="nodes.current ?? undefined">
    <NSpace v-if="s">
      <NTag v-if="s.features.socket" size="small" round :bordered="false">socket</NTag>
      <NTag v-if="s.features.mnesia" size="small" round :bordered="false">mnesia</NTag>
    </NSpace>
  </PageHeader>
  <NodeGuard>
    <div v-if="error" class="err">{{ error }}</div>
    <NGrid v-if="s" cols="1 m:2 l:3" responsive="screen" :x-gap="16" :y-gap="16">
      <NGi><StatCard title="系统与架构" :rows="systemRows" /></NGi>
      <NGi><StatCard title="CPU 与内存" :rows="cpuRows" /></NGi>
      <NGi>
        <NCard title="资源使用" size="small">
          <UsageBar label="进程" :used="s.process_count" :limit="s.process_limit" />
          <UsageBar label="端口" :used="s.port_count" :limit="s.port_limit" />
          <UsageBar label="原子" :used="s.atom_count" :limit="s.atom_limit" />
          <div class="ets">ETS 表 <span class="mono">{{ s.ets_count }}</span></div>
        </NCard>
      </NGi>
    </NGrid>
    <NSkeleton v-else text :repeat="6" />
  </NodeGuard>
</template>

<style scoped>
.ets {
  margin-top: 16px;
  opacity: 0.65;
}
.err {
  color: #d03050;
  margin-bottom: 12px;
}
</style>
