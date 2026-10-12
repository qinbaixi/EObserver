<script setup lang="ts">
// Shows the node's connection state instead of page content until the
// current node is connected.
import { NAlert, NSpin, NButton } from 'naive-ui'
import { useNodes } from '../stores/nodes'

const nodes = useNodes()

async function retry() {
  const n = nodes.currentInfo
  if (n) await nodes.connect(n.node, '')
}
</script>

<template>
  <div v-if="!nodes.currentInfo" />
  <div v-else-if="nodes.currentInfo.status === 'connecting'" class="center">
    <NSpin size="large" />
    <p>正在连接 <span class="mono">{{ nodes.currentInfo.node }}</span>…</p>
  </div>
  <NAlert v-else-if="nodes.currentInfo.status !== 'connected'"
          :type="nodes.currentInfo.status === 'failed' ? 'error' : 'warning'"
          :title="nodes.currentInfo.status === 'failed' ? '无法观察此节点' : '节点未连接，正在自动重连'">
    {{ nodes.currentInfo.error }}
    <template v-if="nodes.currentInfo.status === 'failed'">
      <div style="margin-top: 12px"><NButton size="small" @click="retry">重试</NButton></div>
    </template>
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
