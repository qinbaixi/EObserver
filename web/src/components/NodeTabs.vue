<script setup lang="ts">
import { computed, h, nextTick, ref, watch } from 'vue'
import { NButton, NDropdown, NIcon, useThemeVars, type DropdownOption } from 'naive-ui'
import { AddOutline, CloseOutline } from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'
import { pages, pageTitle } from '../router'
import { useNodes } from '../stores/nodes'
import { useTabs, NODE_MIME, type NodeTab } from '../stores/tabs'
import { useUi } from '../stores/ui'
import StatusDot from './StatusDot.vue'

// The node tabs, in the header next to (or in place of) the node switcher.
// Hidden while there is a single tab, shown as a drop zone while a node is
// dragged out of the node switcher.

const tabs = useTabs()
const nodes = useNodes()
const ui = useUi()
const themeVars = useThemeVars()
const { t } = useI18n()

const TAB_MIME = 'application/x-eobs-tab'

const visible = computed(() => tabs.tabs.length > 1 || ui.dragNode !== null)

function pageOf(tab: NodeTab) {
  const path = tab.path.split('?')[0]
  const p = pages.find((x) => x.path === path)
  return p ? pageTitle(p.meta) : ''
}

// The strip scrolls sideways (no scrollbar): with the mouse wheel, and to
// keep the active tab in view.
const strip = ref<HTMLElement | null>(null)

function onWheel(e: WheelEvent) {
  const el = strip.value
  if (!el || el.scrollWidth <= el.clientWidth || Math.abs(e.deltaX) > Math.abs(e.deltaY)) return
  e.preventDefault()
  el.scrollLeft += e.deltaY
}

watch(() => [tabs.active, visible.value], async () => {
  await nextTick()
  strip.value?.querySelector('.node-tab.active')?.scrollIntoView({ block: 'nearest', inline: 'nearest' })
})

const status = (tab: NodeTab) => nodes.nodes[tab.node]?.status ?? 'disconnected'

// --- dragging: reorder tabs, or drop a node to open it --------------------

const dragTab = ref<string | null>(null)
const dropBefore = ref<string | null | undefined>(undefined)

function onTabDragStart(e: DragEvent, tab: NodeTab) {
  dragTab.value = tab.id
  e.dataTransfer?.setData(TAB_MIME, tab.id)
  e.dataTransfer?.setData('text/plain', tab.node)
  if (e.dataTransfer) e.dataTransfer.effectAllowed = 'move'
}

function accepts(e: DragEvent) {
  const types = e.dataTransfer?.types ?? []
  return types.includes(TAB_MIME) || types.includes(NODE_MIME)
}

function onDragOver(e: DragEvent, before: string | null) {
  if (!accepts(e)) return
  e.preventDefault()
  if (e.dataTransfer) e.dataTransfer.dropEffect = dragTab.value ? 'move' : 'copy'
  dropBefore.value = before
}

function onTabDragOver(e: DragEvent, tab: NodeTab) {
  if (!accepts(e)) return
  // The left half of a tab drops before it, the right half after it.
  const r = (e.currentTarget as HTMLElement).getBoundingClientRect()
  const i = tabs.tabs.findIndex((x) => x.id === tab.id)
  const before = e.clientX < r.left + r.width / 2 ? tab.id : tabs.tabs[i + 1]?.id ?? null
  e.stopPropagation()
  onDragOver(e, before)
}

function onDrop(e: DragEvent) {
  if (!accepts(e)) return
  e.preventDefault()
  // The header around the tabs opens dropped nodes too.
  e.stopPropagation()
  const before = dropBefore.value ?? null
  const tabId = e.dataTransfer?.getData(TAB_MIME)
  const node = e.dataTransfer?.getData(NODE_MIME) || ui.dragNode
  if (tabId) {
    tabs.move(tabId, before)
  } else if (node) {
    const i = before ? tabs.tabs.findIndex((x) => x.id === before) : tabs.tabs.length
    tabs.open(node, tabs.tabs[i - 1]?.id ?? null)
  }
  endDrag()
}

function endDrag() {
  dragTab.value = null
  dropBefore.value = undefined
  ui.dragNode = null
}

// --- menus ------------------------------------------------------------------

const menu = ref<{ x: number; y: number; tab: NodeTab } | null>(null)

const menuOptions = computed<DropdownOption[]>(() => {
  const tab = menu.value?.tab
  if (!tab) return []
  const i = tabs.tabs.findIndex((x) => x.id === tab.id)
  return [
    { key: 'dup', label: t('shell.tabs.duplicate') },
    { type: 'divider', key: 'd1' },
    { key: 'close', label: t('shell.tabs.close') },
    { key: 'others', label: t('shell.tabs.close_others'), disabled: tabs.tabs.length < 2 },
    { key: 'right', label: t('shell.tabs.close_right'), disabled: i === tabs.tabs.length - 1 },
  ]
})

async function openMenu(e: MouseEvent, tab: NodeTab) {
  e.preventDefault()
  menu.value = null
  await nextTick()
  menu.value = { x: e.clientX, y: e.clientY, tab }
}

function onMenu(key: string) {
  const tab = menu.value?.tab
  menu.value = null
  if (!tab) return
  const i = tabs.tabs.findIndex((x) => x.id === tab.id)
  if (key === 'dup') tabs.open(tab.node, tab.id)
  else if (key === 'close') tabs.close([tab.id])
  else if (key === 'others') tabs.close(tabs.tabs.filter((x) => x.id !== tab.id).map((x) => x.id))
  else if (key === 'right') tabs.close(tabs.tabs.slice(i + 1).map((x) => x.id))
}

const CONNECT = '\u0000connect'

const addOptions = computed<DropdownOption[]>(() => [
  ...nodes.list.map((n) => ({
    key: n.node,
    label: () => h('span', { class: 'node-option' }, [
      h(StatusDot, { status: n.status }),
      h('span', { class: 'mono node-name' }, n.node),
    ]),
  })),
  { type: 'divider', key: 'd' },
  { key: CONNECT, label: t('shell.switcher.add'), icon: () => h(NIcon, { component: AddOutline }) },
])

function onAdd(key: string) {
  if (key === CONNECT) ui.openConnect()
  else tabs.open(key, null)
}

function onAux(e: MouseEvent, tab: NodeTab) {
  if (e.button === 1) {
    e.preventDefault()
    tabs.close([tab.id])
  }
}
</script>

<template>
  <div v-if="visible" ref="strip" class="node-tabs" :class="{ dropping: ui.dragNode !== null }"
       :style="{ '--tab-border': themeVars.borderColor, '--tab-active': themeVars.primaryColor,
                 '--tab-hover': themeVars.hoverColor, '--tab-text-dim': themeVars.textColor3 }"
       @dragover="onDragOver($event, null)" @drop="onDrop" @dragleave.self="dropBefore = undefined" @wheel="onWheel">
    <div v-for="tab in tabs.tabs" :key="tab.id" class="node-tab"
         :class="{ active: tab.id === tabs.active, dragging: tab.id === dragTab,
                   'drop-before': dropBefore === tab.id }"
         draggable="true" :title="tab.node"
         @click="tabs.activate(tab.id)" @auxclick="onAux($event, tab)" @mousedown.middle.prevent
         @contextmenu="openMenu($event, tab)"
         @dragstart="onTabDragStart($event, tab)" @dragend="endDrag"
         @dragover="onTabDragOver($event, tab)">
      <StatusDot :status="status(tab)" />
      <span class="mono tab-node">{{ tab.node }}</span>
      <span v-if="pageOf(tab)" class="tab-page">{{ pageOf(tab) }}</span>
      <button type="button" class="tab-close" :title="t('shell.tabs.close')"
              @click.stop="tabs.close([tab.id])">
        <NIcon :component="CloseOutline" />
      </button>
    </div>
    <div class="drop-end" :class="{ on: dropBefore === null }" />
    <div v-if="ui.dragNode !== null" class="drop-hint">{{ t('shell.tabs.drop_hint') }}</div>
    <NDropdown trigger="click" :options="addOptions" scrollable
               @select="onAdd">
      <NButton quaternary circle size="small" class="tab-add" :title="t('shell.tabs.add')">
        <template #icon><NIcon :component="AddOutline" /></template>
      </NButton>
    </NDropdown>
    <NDropdown placement="bottom-start" trigger="manual" :show="menu !== null" :options="menuOptions"
               :x="menu?.x ?? 0" :y="menu?.y ?? 0" @select="onMenu" @clickoutside="menu = null" />
  </div>
</template>

<style scoped>
.node-tabs {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  align-items: center;
  gap: 4px;
  height: 40px;
  padding: 0 2px;
  border-radius: 8px;
  overflow-x: auto;
  overflow-y: hidden;
  scrollbar-width: none;
}
.node-tabs.dropping {
  outline: 1px dashed var(--tab-active);
  outline-offset: -2px;
}
.node-tab {
  position: relative;
  flex: none;
  display: flex;
  align-items: center;
  gap: 7px;
  height: 30px;
  max-width: 280px;
  padding: 0 4px 0 11px;
  border: 1px solid var(--tab-border);
  border-radius: 15px;
  font-size: 13px;
  cursor: pointer;
  user-select: none;
  transition: background-color 0.15s, border-color 0.15s;
}
.node-tab:not(.active) {
  color: var(--tab-text-dim);
}
.node-tab:hover {
  background: var(--tab-hover);
}
.node-tab.active {
  border-color: var(--tab-active);
  background: color-mix(in srgb, var(--tab-active) 10%, transparent);
  color: var(--tab-active);
}
.node-tab.dragging {
  opacity: 0.4;
}
.node-tab.drop-before::after,
.drop-end.on::after {
  content: '';
  position: absolute;
  left: -4px;
  top: 4px;
  bottom: 4px;
  width: 2px;
  border-radius: 1px;
  background: var(--tab-active);
}
.drop-end {
  position: relative;
  flex: none;
  align-self: stretch;
  width: 0;
}
.tab-node {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  min-width: 0;
}
.tab-page {
  flex: none;
  font-size: 12px;
  opacity: 0.65;
}
.tab-close {
  flex: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 20px;
  height: 20px;
  margin-left: auto;
  padding: 0;
  border: none;
  border-radius: 50%;
  background: transparent;
  color: inherit;
  font-size: 13px;
  cursor: pointer;
  opacity: 0;
}
.node-tab:hover .tab-close,
.node-tab.active .tab-close {
  opacity: 0.6;
}
.tab-close:hover {
  opacity: 1 !important;
  background: var(--tab-hover);
}
.drop-hint {
  flex: none;
  font-size: 12px;
  opacity: 0.7;
  padding: 0 8px;
  white-space: nowrap;
}
.tab-add {
  flex: none;
}
</style>
