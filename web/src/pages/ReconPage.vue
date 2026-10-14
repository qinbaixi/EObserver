<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import { NTabs, NTabPane } from 'naive-ui'
import { useNodes } from '../stores/nodes'
import { useQueryRef } from '../composables/useQueryRef'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'
import ProcessDrawer from '../components/ProcessDrawer.vue'
import ProcTop from '../components/recon/ProcTop.vue'
import WindowTop from '../components/recon/WindowTop.vue'
import BinLeak from '../components/recon/BinLeak.vue'
import InetTop from '../components/recon/InetTop.vue'
import PortTypes from '../components/recon/PortTypes.vue'
import AllocFrag from '../components/recon/AllocFrag.vue'
import SchedUsage from '../components/recon/SchedUsage.vue'

// The recon library's tools, run on demand in the injected agent (the
// node does not need recon installed). One tab per tool.
const TABS = ['proc', 'window', 'bin_leak', 'inet', 'ports', 'alloc', 'sched'] as const

const { t } = useI18n()
const nodes = useNodes()
const node = computed(() =>
  nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)
const selected = useQueryRef('pid')
const tabRef = useQueryRef('tab')
const tab = computed({
  get: () => (TABS as readonly string[]).includes(tabRef.value ?? '') ? tabRef.value! : 'proc',
  set: (v: string) => { tabRef.value = v === 'proc' ? null : v },
})
</script>

<template>
  <PageHeader :title="t('recon.title')" :subtitle="nodes.current ?? undefined" />
  <NodeGuard>
    <NTabs v-if="node" v-model:value="tab" type="line" animated display-directive="show:lazy">
      <NTabPane name="proc" :tab="t('recon.tabs.proc')">
        <ProcTop :node="node" @open="selected = $event" />
      </NTabPane>
      <NTabPane name="window" :tab="t('recon.tabs.window')">
        <WindowTop :node="node" @open="selected = $event" />
      </NTabPane>
      <NTabPane name="bin_leak" :tab="t('recon.tabs.bin_leak')">
        <BinLeak :node="node" @open="selected = $event" />
      </NTabPane>
      <NTabPane name="inet" :tab="t('recon.tabs.inet')">
        <InetTop :node="node" @open="selected = $event" />
      </NTabPane>
      <NTabPane name="ports" :tab="t('recon.tabs.ports')">
        <PortTypes :node="node" />
      </NTabPane>
      <NTabPane name="alloc" :tab="t('recon.tabs.alloc')">
        <AllocFrag :node="node" />
      </NTabPane>
      <NTabPane name="sched" :tab="t('recon.tabs.sched')">
        <SchedUsage :node="node" />
      </NTabPane>
    </NTabs>
    <ProcessDrawer v-if="node" v-model:pid="selected" :node="node" />
  </NodeGuard>
</template>
