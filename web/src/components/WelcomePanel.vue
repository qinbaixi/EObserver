<script setup lang="ts">
import { ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRouter } from 'vue-router'
import { NCard, NButton, NIcon, useMessage } from 'naive-ui'
import { FolderOpenOutline } from '@vicons/ionicons5'
import ConnectForm from './ConnectForm.vue'
import { useTrace } from '../stores/trace'
import { errorText } from '../api/errors'

const { t } = useI18n()
const router = useRouter()
const message = useMessage()
const trace = useTrace()
const fileInput = ref<HTMLInputElement | null>(null)

// A saved trace can be viewed without connecting to any node.
async function onFile(ev: Event) {
  const input = ev.target as HTMLInputElement
  const file = input.files?.[0]
  input.value = ''
  if (!file) return
  try {
    await trace.open(file)
    void router.push('/trace')
  } catch (e) {
    message.error(e instanceof Error && e.message === 'bad_file' ? t('trace.file.bad_file') : errorText(e))
  }
}
</script>

<template>
  <div class="welcome">
    <img src="/favicon.svg" alt="" class="logo" />
    <h1>EObserver</h1>
    <p class="lead">连接一个 Erlang 节点开始观察。EObserver 以隐藏节点身份连接，不会出现在目标节点的 <code>nodes()</code> 中。</p>
    <NCard style="width: 520px; max-width: 94vw; text-align: left">
      <ConnectForm />
    </NCard>
    <NButton text class="open" @click="fileInput?.click()">
      <template #icon><NIcon :component="FolderOpenOutline" /></template>
      {{ t('trace.file.open_welcome') }}
    </NButton>
    <input ref="fileInput" type="file" accept=".json,application/json" hidden @change="onFile" />
  </div>
</template>

<style scoped>
.welcome {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding-top: 8vh;
  text-align: center;
}
.logo {
  width: 56px;
  height: 56px;
}
h1 {
  margin: 16px 0 8px;
  font-size: 28px;
}
.lead {
  max-width: 460px;
  opacity: 0.7;
  margin: 0 0 24px;
  line-height: 1.6;
}
.open {
  margin-top: 16px;
  opacity: 0.75;
}
</style>
