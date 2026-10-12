<script setup lang="ts">
import { computed, h, type VNode } from 'vue'
import { NSelect, NButton, NIcon, NTooltip, useDialog, useMessage, type SelectOption } from 'naive-ui'
import { AddOutline, CloseOutline } from '@vicons/ionicons5'
import { useNodes } from '../stores/nodes'
import { errorText } from '../api/errors'
import StatusDot from './StatusDot.vue'
import { useUi } from '../stores/ui'
import type { NodeStatus } from '../api/types'

const nodes = useNodes()
const dialog = useDialog()
const message = useMessage()
const ui = useUi()

const options = computed<SelectOption[]>(() =>
  nodes.list.map((n) => ({ label: n.node, value: n.node, status: n.status })),
)

function renderLabel(option: SelectOption) {
  return h('span', { class: 'node-option', title: option.label as string }, [
    h(StatusDot, { status: option.status as NodeStatus }),
    h('span', { class: 'mono node-name' }, option.label as string),
  ])
}

// Menu rows get a remove button on the right.
function renderOption({ node, option }: { node: VNode; option: SelectOption }) {
  return h('div', { class: 'node-row' }, [
    node,
    h(NButton, {
      quaternary: true, circle: true, size: 'tiny', class: 'node-remove', title: '移除这个节点',
      // Keep the click from selecting the row.
      onMousedown: (e: MouseEvent) => e.stopPropagation(),
      onClick: (e: MouseEvent) => { e.stopPropagation(); void remove([option.value as string]) },
    }, { icon: () => h(NIcon, { component: CloseOutline }) }),
  ])
}

const offline = computed(() => nodes.list.filter((n) => n.status !== 'connected').map((n) => n.node))

async function remove(list: string[]) {
  try {
    for (const node of list) await nodes.disconnect(node)
    message.success(list.length === 1 ? `已移除 ${list[0]}` : `已移除 ${list.length} 个节点`)
  } catch (e) {
    message.error(errorText(e))
  }
}

function confirmRemoveAll() {
  const all = nodes.list.map((n) => n.node)
  dialog.warning({
    title: '移除全部节点',
    content: `停止观察全部 ${all.length} 个节点？目标节点不会受影响。`,
    positiveText: '全部移除',
    negativeText: '取消',
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
    title: '移除节点',
    content: `停止观察 ${node} 并从列表中移除？目标节点不会受影响。`,
    positiveText: '移除',
    negativeText: '取消',
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
  <div class="node-switcher">
    <NSelect v-if="nodes.list.length" :value="nodes.current" :options="options"
             :render-label="renderLabel" :render-option="renderOption" :consistent-menu-width="false"
             :menu-props="{ class: 'node-menu' }" :style="{ width: selectWidth }" class="node-select"
             placeholder="选择节点" @update:value="nodes.select">
      <template #action>
        <div class="node-actions">
          <NButton size="tiny" quaternary :disabled="!offline.length" @click="remove(offline)">
            移除未连接的节点（{{ offline.length }}）
          </NButton>
          <NButton size="tiny" quaternary type="error" @click="confirmRemoveAll">全部移除</NButton>
        </div>
      </template>
    </NSelect>
    <NTooltip>
      <template #trigger>
        <NButton secondary @click="ui.openConnect()">
          <template #icon><NIcon :component="AddOutline" /></template>
          添加节点
        </NButton>
      </template>
      通过节点名和 cookie 连接一个 Erlang 节点
    </NTooltip>
    <NTooltip v-if="nodes.current">
      <template #trigger>
        <NButton quaternary circle @click="confirmDisconnect">
          <template #icon><NIcon :component="CloseOutline" /></template>
        </NButton>
      </template>
      移除当前节点（停止观察）
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
