<script setup lang="ts">
import { computed, h, onMounted, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { NTabs, NTab, NButton, NIcon, NTooltip, useMessage } from 'naive-ui'
import { FolderOpenOutline, CloudUploadOutline } from '@vicons/ionicons5'
import { basename } from '../api/dump'
import { errorText } from '../api/errors'
import { useDumps } from '../stores/dump'
import { useQueryRef } from '../composables/useQueryRef'
import PageHeader from '../components/PageHeader.vue'
import DumpOpen from '../components/crashdump/DumpOpen.vue'
import DumpView from '../components/crashdump/DumpView.vue'
import FileBrowser from '../components/crashdump/FileBrowser.vue'

// Crash dump viewer. Works without any connected node: the EObserver
// backend reads the file on this machine. Several dumps can be open at
// once, one tab each; "+" (or no dump yet) shows the open screen.
const { t, te } = useI18n()
const message = useMessage()
const dumps = useDumps()
const active = useQueryRef('dump')
const adding = ref(false)
const opening = ref(false)
const browsing = ref(false)
const dragging = ref(false)
const desktop = computed(() => !!window.eobsDesktop?.openDumpFile)

onMounted(() => {
  dumps.start()
  void dumps.refresh()
  void dumps.loadRecent()
})

const current = computed(() => (adding.value ? null : dumps.get(active.value)))

// With dumps open and none chosen (or a stale id in the URL), show the first.
watch([() => dumps.loaded, () => dumps.list.length, active], () => {
  if (!dumps.loaded || adding.value) return
  if (!dumps.get(active.value) && dumps.list.length) active.value = dumps.list[0].id
  else if (!dumps.list.length && active.value) active.value = null
}, { immediate: true })

function openError(e: unknown): string {
  const code = e instanceof Error ? e.message : String(e)
  return te(`crashdump.errors.${code}`) ? t(`crashdump.errors.${code}`) : errorText(e)
}

async function open(path: string) {
  opening.value = true
  try {
    const id = await dumps.open(path)
    adding.value = false
    active.value = id
  } catch (e) {
    message.error(t('crashdump.open_failed', { path: basename(path), err: openError(e) }), { duration: 6000 })
  } finally {
    opening.value = false
  }
}

async function pick() {
  const bridge = window.eobsDesktop
  if (bridge?.openDumpFile) {
    const path = await bridge.openDumpFile()
    if (path) await open(path)
  } else {
    browsing.value = true
  }
}

async function close(id: string) {
  const i = dumps.list.findIndex((d) => d.id === id)
  if (active.value === id) {
    const next = dumps.list[i + 1] ?? dumps.list[i - 1]
    active.value = next?.id ?? null
  }
  try {
    await dumps.close(id)
  } catch (e) {
    message.error(errorText(e))
  }
}

function select(v: string | number) {
  if (v === '__open') return
  adding.value = false
  active.value = String(v)
}

// Drag & drop: the desktop app knows the dropped file's path; a browser
// does not, so it points to the file browser instead.
let depth = 0
function onDragEnter(e: DragEvent) {
  if (!e.dataTransfer?.types.includes('Files')) return
  depth++
  dragging.value = true
}
function onDragLeave() {
  depth = Math.max(0, depth - 1)
  if (!depth) dragging.value = false
}
function onDrop(e: DragEvent) {
  depth = 0
  dragging.value = false
  const file = e.dataTransfer?.files?.[0]
  if (!file) return
  const path = window.eobsDesktop?.pathForFile?.(file)
  if (path) void open(path)
  else message.warning(t('crashdump.drop_browser'), { duration: 6000 })
}

const tabLabel = (d: { path: string; status: string; size: number; scanned: number }) => () => h(NTooltip, null, {
  trigger: () => h('span', { class: 'dump-tab' }, [
    d.status === 'scanning' ? h('span', { class: 'dump-spin', style: 'margin-right: 6px' }) : null,
    h('span', { class: 'mono' }, basename(d.path)),
    d.status === 'scanning' && d.size ? h('span', { class: 'dump-tab-pct' }, `${Math.floor((d.scanned / d.size) * 100)}%`) : null,
  ]),
  default: () => d.path,
})
</script>

<template>
  <div class="crashdump" @dragenter.prevent="onDragEnter" @dragover.prevent @dragleave="onDragLeave" @drop.prevent="onDrop">
    <PageHeader :title="t('crashdump.title')" :subtitle="current ? current.path : t('crashdump.subtitle')">
      <NButton @click="pick">
        <template #icon><NIcon :component="FolderOpenOutline" /></template>
        {{ t('crashdump.open_file') }}
      </NButton>
    </PageHeader>

    <NTabs v-if="dumps.list.length" type="card" size="small" :value="adding ? '__open' : (active ?? '__open')"
           closable addable class="files" @update:value="select" @close="(id: string) => close(id)"
           @add="adding = true">
      <NTab v-for="d in dumps.list" :key="d.id" :name="d.id" :tab="tabLabel(d)" />
      <NTab v-if="adding" name="__open" :tab="t('crashdump.new_tab')" :closable="false" />
    </NTabs>

    <DumpView v-if="current" :key="current.id" :info="current" @cancel="dumps.cancel(current.id)" />
    <DumpOpen v-else :opening="opening" :desktop="desktop" @open="open" @pick="pick" />

    <FileBrowser v-model:show="browsing" @open="open" />

    <div v-if="dragging" class="drop-overlay">
      <NIcon :component="CloudUploadOutline" :size="48" />
      <div>{{ t(desktop ? 'crashdump.drop_here' : 'crashdump.drop_browser') }}</div>
    </div>
  </div>
</template>

<style scoped>
.crashdump {
  position: relative;
  min-height: calc(100vh - 120px);
}
.files {
  margin-bottom: 16px;
}
.files :deep(.dump-tab) {
  display: inline-flex;
  align-items: center;
  max-width: 260px;
}
.files :deep(.dump-tab .mono) {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.files :deep(.dump-tab-pct) {
  margin-left: 6px;
  font-size: 11px;
  opacity: 0.6;
}
.drop-overlay {
  position: fixed;
  inset: 0;
  z-index: 3000;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 12px;
  font-size: 18px;
  background: rgba(32, 128, 240, 0.14);
  border: 3px dashed rgba(32, 128, 240, 0.7);
  backdrop-filter: blur(2px);
  pointer-events: none;
}
</style>
