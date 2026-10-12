<script setup lang="ts">
import { ref, watch } from 'vue'
import { NForm, NFormItem, NInput, NButton, NTabs, NTabPane, useMessage } from 'naive-ui'
import { useNodes } from '../stores/nodes'
import { errorText } from '../api/errors'
import { useUi } from '../stores/ui'
import { useCookies, type CookieChoice } from '../stores/cookies'
import CookiePicker from './CookiePicker.vue'
import LocalNodesForm from './LocalNodesForm.vue'

const emit = defineEmits<{ connected: [] }>()
const nodes = useNodes()
const cookies = useCookies()
const message = useMessage()
const ui = useUi()

const TAB_KEY = 'eobs.connectTab'
const tab = ref(ui.connectNode ? 'manual' : storedTab())
const node = ref(ui.connectNode)
watch(() => ui.connectNode, (n) => {
  node.value = n
  if (n) tab.value = 'manual'
})
watch(tab, (t) => {
  try {
    localStorage.setItem(TAB_KEY, t)
  } catch {
    /* storage unavailable */
  }
})
const choice = ref<CookieChoice>({ kind: 'new', cookie: '', label: '', remember: true })
const loading = ref(false)

function storedTab() {
  try {
    return localStorage.getItem(TAB_KEY) === 'manual' ? 'manual' : 'local'
  } catch {
    return 'local'
  }
}

async function submit() {
  const name = node.value.trim()
  if (!/^[^@\s]+@[^@\s]+$/.test(name)) {
    message.warning('节点名格式应为 name@host')
    return
  }
  loading.value = true
  try {
    await nodes.connect(name, await cookies.params(choice.value))
    message.success(`已添加 ${name}`)
    node.value = ''
    ui.connectNode = ''
    if (choice.value.kind === 'new') choice.value = cookies.lastChoice()
    emit('connected')
  } catch (e) {
    message.error(errorText(e))
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <NTabs v-model:value="tab" type="segment" animated>
    <NTabPane name="local" tab="本机节点">
      <LocalNodesForm @connected="emit('connected')" />
    </NTabPane>
    <NTabPane name="manual" tab="手动输入">
      <NForm label-placement="top" @submit.prevent="submit">
        <NFormItem label="节点名">
          <NInput v-model:value="node" placeholder="app@hostname" class="mono"
                  @keyup.enter="submit" />
        </NFormItem>
        <NFormItem label="Cookie">
          <CookiePicker v-model="choice" />
        </NFormItem>
        <NButton type="primary" block :loading="loading" @click="submit">连接</NButton>
      </NForm>
    </NTabPane>
  </NTabs>
</template>
