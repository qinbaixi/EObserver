<script setup lang="ts">
import { computed, h } from 'vue'
import { NSelect, NButton, NIcon, NSpace, NTooltip, useDialog, useMessage, type SelectOption } from 'naive-ui'
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
  return h('span', { style: 'display:inline-flex;align-items:center;gap:8px' }, [
    h(StatusDot, { status: option.status as NodeStatus }),
    h('span', { class: 'mono' }, option.label as string),
  ])
}

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
  <NSpace align="center" :size="8">
    <NSelect v-if="nodes.list.length" :value="nodes.current" :options="options"
             :render-label="renderLabel" style="width: 320px"
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
  </NSpace>
</template>
