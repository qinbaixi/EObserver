import { computed, ref, type MaybeRefOrGetter, toValue } from 'vue'
import type { DataTableColumns } from 'naive-ui'

type Col = { key?: string | number; width?: number | string; minWidth?: number | string; type?: string }

// Props for an NDataTable whose columns can be dragged wider or narrower
// from the header edge (v-bind the result). The table's scroll width
// follows the columns, so widening one brings up the horizontal scrollbar;
// the body scrolls inside the window so that scrollbar stays at the bottom
// of the screen, and it is always shown rather than only on hover.
export function useResizableTable<T>(source: MaybeRefOrGetter<DataTableColumns<T>>, minScrollX = 0) {
  const widths = ref<Record<string, number>>({})

  const columns = computed(() => toValue(source).map((c) => {
    const col = c as Col
    if (col.type) return c
    // Resizing needs a starting width; columns that only had a minWidth
    // start from it.
    return { ...c, resizable: true, width: col.width ?? col.minWidth ?? 120, minWidth: 60 } as typeof c
  }))

  const scrollX = computed(() => Math.max(minScrollX, columns.value.reduce((sum, c) => {
    const col = c as Col
    const w = widths.value[String(col.key)] ?? Number(col.width)
    return sum + (Number.isFinite(w) ? w : 120)
  }, 0)))

  function onUnstableColumnResize(_resized: number, limited: number, column: { key: string | number }) {
    widths.value = { ...widths.value, [String(column.key)]: limited }
  }

  return computed(() => ({
    columns: columns.value,
    scrollX: scrollX.value,
    onUnstableColumnResize,
    maxHeight: 'calc(100vh - 330px)',
    scrollbarProps: { trigger: 'none' as const },
  }))
}
