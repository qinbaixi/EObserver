<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { NModal, NCard, NButton, NIcon, NInput, NSpin, NAlert, NCheckbox, NEmpty, NTag, NBreadcrumb, NBreadcrumbItem } from 'naive-ui'
import { FolderOutline, DocumentOutline, BugOutline, ArrowUpOutline, HomeOutline, LocateOutline } from '@vicons/ionicons5'
import { dumpRequest, toMs, type BrowseEntry, type BrowseResult, type BrowseRoot } from '../../api/dump'
import { errorText } from '../../api/errors'
import { formatBytes, formatDateTime } from '../../api/format'

// The browser UI cannot read local paths, so the backend lists directories
// on the EObserver machine (dump.browse) and the user picks a file here.
const props = defineProps<{ show: boolean }>()
const emit = defineEmits<{ 'update:show': [boolean]; open: [path: string] }>()
const { t, te } = useI18n()

const data = ref<BrowseResult | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)
const selected = ref<string | null>(null)
const onlyDumps = ref(false)
const pathInput = ref('')

async function browse(path?: string) {
  loading.value = true
  error.value = null
  try {
    data.value = await dumpRequest<BrowseResult>('dump.browse', path ? { path } : {})
    pathInput.value = data.value.path
    selected.value = null
  } catch (e) {
    const code = e instanceof Error ? e.message : String(e)
    error.value = te(`crashdump.errors.${code}`) ? t(`crashdump.errors.${code}`) : errorText(e)
  } finally {
    loading.value = false
  }
}

watch(() => props.show, (v) => { if (v) void browse(data.value?.path) }, { immediate: true })

const roots = computed<BrowseRoot[]>(() => (data.value?.roots ?? []).map((r) =>
  typeof r === 'string' ? { name: r, path: r, kind: r === '/' || /^[A-Za-z]:[\\/]?$/.test(r) ? 'root' : 'home' } : r))

const entries = computed(() => {
  const list = [...(data.value?.entries ?? [])]
    .filter((e) => !onlyDumps.value || e.dir || e.dump)
  return list.sort((a, b) => (a.dir === b.dir ? (a.dump === b.dump ? a.name.localeCompare(b.name) : a.dump ? -1 : 1) : a.dir ? -1 : 1))
})

// Breadcrumb: each ancestor of the current path.
const crumbs = computed(() => {
  const d = data.value
  if (!d) return []
  const sep = d.sep || '/'
  const p = d.path
  const absolute = p.startsWith(sep)
  const out: { name: string; path: string }[] = absolute ? [{ name: sep, path: sep }] : []
  let acc = ''
  p.split(sep).filter(Boolean).forEach((seg, i) => {
    // "C:" becomes "C:\" so the drive root is a directory.
    if (i === 0 && !absolute) acc = seg + sep
    else acc = acc.endsWith(sep) ? acc + seg : acc + sep + seg
    out.push({ name: seg, path: acc })
  })
  return out
})

function click(e: BrowseEntry) {
  if (e.dir) void browse(e.path)
  else selected.value = e.path
}
function dbl(e: BrowseEntry) {
  if (!e.dir) choose(e.path)
}
function choose(path: string | null) {
  if (!path) return
  emit('open', path)
  emit('update:show', false)
}
function goInput() {
  const p = pathInput.value.trim()
  if (!p) return
  const entry = data.value?.entries.find((e) => e.path === p)
  if (entry && !entry.dir) choose(p)
  else void browse(p)
}
</script>

<template>
  <NModal :show="show" @update:show="emit('update:show', $event)">
    <NCard class="browser" :title="t('crashdump.browse.title')" closable size="small"
           :segmented="{ content: true, footer: 'soft' }" @close="emit('update:show', false)">
      <div class="bar">
        <NButton v-for="r in roots" :key="r.path" size="small" tertiary @click="browse(r.path)">
          <template #icon><NIcon :component="r.kind === 'home' ? HomeOutline : r.kind === 'cwd' ? LocateOutline : FolderOutline" /></template>
          {{ r.kind === 'home' || r.kind === 'cwd' ? t(`crashdump.browse.${r.kind}`) : r.name }}
        </NButton>
        <NButton size="small" tertiary :disabled="!data?.parent" @click="browse(data?.parent ?? undefined)">
          <template #icon><NIcon :component="ArrowUpOutline" /></template>
          {{ t('crashdump.browse.up') }}
        </NButton>
        <NCheckbox v-model:checked="onlyDumps" size="small" class="only">{{ t('crashdump.browse.only_dumps') }}</NCheckbox>
      </div>
      <NBreadcrumb v-if="crumbs.length" class="crumbs" separator="›">
        <NBreadcrumbItem v-for="c in crumbs" :key="c.path" @click="browse(c.path)">
          <span class="mono">{{ c.name }}</span>
        </NBreadcrumbItem>
      </NBreadcrumb>
      <NInput v-model:value="pathInput" size="small" class="mono path" :placeholder="t('crashdump.browse.path')"
              @keydown.enter="goInput" />
      <NAlert v-if="error" type="error" style="margin: 8px 0">{{ error }}</NAlert>
      <div class="list">
        <NSpin :show="loading">
          <div class="head row">
            <span class="name">{{ t('crashdump.browse.name') }}</span>
            <span class="size">{{ t('crashdump.browse.size') }}</span>
            <span class="mtime">{{ t('crashdump.browse.mtime') }}</span>
          </div>
          <div v-for="e in entries" :key="e.path" class="row entry"
               :class="{ dir: e.dir, dump: e.dump, sel: selected === e.path }"
               @click="click(e)" @dblclick="dbl(e)">
            <span class="name">
              <NIcon :component="e.dir ? FolderOutline : e.dump ? BugOutline : DocumentOutline" :size="16" class="icon" />
              <span class="label">{{ e.name }}</span>
              <NTag v-if="e.dump" size="tiny" type="primary" :bordered="false">dump</NTag>
            </span>
            <span class="size mono">{{ e.dir || e.size === null ? '' : formatBytes(e.size) }}</span>
            <span class="mtime">{{ e.mtime ? formatDateTime(toMs(e.mtime)) : '' }}</span>
          </div>
          <div v-if="data?.truncated" class="trunc">{{ t('crashdump.browse.truncated') }}</div>
          <NEmpty v-if="data && !entries.length" :description="t('crashdump.browse.empty')" style="padding: 32px 0" />
        </NSpin>
      </div>
      <template #footer>
        <div class="foot">
          <span class="mono chosen">{{ selected ?? t('crashdump.browse.pick') }}</span>
          <NButton @click="emit('update:show', false)">{{ t('crashdump.cancel') }}</NButton>
          <NButton type="primary" :disabled="!selected" @click="choose(selected)">{{ t('crashdump.open') }}</NButton>
        </div>
      </template>
    </NCard>
  </NModal>
</template>

<style scoped>
.browser {
  width: 820px;
  max-width: calc(100vw - 32px);
}
.bar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
}
.only {
  margin-left: auto;
}
.crumbs {
  margin: 10px 0 6px;
}
.path {
  margin-bottom: 8px;
}
.list {
  height: min(52vh, 460px);
  overflow-y: auto;
  border: 1px solid rgba(128, 128, 128, 0.2);
  border-radius: 8px;
}
.row {
  display: grid;
  grid-template-columns: 1fr 100px 170px;
  gap: 12px;
  align-items: center;
  padding: 6px 12px;
  font-size: 13px;
}
.head {
  position: sticky;
  top: 0;
  z-index: 1;
  font-size: 12px;
  opacity: 0.6;
  background: inherit;
  border-bottom: 1px solid rgba(128, 128, 128, 0.2);
}
.entry {
  cursor: pointer;
  user-select: none;
}
.entry:hover {
  background: rgba(128, 128, 128, 0.1);
}
.entry.sel {
  background: rgba(32, 128, 240, 0.16);
}
.entry:not(.dir):not(.dump) {
  opacity: 0.6;
}
.entry.dump .label {
  font-weight: 600;
}
.name {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.label {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.icon {
  flex: none;
  opacity: 0.75;
}
.entry.dump .icon {
  color: #d03050;
  opacity: 1;
}
.size {
  text-align: right;
  font-variant-numeric: tabular-nums;
}
.mtime {
  opacity: 0.6;
  font-size: 12px;
}
.trunc {
  padding: 8px 12px;
  font-size: 12px;
  opacity: 0.55;
}
.foot {
  display: flex;
  align-items: center;
  gap: 8px;
}
.chosen {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 12px;
  opacity: 0.6;
}
@media (max-width: 640px) {
  .row { grid-template-columns: 1fr 80px; }
  .mtime { display: none; }
}
</style>
