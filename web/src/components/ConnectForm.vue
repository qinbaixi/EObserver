<script setup lang="ts">
import { ref } from 'vue'
import { NForm, NFormItem, NInput, NButton, useMessage } from 'naive-ui'
import { useNodes } from '../stores/nodes'

const emit = defineEmits<{ connected: [] }>()
const nodes = useNodes()
const message = useMessage()
const node = ref('')
const cookie = ref('')
const loading = ref(false)

async function submit() {
  const name = node.value.trim()
  if (!/^[^@\s]+@[^@\s]+$/.test(name)) {
    message.warning('节点名格式应为 name@host')
    return
  }
  loading.value = true
  try {
    await nodes.connect(name, cookie.value.trim())
    message.success(`已添加 ${name}`)
    node.value = ''
    cookie.value = ''
    emit('connected')
  } catch (e) {
    message.error((e as Error).message)
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <NForm label-placement="top" @submit.prevent="submit">
    <NFormItem label="节点名">
      <NInput v-model:value="node" placeholder="app@hostname" class="mono" autofocus
              @keyup.enter="submit" />
    </NFormItem>
    <NFormItem label="Cookie">
      <NInput v-model:value="cookie" type="password" show-password-on="click"
              placeholder="留空则使用 ~/.erlang.cookie" @keyup.enter="submit" />
    </NFormItem>
    <NButton type="primary" block :loading="loading" @click="submit">连接</NButton>
  </NForm>
</template>
