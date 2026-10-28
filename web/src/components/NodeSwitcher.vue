<script setup lang="ts">
import { computed, h, nextTick, ref, type VNode } from 'vue'
import { NSelect, NButton, NIcon, NTooltip, NDropdown, useDialog, useMessage, type SelectOption, type DropdownOption } from 'naive-ui'
import { AddOutline, CloseOutline } from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'
import { useNodes } from '../stores/nodes'
import { errorText } from '../api/errors'
import StatusDot from './StatusDot.vue'
import { useUi } from '../stores/ui'
import { useTabs, NODE_MIME } from '../stores/tabs'
import type { NodeStatus } from '../api/types'

// compact: beside the node tabs, where the add button shows only its icon.
defineProps<{ compact?: boolean }>()

const nodes = useNodes()
const dialog = useDialog()
const message = useMessage()
const ui = useUi()
const tabs = useTabs()
const showMenu = ref(false)
const { t } = useI18n()

const options = computed<SelectOption[]>(() =>
  nodes.list.map((n) => ({ label: n.node, value: n.node, status: n.status })),
)

function renderLabel(option: SelectOption) {
  return h('span', { class: 'node-option', title: option.label as string }, [
    h(StatusDot, { status: option.status as NodeStatus }),
    h('span', { class: 'mono node-name' }, option.label as string),
  ])
}

// Menu rows get a remove button on the right. A row can also open its node
// in a new tab: right-click or long-press it for a menu, Ctrl/⌘-click it, or
// drag it onto the tab strip or the page.
const LONG_PRESS_MS = 500
let pressTimer: number | undefined
let pressed = false

function cancelPress() {
  window.clearTimeout(pressTimer)
  pressTimer = undefined
}

function renderOption({ node, option }: { node: VNode; option: SelectOption }) {
  const value = option.value as string
  return h('div', {
    class: 'node-row',
    draggable: 'true',
    // The menu cancels mousedown (to keep focus in the select), which also
    // cancels dragging; focusing the row instead keeps the menu open.
    tabindex: -1,
    onMousedown: (e: MouseEvent) => { if (e.button === 0) e.stopPropagation() },
    title: t('shell.tabs.row_tip'),
    onClickCapture: (e: MouseEvent) => {
      // A long press already opened the menu; don't also select the row.
      if (pressed || e.ctrlKey || e.metaKey) {
        e.stopPropagation()
        e.preventDefault()
        if (!pressed) { showMenu.value = false; tabs.open(value) }
        pressed = false
      }
    },
    onContextmenu: (e: MouseEvent) => openRowMenu(e, value),
    onPointerdown: (e: PointerEvent) => {
      if (e.button !== 0) return
      pressed = false
      cancelPress()
      pressTimer = window.setTimeout(() => {
        pressed = true
        openRowMenu(e, value)
      }, LONG_PRESS_MS)
    },
    onPointerup: cancelPress,
    onPointerleave: cancelPress,
    onPointercancel: cancelPress,
    onDragstart: (e: DragEvent) => {
      cancelPress()
      e.dataTransfer?.setData(NODE_MIME, value)
      e.dataTransfer?.setData('text/plain', value)
      if (e.dataTransfer) e.dataTransfer.effectAllowed = 'copy'
      ui.dragNode = value
    },
    onDragend: () => { ui.dragNode = null },
  }, [
    node,
    h(NButton, {
      quaternary: true, circle: true, size: 'tiny', class: 'node-remove', title: t('shell.switcher.remove_one'),
      // Keep the click from selecting the row.
      onMousedown: (e: MouseEvent) => e.stopPropagation(),
      onPointerdown: (e: PointerEvent) => e.stopPropagation(),
      onClick: (e: MouseEvent) => { e.stopPropagation(); void remove([value]) },
    }, { icon: () => h(NIcon, { component: CloseOutline }) }),
  ])
}

const rowMenu = ref<{ x: number; y: number; node: string } | null>(null)

const rowMenuOptions = computed<DropdownOption[]>(() => [
  { key: 'tab', label: t('shell.tabs.open_new') },
  { key: 'here', label: t('shell.tabs.open_here'), disabled: rowMenu.value?.node === nodes.current },
  { type: 'divider', key: 'd' },
  { key: 'remove', label: t('shell.switcher.remove_one') },
])

async function openRowMenu(e: MouseEvent, node: string) {
  e.preventDefault()
  rowMenu.value = null
  await nextTick()
  rowMenu.value = { x: e.clientX, y: e.clientY, node }
}

// A click back in the node list keeps it open; anywhere else closes it too.
function onRowMenuOutside(e: MouseEvent) {
  rowMenu.value = null
  if (!(e.target as Element | null)?.closest?.('.node-menu')) showMenu.value = false
}

function onRowMenu(key: string) {
  const node = rowMenu.value?.node
  rowMenu.value = null
  showMenu.value = false
  if (!node) return
  if (key === 'tab') tabs.open(node)
  else if (key === 'here') nodes.select(node)
  else if (key === 'remove') void remove([node])
}

const offline = computed(() => nodes.list.filter((n) => n.status !== 'connected').map((n) => n.node))

async function remove(list: string[]) {
  try {
    for (const node of list) await nodes.disconnect(node)
    message.success(list.length === 1
      ? t('shell.switcher.removed_one', { node: list[0] })
      : t('shell.switcher.removed_n', { n: list.length }))
  } catch (e) {
    message.error(errorText(e))
  }
}

function confirmRemoveAll() {
  const all = nodes.list.map((n) => n.node)
  dialog.warning({
    title: t('shell.switcher.remove_all_title'),
    content: t('shell.switcher.remove_all_content', { n: all.length }),
    positiveText: t('shell.switcher.remove_all_ok'),
    negativeText: t('shell.switcher.cancel'),
    onPositiveClick: () => remove(all),
  })
}

// Wide enough for the current node's full name; the header shrinks it
// (with an ellipsis) only when the window is too narrow.
const selectWidth = computed(() => `calc(${(nodes.current ?? '').length}ch + 64px)`)

function confirmDisconnect() {
  const node = nodes.current
  if (!node) return
  dialog.warning({
    title: t('shell.switcher.remove_title'),
    content: t('shell.switcher.remove_content', { node }),
    positiveText: t('shell.switcher.remove_ok'),
    negativeText: t('shell.switcher.cancel'),
    onPositiveClick: async () => {
      try {
        await nodes.disconnect(node)
      } catch (e) {
        message.error(errorText(e))
      }
    },
  })
}
</script>

<template>
  <div class="node-switcher" :class="{ compact }">
    <NSelect v-if="nodes.list.length" :value="nodes.current" :options="options"
             :render-label="renderLabel" :render-option="renderOption" :consistent-menu-width="false"
             :menu-props="{ class: 'node-menu' }" :style="{ width: selectWidth }" class="node-select"
             :placeholder="t('shell.switcher.placeholder')" :show="showMenu"
             @update:show="(v: boolean) => { if (!rowMenu || v) showMenu = v }" @update:value="nodes.select">
      <template #action>
        <div class="node-actions">
          <NButton size="tiny" quaternary :disabled="!offline.length" @click="remove(offline)">
            {{ t('shell.switcher.remove_offline', { n: offline.length }) }}
          </NButton>
          <NButton size="tiny" quaternary type="error" @click="confirmRemoveAll">{{ t('shell.switcher.remove_all') }}</NButton>
        </div>
      </template>
    </NSelect>
    <NDropdown placement="bottom-start" trigger="manual" :show="rowMenu !== null" :options="rowMenuOptions"
               :x="rowMenu?.x ?? 0" :y="rowMenu?.y ?? 0" @select="onRowMenu"
               @clickoutside="onRowMenuOutside" />
    <NTooltip>
      <template #trigger>
        <NButton secondary @click="ui.openConnect()">
          <template #icon><NIcon :component="AddOutline" /></template>
          <template v-if="!compact">{{ t('shell.switcher.add') }}</template>
        </NButton>
      </template>
      {{ t('shell.switcher.add_tip') }}
    </NTooltip>
    <NTooltip v-if="nodes.current">
      <template #trigger>
        <NButton quaternary circle @click="confirmDisconnect">
          <template #icon><NIcon :component="CloseOutline" /></template>
        </NButton>
      </template>
      {{ t('shell.switcher.remove_current_tip') }}
    </NTooltip>
  </div>
</template>

<style scoped>
.node-switcher {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.node-switcher > * {
  flex: none;
}
.node-switcher > .node-select {
  flex: 0 1 auto;
  min-width: 220px;
}
.node-switcher.compact > .node-select {
  min-width: 160px;
}
</style>

<style>
.node-option {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
  max-width: 100%;
}
.node-option .node-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.node-row {
  display: flex;
  align-items: center;
  outline: none;
}
.node-row > :first-child {
  flex: 1;
  min-width: 0;
}
.node-row .node-remove {
  margin-right: 6px;
  opacity: 0;
}
.node-row:hover .node-remove {
  opacity: 0.7;
}
.node-actions {
  display: flex;
  justify-content: space-between;
  gap: 8px;
}
.node-menu {
  max-width: min(720px, calc(100vw - 32px));
}
</style>
