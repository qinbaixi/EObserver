<script setup lang="ts">
// Shows the node's connection state instead of page content until the
// current node is connected.
import { ref } from 'vue'
import { NAlert, NSpin, NButton, NSpace, useMessage, useDialog } from 'naive-ui'
import { useI18n } from 'vue-i18n'
import { useNodes } from '../stores/nodes'
import { useUi } from '../stores/ui'
import { errorText } from '../api/errors'

const nodes = useNodes()
const ui = useUi()
const message = useMessage()
const dialog = useDialog()
const busy = ref(false)
const { t } = useI18n()

async function retry() {
  const n = nodes.currentInfo
  if (!n) return
  busy.value = true
  try {
    await nodes.connect(n.node, {})
  } catch (e) {
    message.error(t('shell.guard.retry_failed', { error: errorText(e) }))
  } finally {
    busy.value = false
  }
}

// The backend reports why a node is down in English (eobs_node:format_error).
function nodeError(text: string | null | undefined) {
  if (!text) return ''
  if (text.startsWith('Node is unreachable')) return t('shell.guard.unreachable')
  if (text === 'Connection lost') return t('shell.guard.nodedown')
  const m = /^EObserver already runs with (\S+), but this node needs (\S+)$/.exec(text)
  if (m) return t('shell.guard.name_domain', { have: m[1], want: m[2] })
  return text
}

function changeCookie() {
  const n = nodes.currentInfo
  if (n) ui.openConnect(n.node)
}

function remove() {
  const n = nodes.currentInfo
  if (!n) return
  dialog.warning({
    title: t('shell.guard.remove_title'),
    content: t('shell.guard.remove_content', { node: n.node }),
    positiveText: t('shell.guard.remove_ok'),
    negativeText: t('shell.guard.cancel'),
    onPositiveClick: async () => {
      try {
        await nodes.disconnect(n.node)
      } catch (e) {
        message.error(t('shell.guard.remove_failed', { error: errorText(e) }))
      }
    },
  })
}
</script>

<template>
  <div v-if="!nodes.currentInfo" />
  <div v-else-if="nodes.currentInfo.status === 'connecting'" class="center">
    <NSpin size="large" />
    <i18n-t keypath="shell.guard.connecting" tag="p">
      <template #node><span class="mono">{{ nodes.currentInfo.node }}</span></template>
    </i18n-t>
    <NSpace>
      <NButton size="small" @click="changeCookie">{{ t('shell.guard.change_cookie') }}</NButton>
      <NButton size="small" @click="remove">{{ t('shell.guard.remove') }}</NButton>
    </NSpace>
  </div>
  <NAlert v-else-if="nodes.currentInfo.status !== 'connected'"
          :type="nodes.currentInfo.status === 'failed' ? 'error' : 'warning'"
          :title="nodes.currentInfo.status === 'failed' ? t('shell.guard.failed') : t('shell.guard.reconnecting')">
    {{ nodeError(nodes.currentInfo.error) }}
    <NSpace style="margin-top: 12px">
      <NButton size="small" type="primary" :loading="busy" @click="retry">{{ t('shell.guard.retry') }}</NButton>
      <NButton size="small" @click="changeCookie">{{ t('shell.guard.retry_cookie') }}</NButton>
      <NButton size="small" @click="remove">{{ t('shell.guard.remove') }}</NButton>
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
