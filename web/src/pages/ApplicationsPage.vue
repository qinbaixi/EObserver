<script setup lang="ts">
import { useQueryRef } from '../composables/useQueryRef'
import { errorText } from '../api/errors'
import { computed, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { NCard, NSpin, NEmpty, NAlert, NTag, NButton, NIcon, NScrollbar, NInput } from 'naive-ui'
import { RefreshOutline, SearchOutline } from '@vicons/ionicons5'
import { client } from '../api/ws'
import { useNodes } from '../stores/nodes'
import type { AppInfo, AppTree } from '../api/types'
import PageHeader from '../components/PageHeader.vue'
import NodeGuard from '../components/NodeGuard.vue'
import ProcessDrawer from '../components/ProcessDrawer.vue'
import SupervisionTree from '../charts/SupervisionTree.vue'

const { t } = useI18n()
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
    error.value = errorText(e)
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
    error.value = errorText(e)
  } finally {
    loadingTree.value = false
  }
}

// Keep an ?app= from the URL on first load; a node switch starts over.
watch(node, async (_, old) => {
  apps.value = []
  if (old) selectedApp.value = null
  const before = selectedApp.value
  await loadApps()
  // An ?app= from the URL is already selected, so the watch below does not
  // fire for it; load its tree now that the list is known.
  if (before && selectedApp.value === before) await loadTree()
}, { immediate: true })
watch(selectedApp, () => void loadTree())

// Applications may have been started or stopped since the list was read.
async function refreshAll() {
  const before = selectedApp.value
  await loadApps()
  if (selectedApp.value === before) await loadTree()
}

const current = computed(() => apps.value.find((a) => a.name === selectedApp.value) ?? null)
</script>

<template>
  <PageHeader :title="t('pages.applications.title')" :subtitle="nodes.current ?? undefined" />
  <NodeGuard>
    <div class="layout">
      <NCard size="small" class="list" content-style="padding: 0">
        <div class="search">
          <NInput v-model:value="search" size="small" clearable :placeholder="t('pages.applications.filter')">
            <template #prefix><NIcon :component="SearchOutline" /></template>
          </NInput>
        </div>
        <NScrollbar style="max-height: calc(100vh - 230px)">
          <div v-for="a in visibleApps" :key="a.name" class="app"
               :class="{ active: a.name === selectedApp, loaded: !a.running }"
               @click="selectedApp = a.name">
            <div class="app-name mono">{{ a.name }}</div>
            <div class="app-vsn">{{ a.vsn }}<span v-if="!a.running"> · {{ t('pages.applications.loaded') }}</span></div>
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
                   @click="refreshAll">
            <template #icon><NIcon :component="RefreshOutline" /></template>
          </NButton>
        </template>
        <NAlert v-if="error" type="error">{{ error }}</NAlert>
        <NSpin v-else-if="loadingTree" style="width: 100%; padding: 80px 0" />
        <NEmpty v-else-if="current && !current.running" :description="t('pages.applications.not_running')" style="padding: 80px 0" />
        <NEmpty v-else-if="tree && !tree.root" :description="t('pages.applications.no_tree')" style="padding: 80px 0" />
        <SupervisionTree v-else-if="tree?.root" :root="tree.root" @select="(p) => (selectedPid = p)" />
        <p v-if="tree?.root" class="note">{{ t('pages.applications.note') }}</p>
      </NCard>
    </div>
    <ProcessDrawer v-if="node" v-model:pid="selectedPid" :node="node" />
  </NodeGuard>
</template>

<style scoped>
.layout {
  display: grid;
  /* minmax(0, …): a wide supervision tree scrolls inside its card instead
     of stretching the column past the window. */
  grid-template-columns: 260px minmax(0, 1fr);
  gap: 16px;
  align-items: start;
}
@media (max-width: 800px) {
  .layout {
    grid-template-columns: minmax(0, 1fr);
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
