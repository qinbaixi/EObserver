<script setup lang="ts">
import { computed, h } from 'vue'
import { NSelect, NButton, NIcon, NTooltip, useDialog, useMessage, type SelectOption } from 'naive-ui'
import { AddOutline, CloseOutline } from '@vicons/ionicons5'
import { useNodes } from '../stores/nodes'
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

// Wide enough for the current node's full name; the header shrinks it
// (with an ellipsis) only when the window is too narrow.
const selectWidth = computed(() => `calc(${(nodes.current ?? '').length}ch + 64px)`)

function confirmDisconnect() {
  const node = nodes.current
  if (!node) return
  dialog.warning({
    title: '断开节点',
    content: `停止观察 ${node}？目标节点不会受影响。`,
    positiveText: '断开',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await nodes.disconnect(node)
      } catch (e) {
        message.error((e as Error).message)
      }
    },
  })
}
</script>

<template>
  <div class="node-switcher">
    <NSelect v-if="nodes.list.length" :value="nodes.current" :options="options"
             :render-label="renderLabel" :consistent-menu-width="false"
             :menu-props="{ class: 'node-menu' }" :style="{ width: selectWidth }" class="node-select"
             placeholder="选择节点" @update:value="nodes.select" />
    <NTooltip>
      <template #trigger>
        <NButton secondary @click="ui.openConnect()">
          <template #icon><NIcon :component="AddOutline" /></template>
          添加节点
        </NButton>
      </template>
      通过节点名和 cookie 连接一个 Erlang 节点
    </NTooltip>
    <NButton v-if="nodes.current" quaternary circle @click="confirmDisconnect">
      <template #icon><NIcon :component="CloseOutline" /></template>
    </NButton>
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
.node-menu {
  max-width: min(720px, calc(100vw - 32px));
}
</style>
