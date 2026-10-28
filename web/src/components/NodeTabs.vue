<script setup lang="ts">
import { computed, h, nextTick, ref } from 'vue'
import { NButton, NDropdown, NIcon, NTooltip, useThemeVars, type DropdownOption } from 'naive-ui'
import { AddOutline, CloseOutline } from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'
import { pages, pageTitle } from '../router'
import { useNodes } from '../stores/nodes'
import { useTabs, NODE_MIME, type NodeTab } from '../stores/tabs'
import { useUi } from '../stores/ui'
import StatusDot from './StatusDot.vue'

// The tab strip under the header. Hidden while there is a single tab,
// shown as a drop zone while a node is dragged out of the node switcher.

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

const addOptions = computed<DropdownOption[]>(() => nodes.list.map((n) => ({
  key: n.node,
  label: () => h('span', { class: 'node-option' }, [
    h(StatusDot, { status: n.status }),
    h('span', { class: 'mono node-name' }, n.node),
  ]),
})))

function onAux(e: MouseEvent, tab: NodeTab) {
  if (e.button === 1) {
    e.preventDefault()
    tabs.close([tab.id])
  }
}
</script>

<template>
  <div v-if="visible" class="node-tabs" :class="{ dropping: ui.dragNode !== null }"
       :style="{ '--tab-border': themeVars.borderColor, '--tab-active': themeVars.primaryColor,
                 '--tab-hover': themeVars.hoverColor, '--tab-bg': themeVars.cardColor }"
       @dragover="onDragOver($event, null)" @drop="onDrop" @dragleave.self="dropBefore = undefined">
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
               @select="(n: string) => tabs.open(n, null)">
      <span>
        <NTooltip>
          <template #trigger>
            <NButton quaternary circle size="tiny" class="tab-add">
              <template #icon><NIcon :component="AddOutline" /></template>
            </NButton>
          </template>
          {{ t('shell.tabs.add') }}
        </NTooltip>
      </span>
    </NDropdown>
    <NDropdown placement="bottom-start" trigger="manual" :show="menu !== null" :options="menuOptions"
               :x="menu?.x ?? 0" :y="menu?.y ?? 0" @select="onMenu" @clickoutside="menu = null" />
  </div>
</template>

<style scoped>
.node-tabs {
  display: flex;
  align-items: flex-end;
  gap: 2px;
  height: 38px;
  padding: 0 12px;
  border-bottom: 1px solid var(--tab-border);
  overflow-x: auto;
  overflow-y: hidden;
  scrollbar-width: thin;
}
.node-tabs.dropping {
  background: var(--tab-hover);
}
.node-tab {
  position: relative;
  flex: 0 1 auto;
  display: flex;
  align-items: center;
  gap: 7px;
  height: 32px;
  max-width: 300px;
  min-width: 120px;
  padding: 0 6px 0 12px;
  border: 1px solid transparent;
  border-bottom: none;
  border-radius: 6px 6px 0 0;
  font-size: 13px;
  cursor: pointer;
  user-select: none;
  opacity: 0.72;
}
.node-tab:hover {
  background: var(--tab-hover);
  opacity: 1;
}
.node-tab.active {
  opacity: 1;
  background: var(--tab-bg);
  border-color: var(--tab-border);
  margin-bottom: -1px;
  height: 33px;
}
.node-tab.active::before {
  content: '';
  position: absolute;
  left: 8px;
  right: 8px;
  top: 0;
  height: 2px;
  border-radius: 0 0 2px 2px;
  background: var(--tab-active);
}
.node-tab.dragging {
  opacity: 0.4;
}
.node-tab.drop-before::after,
.drop-end.on::after {
  content: '';
  position: absolute;
  left: -2px;
  top: 6px;
  bottom: 6px;
  width: 2px;
  background: var(--tab-active);
}
.drop-end {
  position: relative;
  align-self: stretch;
  width: 2px;
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
  opacity: 0.6;
}
.tab-close {
  flex: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 18px;
  height: 18px;
  margin-left: auto;
  padding: 0;
  border: none;
  border-radius: 4px;
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
  align-self: center;
  font-size: 12px;
  opacity: 0.7;
  padding: 0 8px;
  white-space: nowrap;
}
.tab-add {
  margin: 0 0 6px 4px;
}
</style>
