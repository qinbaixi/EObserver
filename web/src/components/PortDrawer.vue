<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import {
  NDrawer, NDrawerContent, NDescriptions, NDescriptionsItem, NTag, NButton, NSpace,
  NEmpty, NSpin, NAlert, NIcon, useDialog, useMessage,
} from 'naive-ui'
import { RefreshOutline, CloseCircleOutline } from '@vicons/ionicons5'
import { client } from '../api/ws'
import { errorText } from '../api/errors'
import type { PortDetail } from '../api/types'
import { formatBytes, formatNumber } from '../api/format'
import { useSettings } from '../stores/settings'
import Term from './Term.vue'

const props = defineProps<{ node: string; port: string | null }>()
const emit = defineEmits<{ 'update:port': [string | null]; openPid: [string] }>()
const dialog = useDialog()
const message = useMessage()
const settings = useSettings()
const detail = ref<PortDetail | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)

const show = computed({
  get: () => props.port !== null,
  set: (v) => { if (!v) emit('update:port', null) },
})

async function load() {
  if (!props.port) return
  loading.value = true
  error.value = null
  try {
    detail.value = await client.request<PortDetail>('port.info', { node: props.node, port: props.port })
  } catch (e) {
    detail.value = null
    error.value = errorText(e)
  } finally {
    loading.value = false
  }
}
watch(() => props.port, () => void load(), { immediate: true })

function close() {
  const port = props.port
  dialog.error({
    title: '关闭端口',
    content: `调用 erlang:port_close(${port})？使用该端口的进程会收到错误。`,
    positiveText: '关闭',
    negativeText: '取消',
    onPositiveClick: async () => {
      try {
        await client.request('port.close', { node: props.node, port })
        message.success(`已关闭 ${port}`)
        await load()
      } catch (e) {
        message.error(errorText(e))
      }
    },
  })
}

function pid(ref: string) {
  if (ref.startsWith('<')) emit('openPid', ref)
}
</script>

<template>
  <NDrawer v-model:show="show" :width="560" placement="right">
    <NDrawerContent closable>
      <template #header>
        <NSpace align="center" :size="8">
          <span class="mono">{{ port }}</span>
          <NTag v-if="detail" size="small" :bordered="false">{{ detail.name }}</NTag>
          <NButton quaternary circle size="small" :loading="loading" @click="load">
            <template #icon><NIcon :component="RefreshOutline" /></template>
          </NButton>
        </NSpace>
      </template>
      <NSpin v-if="loading && !detail" style="width: 100%; padding: 60px 0" />
      <NEmpty v-else-if="error === 'not_found'" description="端口已关闭" style="padding: 60px 0" />
      <NAlert v-else-if="error" type="error">{{ error }}</NAlert>
      <template v-else-if="detail">
        <NDescriptions :column="1" label-placement="left" size="small" bordered>
          <NDescriptionsItem label="名称"><span class="mono">{{ detail.name }}</span></NDescriptionsItem>
          <NDescriptionsItem v-if="detail.registered_name" label="注册名">{{ detail.registered_name }}</NDescriptionsItem>
          <NDescriptionsItem><template #label><Term label="所属进程" /></template>
            <a v-if="detail.connected" class="mono link" @click="pid(detail.connected)">{{ detail.connected }}</a>
          </NDescriptionsItem>
          <NDescriptionsItem v-if="detail.os_pid"><template #label><Term label="OS pid" /></template>{{ detail.os_pid }}</NDescriptionsItem>
          <NDescriptionsItem v-if="detail.protocol" label="协议">{{ detail.protocol }}</NDescriptionsItem>
          <NDescriptionsItem v-if="detail.local !== undefined" label="本地地址"><span class="mono">{{ detail.local ?? '-' }}</span></NDescriptionsItem>
          <NDescriptionsItem v-if="detail.remote !== undefined" label="远端地址"><span class="mono">{{ detail.remote ?? '-' }}</span></NDescriptionsItem>
          <NDescriptionsItem label="输入 / 输出">{{ formatBytes(detail.input) }} / {{ formatBytes(detail.output) }}</NDescriptionsItem>
          <NDescriptionsItem><template #label><Term label="队列" /></template>{{ formatBytes(detail.queue_size) }}</NDescriptionsItem>
          <NDescriptionsItem><template #label><Term label="内存" /></template>{{ formatBytes(detail.memory) }}</NDescriptionsItem>
          <NDescriptionsItem label="锁">{{ detail.locking ?? '-' }}</NDescriptionsItem>
          <NDescriptionsItem label="并行">{{ detail.parallelism ? '是' : '否' }}</NDescriptionsItem>
        </NDescriptions>
        <div v-if="detail.stats && Object.keys(detail.stats).length" class="group">
          <div class="group-title">Socket 统计</div>
          <NSpace :size="6">
            <NTag v-for="(v, k) in detail.stats" :key="k" size="small" :bordered="false">
              {{ k }}: <span class="mono">{{ formatNumber(v) }}</span>
            </NTag>
          </NSpace>
        </div>
        <div v-for="g in [{ title: 'Links', items: detail.links }, { title: 'Monitors', items: detail.monitors }]"
             :key="g.title" class="group">
          <div class="group-title"><Term :label="g.title" /> <span class="count">{{ g.items.length }}</span></div>
          <NSpace v-if="g.items.length" :size="6">
            <NTag v-for="r in g.items" :key="r" size="small" class="mono clickable" @click="pid(r)">{{ r }}</NTag>
          </NSpace>
          <div v-else class="count">无</div>
        </div>
        <div v-if="!settings.readOnly" class="group">
          <NButton type="error" secondary @click="close">
            <template #icon><NIcon :component="CloseCircleOutline" /></template>
            关闭端口
          </NButton>
        </div>
      </template>
    </NDrawerContent>
  </NDrawer>
</template>

<style scoped>
.group {
  margin-top: 20px;
}
.group-title {
  font-weight: 600;
  margin-bottom: 8px;
}
.count {
  opacity: 0.55;
}
.link, .clickable {
  cursor: pointer;
}
.link:hover {
  text-decoration: underline;
}
</style>
