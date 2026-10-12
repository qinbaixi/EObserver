<script setup lang="ts">
import { useQueryRef } from '../composables/useQueryRef'
import { computed, ref, watch } from 'vue'
import { NCard, NSpin, NEmpty, NAlert, NTag, NButton, NIcon, NScrollbar, NInput } from 'naive-ui'
import { RefreshOutline, SearchOutline } from '@vicons/ionicons5'
import { client } from '../api/ws'
import { useNodes } from '../stores/nodes'
import type { AppInfo, AppTree } from '../api/types'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'
import ProcessDrawer from '../components/ProcessDrawer.vue'
import SupervisionTree from '../charts/SupervisionTree.vue'

const nodes = useNodes()
const node = computed(() =>
  nodes.currentInfo?.status === 'connected' ? nodes.currentInfo.node : null)

const apps = ref<AppInfo[]>([])
const selectedApp = useQueryRef('app')
const tree = ref<AppTree | null>(null)
const loadingTree = ref(false)
const error = ref<string | null>(null)
const selectedPid = useQueryRef('pid')
const search = ref('')

const visibleApps = computed(() => {
  const q = search.value.trim().toLowerCase()
  return q ? apps.value.filter((a) => a.name.toLowerCase().includes(q)) : apps.value
})

async function loadApps() {
  if (!node.value) return
  try {
    apps.value = await client.request<AppInfo[]>('apps.list', { node: node.value })
    if (!selectedApp.value || !apps.value.some((a) => a.name === selectedApp.value)) {
      const running = apps.value.filter((a) => a.running)
      selectedApp.value = (running.find((a) => a.name === 'kernel') ?? running[0])?.name ?? null
    }
  } catch (e) {
    error.value = (e as Error).message
  }
}

async function loadTree() {
  const app = apps.value.find((a) => a.name === selectedApp.value)
  tree.value = null
  error.value = null
  if (!node.value || !app || !app.running) return
  loadingTree.value = true
  try {
    tree.value = await client.request<AppTree>('apps.tree', { node: node.value, app: app.name }, 40000)
  } catch (e) {
    error.value = (e as Error).message
  } finally {
    loadingTree.value = false
  }
}

watch(node, () => { apps.value = []; selectedApp.value = null; void loadApps() }, { immediate: true })
watch(selectedApp, () => void loadTree())

const current = computed(() => apps.value.find((a) => a.name === selectedApp.value) ?? null)
</script>

<template>
  <PageHeader title="应用" :subtitle="nodes.current ?? undefined" />
  <NodeGuard>
    <div class="layout">
      <NCard size="small" class="list" content-style="padding: 0">
        <div class="search">
          <NInput v-model:value="search" size="small" clearable placeholder="过滤应用">
            <template #prefix><NIcon :component="SearchOutline" /></template>
          </NInput>
        </div>
        <NScrollbar style="max-height: calc(100vh - 230px)">
          <div v-for="a in visibleApps" :key="a.name" class="app"
               :class="{ active: a.name === selectedApp, loaded: !a.running }"
               @click="selectedApp = a.name">
            <div class="app-name mono">{{ a.name }}</div>
            <div class="app-vsn">{{ a.vsn }}<span v-if="!a.running"> · 已加载未运行</span></div>
          </div>
        </NScrollbar>
      </NCard>
      <NCard size="small" class="tree">
        <template #header>
          <span class="mono">{{ current?.name ?? '' }}</span>
          <span v-if="current" class="desc">{{ current.description }}</span>
        </template>
        <template #header-extra>
          <NTag v-if="tree?.master" size="small" :bordered="false">master {{ tree.master }}</NTag>
          <NButton quaternary circle size="small" :loading="loadingTree" style="margin-left: 8px"
                   @click="loadTree">
            <template #icon><NIcon :component="RefreshOutline" /></template>
          </NButton>
        </template>
        <NAlert v-if="error" type="error">{{ error }}</NAlert>
        <NSpin v-else-if="loadingTree" style="width: 100%; padding: 80px 0" />
        <NEmpty v-else-if="current && !current.running" description="该应用已加载但未运行" style="padding: 80px 0" />
        <NEmpty v-else-if="tree && !tree.root" description="该应用没有监督树（库应用）" style="padding: 80px 0" />
        <NScrollbar v-else-if="tree?.root" x-scrollable>
          <div style="min-width: 760px">
            <SupervisionTree :root="tree.root" @select="(p) => (selectedPid = p)" />
          </div>
        </NScrollbar>
        <p v-if="tree?.root" class="note">实心圆是监督者，空心圆是工作进程，点击节点查看进程详情。</p>
      </NCard>
    </div>
    <ProcessDrawer v-if="node" v-model:pid="selectedPid" :node="node" />
  </NodeGuard>
</template>

<style scoped>
.layout {
  display: grid;
  grid-template-columns: 260px 1fr;
  gap: 16px;
  align-items: start;
}
@media (max-width: 800px) {
  .layout {
    grid-template-columns: 1fr;
  }
}
.search {
  padding: 12px;
}
.app {
  padding: 8px 16px;
  cursor: pointer;
  border-left: 3px solid transparent;
}
.app:hover {
  background: rgba(128, 128, 128, 0.08);
}
.app.active {
  border-left-color: var(--n-color-target, #a90533);
  background: rgba(169, 5, 51, 0.08);
}
.app.loaded {
  opacity: 0.55;
}
.app-name {
  font-weight: 600;
  font-size: 13px;
}
.app-vsn {
  font-size: 12px;
  opacity: 0.6;
}
.desc {
  margin-left: 12px;
  font-size: 13px;
  opacity: 0.6;
  font-weight: normal;
}
.note {
  font-size: 12px;
  opacity: 0.5;
  margin: 8px 0 0;
}
</style>
