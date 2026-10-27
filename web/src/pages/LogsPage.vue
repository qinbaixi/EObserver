<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { NTabs, NTabPane, NTag, NAlert, NSpace } from 'naive-ui'
import { useNodes } from '../stores/nodes'
import { useLogs } from '../stores/logs'
import { useQueryRef } from '../composables/useQueryRef'
import { formatNumber } from '../api/format'
import { formatTime } from '../api/trace'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'
import LiveLog from '../components/logs/LiveLog.vue'
import LogFiles from '../components/logs/LogFiles.vue'

const { t, te } = useI18n()
const nodes = useNodes()
const logs = useLogs()
const tabRef = useQueryRef('tab')
const tab = computed({
  get: () => (tabRef.value === 'files' ? 'files' : 'live'),
  set: (v: string) => { tabRef.value = v === 'live' ? null : v },
})

// Collecting on the target runs while this page is open.
onMounted(logs.acquire)
onBeforeUnmount(logs.release)

const s = computed(() => logs.status)
const stopReason = computed(() => {
  const r = s.value?.reason
  if (!r) return t('logs.status.stopped')
  return te(`logs.stop_reason.${r}`) ? t(`logs.stop_reason.${r}`) : t('procs.paren', { text: t('logs.status.stopped'), detail: r })
})

// Levels the node's logger lets through, when that hides something.
const primaryLevel = computed(() => {
  const l = s.value?.primary_level
  return l && l !== 'all' && l !== 'debug' ? l : null
})

// With lager attached, the logger level only concerns logger calls.
const lagerNote = computed(() => {
  if (!s.value?.lager) return ''
  const l = s.value.lager_level
  return l && l !== 'debug' ? t('logs.lager_level', { level: l }) : t('logs.lager')
})

const intro = computed(() =>
  t('logs.only_since', { time: s.value ? formatTime(s.value.started * 1000).slice(0, 8) : '…' })
  + lagerNote.value
  + (primaryLevel.value
    ? t(s.value?.lager ? 'logs.primary_level_otp' : 'logs.primary_level', { level: primaryLevel.value })
    : ''))
</script>

<template>
  <PageHeader :title="t('logs.title')" :subtitle="nodes.current ?? undefined">
    <NSpace v-if="logs.node" align="center" :size="8">
      <NTag v-if="!s" :bordered="false" round>{{ t('logs.status.starting') }}</NTag>
      <NTag v-else-if="s.status === 'running'" type="success" :bordered="false" round>
        {{ t('logs.status.running') }} · {{ t('logs.status.received', { n: formatNumber(s.received) }) }}
      </NTag>
      <NTag v-else type="warning" :bordered="false" round>{{ stopReason }}</NTag>
    </NSpace>
  </PageHeader>
  <NodeGuard>
    <template v-if="logs.node">
      <p class="intro">{{ intro }}</p>
      <NAlert v-if="logs.error" type="error" :bordered="false" class="alert">{{ logs.error }}</NAlert>
      <NAlert v-if="s && (s.dropped > 0 || s.limited > 0 || logs.lost > 0 || s.collector_restarts > 0)"
              type="warning" :bordered="false" class="alert">
        <div v-if="s.dropped > 0">{{ t('logs.dropped', { n: formatNumber(s.dropped) }) }}</div>
        <div v-if="s.limited > 0">{{ t('logs.limited', { n: formatNumber(s.limited) }) }}</div>
        <div v-if="logs.lost > 0">{{ t('logs.lost', { n: formatNumber(logs.lost) }) }}</div>
        <div v-if="s.collector_restarts > 0">{{ t('logs.collector_restarts', { n: s.collector_restarts }) }}</div>
      </NAlert>
      <NTabs v-model:value="tab" type="line" animated display-directive="show">
        <NTabPane name="live" :tab="t('logs.tabs.live')">
          <LiveLog />
        </NTabPane>
        <NTabPane name="files" :tab="t('logs.tabs.files')" display-directive="show:lazy">
          <LogFiles />
        </NTabPane>
      </NTabs>
    </template>
  </NodeGuard>
</template>

<style scoped>
.intro {
  margin: -8px 0 12px;
  font-size: 13px;
  opacity: 0.7;
}
.alert {
  margin-bottom: 12px;
}
</style>
