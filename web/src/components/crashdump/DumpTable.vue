<script setup lang="ts">
import { computed, h, onBeforeUnmount, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { NDataTable, NInput, NIcon, NAlert, type DataTableColumns, type DataTableSortState } from 'naive-ui'
import { SearchOutline } from '@vicons/ionicons5'
import { dumpRequest, rowObjects, type DumpColumn, type DumpQueryResult, type DumpRow } from '../../api/dump'
import { errorText } from '../../api/errors'
import { formatNumber } from '../../api/format'
import { useResizableTable } from '../../api/table'
import { colLabel, isNumeric, renderCell, useNav } from './cells'

// One dump.query kind as a server-side paged, sorted and filtered table.
// Columns come from the backend; labels from crashdump.col.<key>.
const props = withDefaults(defineProps<{
  id: string
  kind: string
  // Reloads when this changes (e.g. the scan finished).
  version?: string
  filter?: string
  // A row click opens this detail; the key is the row's value of `field`
  // (or of its first column).
  detail?: { kind: string; field?: string } | null
  pageSize?: number
  compact?: boolean
  // Initial sort column (descending).
  sort?: string | null
}>(), { version: '', filter: '', detail: null, pageSize: 50, compact: false, sort: null })

const { t } = useI18n()
const nav = useNav()
const filterInput = ref(props.filter)
const filter = ref(props.filter.trim())
const sort = ref<string | null>(props.sort)
const order = ref<'asc' | 'desc'>('desc')
const page = ref(1)
const pageSize = ref(props.pageSize)
const data = ref<DumpQueryResult | null>(null)
const rows = ref<DumpRow[]>([])
const loading = ref(false)
const error = ref<string | null>(null)

watch(() => props.filter, (f) => { filterInput.value = f; filter.value = f.trim(); page.value = 1 })

let debounce: number | undefined
watch(filterInput, (v) => {
  clearTimeout(debounce)
  debounce = window.setTimeout(() => {
    if (filter.value !== v.trim()) { filter.value = v.trim(); page.value = 1 }
  }, 300)
})
onBeforeUnmount(() => clearTimeout(debounce))

let seq = 0
async function load() {
  const my = ++seq
  loading.value = true
  try {
    const res = await dumpRequest<DumpQueryResult>('dump.query', {
      id: props.id, kind: props.kind, offset: (page.value - 1) * pageSize.value, limit: pageSize.value,
      sort: sort.value, order: sort.value ? order.value : null, filter: filter.value,
    })
    if (my !== seq) return
    data.value = res
    rows.value = rowObjects(res)
    error.value = null
  } catch (e) {
    if (my === seq) error.value = errorText(e)
  } finally {
    if (my === seq) loading.value = false
  }
}

watch([() => props.id, () => props.kind, () => props.version, filter, sort, order, page, pageSize], load, { immediate: true })

const FIXED: Partial<Record<DumpColumn['type'], number>> = { pid: 140, port: 140, int: 120, bytes: 120, words: 120, ms: 120, bool: 90 }

// Fixed widths for numbers and references; text and term columns share
// the rest of a ~1100px table, so a table with few columns does not
// stretch a narrow number column.
function width(c: DumpColumn, all: DumpColumn[]): { width?: number; minWidth?: number } {
  const fixed = FIXED[c.type]
  if (fixed) return { width: fixed }
  const used = all.reduce((s, x) => s + (FIXED[x.type] ?? 0), 0)
  const flex = all.filter((x) => !FIXED[x.type]).length
  const base = c.type === 'term' ? 280 : 170
  const room = props.compact ? 0 : 1100
  return { minWidth: Math.max(base, Math.floor((room - used) / Math.max(1, flex))) }
}

const columns = computed<DataTableColumns<DumpRow>>(() => (data.value?.columns ?? []).map((c) => ({
  key: c.key,
  title: colLabel(c.key),
  ...width(c, data.value?.columns ?? []),
  align: isNumeric(c.type) ? 'right' as const : undefined,
  ellipsis: c.type === 'term' || c.type === 'text' ? { tooltip: false } : undefined,
  sorter: c.sortable ? true as const : undefined,
  sortOrder: c.sortable ? (sort.value === c.key ? (order.value === 'asc' ? 'ascend' as const : 'descend' as const) : false as const) : undefined,
  render: (r: DumpRow) => renderCell(c.type, r[c.key], nav),
})))

function onSort(s: DataTableSortState | null) {
  if (!s || !s.order) sort.value = null
  else {
    sort.value = String(s.columnKey)
    order.value = s.order === 'ascend' ? 'asc' : 'desc'
  }
  page.value = 1
}

const pagination = computed(() => ({
  page: page.value,
  pageSize: pageSize.value,
  itemCount: data.value?.total ?? 0,
  pageSizes: [25, 50, 100, 200],
  showSizePicker: !props.compact,
  prefix: ({ itemCount }: { itemCount?: number }) => t('crashdump.table.total', { n: formatNumber(itemCount ?? 0) }),
  onUpdatePage: (p: number) => { page.value = p },
  onUpdatePageSize: (s: number) => { pageSize.value = s; page.value = 1 },
}))

function detailKey(r: DumpRow): string | null {
  const d = props.detail
  if (!d) return null
  const first = data.value?.columns[0]?.key
  const v = (d.field ? r[d.field] : undefined) ?? (first ? r[first] : undefined)
  return v === null || v === undefined ? null : String(v)
}

const rowProps = (r: DumpRow) => {
  const key = detailKey(r)
  if (!key || !props.detail) return {}
  const kind = props.detail.kind
  return { style: 'cursor: pointer', onClick: () => nav.open({ kind, key }) }
}

const rowKey = (r: DumpRow) => {
  const i = rows.value.indexOf(r)
  const first = data.value?.columns[0]?.key
  return `${i}:${first ? String(r[first]) : ''}`
}

const table = useResizableTable(columns)
</script>

<template>
  <div class="dump-table">
    <div class="toolbar">
      <NInput v-model:value="filterInput" clearable size="small" :placeholder="t('crashdump.table.filter')" class="filter">
        <template #prefix><NIcon :component="SearchOutline" /></template>
      </NInput>
      <span v-if="detail" class="hint">{{ t('crashdump.table.click_hint') }}</span>
      <slot />
    </div>
    <NAlert v-if="error" type="error" style="margin-bottom: 12px">{{ error }}</NAlert>
    <NDataTable remote v-bind="table" :max-height="compact ? 420 : 'calc(100vh - 420px)'" :min-height="compact ? undefined : 240"
                :data="rows" :loading="loading" :pagination="pagination" :row-key="rowKey"
                :row-props="rowProps" size="small" @update:sorter="onSort" />
  </div>
</template>

<style scoped>
.toolbar {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
  margin-bottom: 10px;
}
.filter {
  width: 300px;
  max-width: 100%;
}
.hint {
  font-size: 12px;
  opacity: 0.5;
}
:deep(.dump-muted) {
  opacity: 0.35;
}
:deep(.dump-term-cell) {
  font-size: 12px;
}
</style>
