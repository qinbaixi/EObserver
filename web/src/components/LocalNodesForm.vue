<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import {
  NSelect, NButton, NIcon, NCheckbox, NFormItem, NEmpty, NAlert, NTag, NText, NSpin, useMessage,
} from 'naive-ui'
import { RefreshOutline } from '@vicons/ionicons5'
import { client } from '../api/ws'
import { errorText } from '../api/errors'
import type { Discovery } from '../api/types'
import { useNodes } from '../stores/nodes'
import { useCookies, type CookieChoice } from '../stores/cookies'
import CookiePicker from './CookiePicker.vue'

// Lists the nodes registered with this machine's epmd and connects the
// selected ones with one cookie.
const emit = defineEmits<{ connected: [] }>()
const nodes = useNodes()
const cookies = useCookies()
const message = useMessage()

const HOST_KEY = 'eobs.discoverHost'
const data = ref<Discovery | null>(null)
const host = ref<string | null>(storedHost())
const loading = ref(false)
const connecting = ref(false)
const picked = ref<string[]>([])
const choice = ref<CookieChoice>({ kind: 'new', cookie: '', label: '', remember: true })

function storedHost() {
  try {
    return localStorage.getItem(HOST_KEY)
  } catch {
    return null
  }
}

async function load() {
  loading.value = true
  try {
    data.value = await client.request<Discovery>('nodes.discover', { host: host.value })
    host.value = data.value.host
    const names = new Set(data.value.nodes.map((n) => n.node))
    picked.value = picked.value.filter((n) => names.has(n))
  } catch (e) {
    message.error(errorText(e))
  } finally {
    loading.value = false
  }
}
onMounted(load)

// Clearing goes back to this machine's own host name.
function changeHost(h: string | null) {
  host.value = h
  try {
    if (h) localStorage.setItem(HOST_KEY, h)
    else localStorage.removeItem(HOST_KEY)
  } catch {
    /* storage unavailable */
  }
  picked.value = []
  void load()
}

const hostOptions = computed(() => (data.value?.hosts ?? []).map((h) => ({ label: h, value: h })))
const observed = (node: string) => nodes.nodes[node]?.status === 'connected'
const candidates = computed(() => (data.value?.nodes ?? []).filter((n) => !observed(n.node)))
const allPicked = computed(() => candidates.value.length > 0 && picked.value.length === candidates.value.length)

function toggle(node: string, on: boolean) {
  picked.value = on ? [...picked.value, node] : picked.value.filter((n) => n !== node)
}
function toggleAll(on: boolean) {
  picked.value = on ? candidates.value.map((n) => n.node) : []
}

async function connect() {
  if (!picked.value.length) return
  connecting.value = true
  try {
    const params = await cookies.params(choice.value)
    const results = await Promise.allSettled(
      picked.value.map((node) => client.request('nodes.connect', { node, ...params })))
    await nodes.refresh()
    const failed = results.flatMap((r, i) => (r.status === 'rejected' ? [`${picked.value[i]}：${(r.reason as Error).message}`] : []))
    const ok = picked.value.filter((_, i) => results[i].status === 'fulfilled')
    if (ok.length) {
      nodes.select(ok[0])
      message.success(`已添加 ${ok.length} 个节点`)
    }
    failed.forEach((f) => message.error(f))
    if (!failed.length) {
      picked.value = []
      emit('connected')
    }
  } catch (e) {
    message.error(errorText(e))
  } finally {
    connecting.value = false
  }
}
</script>

<template>
  <div>
    <NFormItem label="主机名" :show-feedback="false" style="margin-bottom: 12px">
      <div class="row">
        <NSelect :value="host" :options="hostOptions" filterable tag clearable
                 placeholder="节点名 @ 后面的部分" @update:value="changeHost" />
        <NButton quaternary circle :loading="loading" title="重新扫描" @click="load">
          <template #icon><NIcon :component="RefreshOutline" /></template>
        </NButton>
      </div>
    </NFormItem>
    <NText depth="3" class="hint">epmd 不记录节点启动时用的主机名，请选和节点 -name / -sname 一致的那个。</NText>

    <NSpin :show="loading && !data">
      <NAlert v-if="data && !data.epmd" type="warning" style="margin: 12px 0">
        本机没有运行 epmd，还没有可连接的节点。
      </NAlert>
      <NEmpty v-else-if="data && !data.nodes.length" description="本机 epmd 上没有其他节点" style="padding: 24px 0" />
      <div v-else-if="data" class="list">
        <div class="item head">
          <NCheckbox :checked="allPicked" :indeterminate="picked.length > 0 && !allPicked"
                     :disabled="!candidates.length" @update:checked="toggleAll">
            全选（{{ data.nodes.length }} 个节点）
          </NCheckbox>
        </div>
        <div v-for="n in data.nodes" :key="n.node" class="item">
          <NCheckbox :checked="picked.includes(n.node)" :disabled="observed(n.node)"
                     @update:checked="(v: boolean) => toggle(n.node, v)">
            <span class="mono">{{ n.node }}</span>
          </NCheckbox>
          <NTag v-if="observed(n.node)" size="small" type="success" :bordered="false">已连接</NTag>
          <NText v-else depth="3" class="mono port">:{{ n.port }}</NText>
        </div>
      </div>
    </NSpin>

    <NFormItem label="Cookie" :show-feedback="false" style="margin: 12px 0 16px">
      <CookiePicker v-model="choice" />
    </NFormItem>
    <NButton type="primary" block :loading="connecting" :disabled="!picked.length" @click="connect">
      {{ picked.length ? `连接所选（${picked.length}）` : '选择要连接的节点' }}
    </NButton>
  </div>
</template>

<style scoped>
.row {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
}
.hint {
  display: block;
  font-size: 12px;
  margin-bottom: 8px;
}
.list {
  max-height: 260px;
  overflow-y: auto;
  border: 1px solid var(--n-border-color, rgba(128, 128, 128, 0.25));
  border-radius: 6px;
  margin-top: 8px;
}
.item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 6px 12px;
}
.item .mono {
  overflow-wrap: anywhere;
}
.item + .item {
  border-top: 1px solid rgba(128, 128, 128, 0.15);
}
.port {
  font-size: 12px;
  flex: none;
}
</style>
