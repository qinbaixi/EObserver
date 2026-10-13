<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { NTabs, NTabPane } from 'naive-ui'
import { useNodes } from '../stores/nodes'
import { useQueryRef } from '../composables/useQueryRef'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'
import ProcessDrawer from '../components/ProcessDrawer.vue'
import HealthCheck from '../components/diag/HealthCheck.vue'
import WindowTop from '../components/diag/WindowTop.vue'

const { t } = useI18n()
const nodes = useNodes()
const node = computed(() =>
  nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)
const selected = useQueryRef('pid')
const tabRef = useQueryRef('tab')
const tab = computed({
  get: () => (tabRef.value === 'window' ? 'window' : 'health'),
  set: (v: string) => { tabRef.value = v === 'health' ? null : v },
})

// ?run=1 (from the command palette) starts a health check right away; the
// flag is dropped from the URL so a reload does not run it again.
const route = useRoute()
const router = useRouter()
const health = ref<InstanceType<typeof HealthCheck> | null>(null)
watch([() => route.query.run, node], async ([run, n]) => {
  if (!run || !n) return
  const query = { ...route.query }
  delete query.run
  delete query.tab
  await router.replace({ query })
  await nextTick()
  void health.value?.run()
}, { immediate: true })
</script>

<template>
  <PageHeader :title="t('diag.title')" :subtitle="nodes.current ?? undefined" />
  <NodeGuard>
    <NTabs v-if="node" v-model:value="tab" type="line" animated display-directive="show">
      <NTabPane name="health" :tab="t('diag.tabs.health')">
        <HealthCheck ref="health" :node="node" @open="selected = $event" />
      </NTabPane>
      <NTabPane name="window" :tab="t('diag.tabs.window')">
        <WindowTop :node="node" @open="selected = $event" />
      </NTabPane>
    </NTabs>
    <ProcessDrawer v-if="node" v-model:pid="selected" :node="node" />
  </NodeGuard>
</template>
