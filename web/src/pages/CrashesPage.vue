<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { NTag, NAlert, NSpace } from 'naive-ui'
import { useNodes } from '../stores/nodes'
import { useLogs } from '../stores/logs'
import { formatNumber } from '../api/format'
import { formatTime } from '../api/trace'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'
import CrashList from '../components/logs/CrashList.vue'

// Crashes and restarts come from the same collector as the logs page.
const { t, te } = useI18n()
const nodes = useNodes()
const logs = useLogs()

onMounted(logs.acquire)
onBeforeUnmount(logs.release)

const s = computed(() => logs.status)
const crashCount = computed(() => {
  let n = 0
  for (const c of logs.crashes.values()) n += c.count
  return n
})

const stopReason = computed(() => {
  const r = s.value?.reason
  if (!r) return t('logs.status.stopped')
  return te(`logs.stop_reason.${r}`) ? t(`logs.stop_reason.${r}`) : t('procs.paren', { text: t('logs.status.stopped'), detail: r })
})
</script>

<template>
  <PageHeader :title="t('logs.crashes_page.title')" :subtitle="nodes.current ?? undefined">
    <NSpace v-if="logs.node" align="center" :size="8">
      <NTag v-if="!s" :bordered="false" round>{{ t('logs.status.starting') }}</NTag>
      <NTag v-else-if="s.status === 'running'" type="success" :bordered="false" round>
        {{ t('logs.crashes_page.running', { n: formatNumber(crashCount) }) }}
      </NTag>
      <NTag v-else type="warning" :bordered="false" round>{{ stopReason }}</NTag>
    </NSpace>
  </PageHeader>
  <NodeGuard>
    <template v-if="logs.node">
      <p class="intro">
        {{ t('logs.crashes_page.only_since', { time: s ? formatTime(s.started * 1000).slice(0, 8) : '…' }) }}
      </p>
      <NAlert v-if="logs.error" type="error" :bordered="false" class="alert">{{ logs.error }}</NAlert>
      <CrashList />
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
