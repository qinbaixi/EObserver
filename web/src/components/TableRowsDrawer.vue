<script setup lang="ts">
import { computed, h, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import {
  NDrawer, NDrawerContent, NDataTable, NInput, NIcon, NButton, NAlert, NPagination,
  NSpace, NText, type DataTableColumns,
} from 'naive-ui'
import { SearchOutline, RefreshOutline, AddOutline } from '@vicons/ionicons5'
import { client } from '../api/ws'
import type { TableRows } from '../api/types'
import { errorText } from '../api/errors'
import { formatNumber } from '../api/format'
import { useSettings } from '../stores/settings'
import TableObjectModal from './TableObjectModal.vue'

// Paged viewer for the objects of one ETS or Mnesia table. Paging and
// searching run on the target node; only the current page is sent.
const props = defineProps<{ node: string; kind: 'ets' | 'mnesia'; table: string | null; title?: string }>()
const emit = defineEmits<{ 'update:table': [string | null] }>()

const { t } = useI18n()
const PAGE = 50
const page = ref(1)
const search = ref('')
const applied = ref('')
const data = ref<TableRows | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)
const settings = useSettings()
// Key of the object shown in TableObjectModal; '' adds a new one.
const openKey = ref<string | null>(null)

type Row = { i: number; cells: string[] }
const rows = computed<Row[]>(() => (data.value?.rows ?? []).map((cells, i) => ({ i, cells })))
const rowProps = (r: Row) => ({
  style: data.value?.keys?.[r.i] ? 'cursor: pointer' : '',
  onClick: () => { const k = data.value?.keys?.[r.i]; if (k) openKey.value = k },
})
// A skeleton for a new Mnesia record: {record_name, attr1, attr2, ...}.
const template = computed(() => {
  const d = data.value
  if (props.kind !== 'mnesia' || !d?.attributes || !d.rows.length) return ''
  return `{${d.rows[0][0]}, ${d.attributes.map((a) => a.charAt(0).toUpperCase() + a.slice(1)).join(', ')}}`
})

// Sorts the current page: numbers numerically, everything else as text.
function compare(a = '', b = '') {
  const x = Number(a)
  const y = Number(b)
  if (a !== '' && b !== '' && !Number.isNaN(x) && !Number.isNaN(y)) return x - y
  return a.localeCompare(b)
}

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
    error.value = errorText(e)
  } finally {
    loading.value = false
  }
}


watch(() => props.table, () => {
  openKey.value = null
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

const columns = computed<DataTableColumns<Row>>(() => {
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
      sorter: (a: Row, b: Row) => compare(a.cells[i], b.cells[i]),
      render: (r: Row) => h('span', { class: ['mono', isKey ? 'key-cell' : ''] }, r.cells[i] ?? ''),
    }
  })
})

const pageCount = computed(() => Math.max(1, Math.ceil((data.value?.total ?? 0) / PAGE)))
const summary = computed(() => {
  const d = data.value
  if (!d) return ''
  if (!applied.value) return t('procs.rows.total', { n: formatNumber(d.total) }, d.total)
  return d.complete
    ? t('procs.rows.matched', { n: formatNumber(d.total) }, d.total)
    : t('procs.rows.matched_partial', { n: formatNumber(d.total), scanned: formatNumber(d.scanned) })
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
          <NInput v-model:value="search" clearable :placeholder="t('procs.rows.search')" style="width: 320px">
            <template #prefix><NIcon :component="SearchOutline" /></template>
          </NInput>
          <NSpace align="center" :size="12">
            <NText depth="3">{{ summary }}</NText>
            <NButton v-if="!settings.readOnly && data" size="small" secondary @click="openKey = ''">
              <template #icon><NIcon :component="AddOutline" /></template>
              {{ t('procs.rows.add') }}
            </NButton>
          </NSpace>
        </NSpace>
        <NAlert v-if="error" type="warning">{{ error }}</NAlert>
        <NDataTable v-else :columns="columns" :data="rows" :loading="loading" size="small"
                    :row-key="(r: Row) => r.i" :row-props="rowProps"
                    :scroll-x="Math.max(800, columns.length * 170)" :max-height="'calc(100vh - 230px)'"
                    :single-line="false" />
        <NSpace justify="space-between" align="center">
          <NText depth="3" style="font-size: 12px">{{ t(settings.readOnly ? 'procs.rows.hint' : 'procs.rows.hint_edit') }}</NText>
          <NPagination v-model:page="page" :page-count="pageCount" :page-slot="7" />
        </NSpace>
      </NSpace>
    </NDrawerContent>
  </NDrawer>
  <TableObjectModal v-if="table" v-model:obj-key="openKey" :node="node" :kind="kind" :table="table"
                    :template="template" @changed="load" />
</template>

<style scoped>
:deep(.key-col) { font-weight: 600; }
:deep(.key-cell) { font-weight: 600; }
</style>
