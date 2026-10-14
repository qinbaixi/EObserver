<script setup lang="ts">
import { computed, toRef } from 'vue'
import { useI18n } from 'vue-i18n'
import { NGrid, NGi, NCard, NTag, NSpace, NSkeleton } from 'naive-ui'
import { useNodes } from '../stores/nodes'
import { useTopic } from '../composables/useTopic'
import type { NodeSummary } from '../api/types'
import { formatBytes, formatDuration, formatNumber } from '../api/format'
import PageHeader from '../components/PageHeader.vue'
import RefreshControl from '../components/RefreshControl.vue'
import NodeGuard from '../components/NodeGuard.vue'
import StatCard from '../components/StatCard.vue'
import UsageBar from '../components/UsageBar.vue'

const { t } = useI18n()
const nodes = useNodes()
const connectedNode = computed(() =>
  nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)
const { data, error, paused, interval, refresh } = useTopic<NodeSummary>('node.summary', toRef(connectedNode), 2000)
const s = computed(() => data.value ?? nodes.currentInfo?.summary ?? null)

const yesNo = (b: boolean) => t(b ? 'pages.yes' : 'pages.no')

// Labels are glossary ids (see Term.vue); the glossary translates them.
const systemRows = computed(() => s.value ? [
  { label: 'OTP 版本', value: s.value.otp_release },
  { label: 'ERTS 版本', value: s.value.erts_version },
  { label: t('pages.system.arch'), value: s.value.system_architecture },
  { label: '模拟器', value: s.value.emu_flavor ?? '-' },
  { label: '字长', value: t('pages.system.bits', { n: s.value.word_size * 8 }) },
  { label: 'Kernel poll', value: yesNo(s.value.kernel_poll) },
] : [])

const cpuRows = computed(() => s.value ? [
  { label: '逻辑处理器', value: s.value.logical_processors },
  { label: '调度器（在线/总数）', value: `${s.value.schedulers_online} / ${s.value.schedulers}` },
  { label: 'Dirty CPU（在线/总数）',
    value: `${s.value.dirty_cpu_schedulers_online ?? '-'} / ${s.value.dirty_cpu_schedulers}` },
  { label: 'Dirty IO 调度器', value: s.value.dirty_io_schedulers },
  { label: '异步线程池', value: s.value.thread_pool_size },
] : [])

const memoryRows = computed(() => {
  const m = s.value?.memory
  return m ? [
    { label: '总计', value: formatBytes(m.total) },
    { label: '进程', value: formatBytes(m.processes) },
    { label: '原子', value: formatBytes(m.atom) },
    { label: '二进制', value: formatBytes(m.binary) },
    { label: '代码', value: formatBytes(m.code) },
    { label: 'ETS', value: formatBytes(m.ets) },
  ] : []
})

const statRows = computed(() => s.value ? [
  { label: '运行时长', value: formatDuration(s.value.uptime_ms) },
  { label: '运行队列', value: formatNumber(s.value.run_queue) },
  { label: 'IO 输入总量', value: formatBytes(s.value.io_input) },
  { label: 'IO 输出总量', value: formatBytes(s.value.io_output) },
  { label: 'Reductions', value: formatNumber(s.value.reductions) },
  { label: '上下文切换', value: formatNumber(s.value.context_switches) },
  { label: 'GC 次数', value: formatNumber(s.value.gc_count) },
  { label: 'GC 回收', value: formatBytes(s.value.gc_words_reclaimed * s.value.word_size) },
] : [])
</script>

<template>
  <PageHeader :title="t('pages.system.title')" :subtitle="nodes.current ?? undefined">
    <NSpace align="center">
      <NTag v-if="s?.features.socket" size="small" round :bordered="false">socket</NTag>
      <NTag v-if="s?.features.mnesia" size="small" round :bordered="false">mnesia</NTag>
      <RefreshControl v-model:paused="paused" v-model:interval="interval" @refresh="refresh" />
    </NSpace>
  </PageHeader>
  <NodeGuard>
    <div v-if="error" class="err">{{ error }}</div>
    <NGrid v-if="s" cols="1 m:2 l:3" responsive="screen" :x-gap="16" :y-gap="16">
      <NGi><StatCard :title="t('pages.system.cards.system')" :rows="systemRows" /></NGi>
      <NGi><StatCard :title="t('pages.system.cards.cpu')" :rows="cpuRows" /></NGi>
      <NGi>
        <NCard :title="t('pages.system.cards.usage')" size="small">
          <UsageBar label="进程" :tip="t('pages.system.tips.process')" :used="s.process_count" :limit="s.process_limit" />
          <UsageBar label="端口" :tip="t('pages.system.tips.port')" :used="s.port_count" :limit="s.port_limit" />
          <UsageBar label="原子" :tip="t('pages.system.tips.atom')" :used="s.atom_count" :limit="s.atom_limit" />
          <UsageBar v-if="s.ets_limit" label="ETS 表" :used="s.ets_count" :limit="s.ets_limit" />
          <div v-else class="ets">{{ t('pages.system.ets') }} <span class="mono">{{ s.ets_count }}</span></div>
        </NCard>
      </NGi>
      <NGi><StatCard :title="t('pages.system.cards.memory')" :rows="memoryRows" /></NGi>
      <NGi span="1 l:2"><StatCard :title="t('pages.system.cards.stats')" :rows="statRows" class="two-col" /></NGi>
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
@media (min-width: 900px) {
  .two-col :deep(dl) {
    grid-template-columns: auto 1fr auto 1fr;
    column-gap: 32px;
  }
}
</style>
