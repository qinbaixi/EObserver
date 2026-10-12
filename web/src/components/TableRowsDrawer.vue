<script setup lang="ts">
import { computed, h, ref, watch } from 'vue'
import {
  NDrawer, NDrawerContent, NDataTable, NInput, NIcon, NButton, NAlert, NPagination,
  NSpace, NText, type DataTableColumns,
} from 'naive-ui'
import { SearchOutline, RefreshOutline } from '@vicons/ionicons5'
import { client } from '../api/ws'
import type { TableRows } from '../api/types'
import { formatNumber } from '../api/format'

// Paged viewer for the objects of one ETS or Mnesia table. Paging and
// searching run on the target node; only the current page is sent.
const props = defineProps<{ node: string; kind: 'ets' | 'mnesia'; table: string | null; title?: string }>()
const emit = defineEmits<{ 'update:table': [string | null] }>()

const PAGE = 50
const page = ref(1)
const search = ref('')
const applied = ref('')
const data = ref<TableRows | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)

const show = computed({
  get: () => props.table !== null,
  set: (v) => { if (!v) emit('update:table', null) },
})

async function load() {
  if (!props.table) return
  loading.value = true
  error.value = null
  try {
    data.value = await client.request<TableRows>(`${props.kind}.rows`, {
      node: props.node, table: props.table,
      offset: (page.value - 1) * PAGE, limit: PAGE, search: applied.value,
    }, 60000)
  } catch (e) {
    data.value = null
    error.value = errorText((e as Error).message)
  } finally {
    loading.value = false
  }
}

function errorText(msg: string) {
  if (msg.includes('private')) return '这是 private 表，只有所属进程能读取。'
  if (msg.includes('not_found')) return '表已不存在。'
  return msg
}

watch(() => props.table, () => {
  page.value = 1
  search.value = ''
  applied.value = ''
  data.value = null
  void load()
}, { immediate: true })
watch(page, () => void load())

let timer: ReturnType<typeof setTimeout> | undefined
watch(search, (q) => {
  clearTimeout(timer)
  timer = setTimeout(() => {
    applied.value = q.trim()
    if (page.value === 1) void load()
    else page.value = 1
  }, 350)
})

const columns = computed<DataTableColumns<string[]>>(() => {
  const d = data.value
  if (!d) return []
  const attrs = d.attributes
  const n = Math.max(d.columns, attrs ? attrs.length + 1 : 0)
  return Array.from({ length: n }, (_, i) => {
    const isKey = i + 1 === d.keypos
    const title = attrs ? (i === 0 ? 'record' : attrs[i - 1] ?? `#${i + 1}`) : `#${i + 1}`
    return {
      key: String(i),
      title: () => h('span', { class: isKey ? 'key-col' : '' }, isKey ? `${title} 🔑` : title),
      minWidth: i === 0 && attrs ? 100 : 160,
      ellipsis: { tooltip: { style: { maxWidth: '640px' }, contentStyle: { whiteSpace: 'pre-wrap', wordBreak: 'break-all' } } },
      render: (r: string[]) => h('span', { class: ['mono', isKey ? 'key-cell' : ''] }, r[i] ?? ''),
    }
  })
})

const pageCount = computed(() => Math.max(1, Math.ceil((data.value?.total ?? 0) / PAGE)))
const summary = computed(() => {
  const d = data.value
  if (!d) return ''
  if (!applied.value) return `${formatNumber(d.total)} 条记录`
  return d.complete
    ? `匹配 ${formatNumber(d.total)} 条`
    : `前 ${formatNumber(d.scanned)} 条中匹配 ${formatNumber(d.total)} 条（为保护目标节点，搜索已停止）`
})
</script>

<template>
  <NDrawer v-model:show="show" width="min(1200px, 92vw)" placement="right">
    <NDrawerContent closable :native-scrollbar="false">
      <template #header>
        <NSpace align="center" :size="8">
          <span class="mono">{{ title ?? table }}</span>
          <NText depth="3" style="font-size: 12px">{{ kind === 'ets' ? 'ETS' : 'Mnesia' }}</NText>
          <NButton quaternary circle size="small" :loading="loading" @click="load">
            <template #icon><NIcon :component="RefreshOutline" /></template>
          </NButton>
        </NSpace>
      </template>
      <NSpace vertical :size="12">
        <NSpace justify="space-between" align="center">
          <NInput v-model:value="search" clearable placeholder="在格式化后的记录中搜索" style="width: 320px">
            <template #prefix><NIcon :component="SearchOutline" /></template>
          </NInput>
          <NText depth="3">{{ summary }}</NText>
        </NSpace>
        <NAlert v-if="error" type="warning">{{ error }}</NAlert>
        <NDataTable v-else :columns="columns" :data="data?.rows ?? []" :loading="loading" size="small"
                    :scroll-x="Math.max(800, columns.length * 170)" :max-height="'calc(100vh - 230px)'"
                    :single-line="false" />
        <NSpace justify="end">
          <NPagination v-model:page="page" :page-count="pageCount" :page-slot="7" />
        </NSpace>
      </NSpace>
    </NDrawerContent>
  </NDrawer>
</template>

<style scoped>
:deep(.key-col) { font-weight: 600; }
:deep(.key-cell) { font-weight: 600; }
</style>
