<script setup lang="ts">
// Shows the node's connection state instead of page content until the
// current node is connected.
import { ref } from 'vue'
import { NAlert, NSpin, NButton, NSpace, useMessage, useDialog } from 'naive-ui'
import { useNodes } from '../stores/nodes'
import { useUi } from '../stores/ui'
import { errorText } from '../api/errors'

const nodes = useNodes()
const ui = useUi()
const message = useMessage()
const dialog = useDialog()
const busy = ref(false)

async function retry() {
  const n = nodes.currentInfo
  if (!n) return
  busy.value = true
  try {
    await nodes.connect(n.node, {})
  } catch (e) {
    message.error(`重试失败：${errorText(e)}`)
  } finally {
    busy.value = false
  }
}

function changeCookie() {
  const n = nodes.currentInfo
  if (n) ui.openConnect(n.node)
}

function remove() {
  const n = nodes.currentInfo
  if (!n) return
  dialog.warning({
    title: '移除节点',
    content: `停止观察 ${n.node}，并从节点列表中移除？`,
    positiveText: '移除',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await nodes.disconnect(n.node)
      } catch (e) {
        message.error(`移除失败：${errorText(e)}`)
      }
    },
  })
}
</script>

<template>
  <div v-if="!nodes.currentInfo" />
  <div v-else-if="nodes.currentInfo.status === 'connecting'" class="center">
    <NSpin size="large" />
    <p>正在连接 <span class="mono">{{ nodes.currentInfo.node }}</span>…</p>
    <NSpace>
      <NButton size="small" @click="changeCookie">换个 cookie</NButton>
      <NButton size="small" @click="remove">移除节点</NButton>
    </NSpace>
  </div>
  <NAlert v-else-if="nodes.currentInfo.status !== 'connected'"
          :type="nodes.currentInfo.status === 'failed' ? 'error' : 'warning'"
          :title="nodes.currentInfo.status === 'failed' ? '无法观察此节点' : '节点未连接，正在自动重连'">
    {{ nodes.currentInfo.error }}
    <NSpace style="margin-top: 12px">
      <NButton size="small" type="primary" :loading="busy" @click="retry">立即重试</NButton>
      <NButton size="small" @click="changeCookie">换个 cookie 重连</NButton>
      <NButton size="small" @click="remove">移除节点</NButton>
    </NSpace>
  </NAlert>
  <slot v-else />
</template>

<style scoped>
.center {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 80px 0;
  opacity: 0.8;
}
</style>
