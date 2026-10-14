<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { useRoute, useRouter, RouterLink } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { useNodes } from '../stores/nodes'
import { useQueryRef } from '../composables/useQueryRef'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'
import ProcessDrawer from '../components/ProcessDrawer.vue'
import HealthCheck from '../components/diag/HealthCheck.vue'

const { t } = useI18n()
const nodes = useNodes()
const node = computed(() =>
  nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)
const selected = useQueryRef('pid')

// ?run=1 (from the command palette) starts a health check right away; the
// flag is dropped from the URL so a reload does not run it again.
const route = useRoute()
const router = useRouter()
const health = ref<InstanceType<typeof HealthCheck> | null>(null)
watch([() => route.query.run, node], async ([run, n]) => {
  if (!run || !n) return
  const query = { ...route.query }
  delete query.run
  await router.replace({ query })
  await nextTick()
  void health.value?.run()
}, { immediate: true })

// The window Top N lives on the Recon page now; old ?tab=window links go there.
watch(() => route.query.tab, (tab) => {
  if (tab === 'window') void router.replace({ path: '/recon', query: { ...route.query } })
}, { immediate: true })
const windowLink = computed(() => ({
  path: '/recon',
  query: route.query.node ? { node: route.query.node, tab: 'window' } : { tab: 'window' },
}))
</script>

<template>
  <PageHeader :title="t('diag.title')" :subtitle="nodes.current ?? undefined" />
  <NodeGuard>
    <HealthCheck v-if="node" ref="health" :node="node" @open="selected = $event" />
    <p v-if="node" class="moved">
      {{ t('diag.window_hint') }} <RouterLink :to="windowLink">{{ t('diag.window_link') }}</RouterLink>
    </p>
    <ProcessDrawer v-if="node" v-model:pid="selected" :node="node" />
  </NodeGuard>
</template>

<style scoped>
.moved {
  font-size: 12px;
  opacity: 0.55;
  margin-top: 20px;
}
.moved a {
  color: inherit;
  text-decoration: underline dotted;
  text-underline-offset: 3px;
}
.moved a:hover {
  text-decoration-style: solid;
}
</style>
