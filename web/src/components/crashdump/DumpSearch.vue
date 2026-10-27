<script setup lang="ts">
import { h, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { NAutoComplete, NIcon, NTag, type AutoCompleteOption } from 'naive-ui'
import { SearchOutline } from '@vicons/ionicons5'
import { dumpRequest, type DumpTarget, type SearchHit } from '../../api/dump'

// Search the whole dump (pids, registered names, modules, tables, ...) and
// jump to the hit.
const props = defineProps<{ id: string }>()
const emit = defineEmits<{ go: [DumpTarget] }>()
const { t, te } = useI18n()

const q = ref('')
type Opt = AutoCompleteOption & { kind?: string }
const options = ref<Opt[]>([])
const loading = ref(false)
let timer: number | undefined
let seq = 0
const SEP = '\u0000'

watch(q, (v) => {
  clearTimeout(timer)
  const text = v.trim()
  if (!text) { options.value = []; return }
  timer = window.setTimeout(async () => {
    const my = ++seq
    loading.value = true
    try {
      const hits = await dumpRequest<SearchHit[]>('dump.search', { id: props.id, q: text })
      if (my !== seq) return
      options.value = hits.map((x) => ({ label: x.label || x.key, value: `${x.kind}${SEP}${x.key}`, kind: x.kind }))
      if (!hits.length) options.value = [{ label: t('crashdump.search.empty'), value: '', disabled: true }]
    } catch {
      if (my === seq) options.value = []
    } finally {
      if (my === seq) loading.value = false
    }
  }, 250)
})

const kindLabel = (k: string) => (te(`crashdump.kind.${k}`) ? t(`crashdump.kind.${k}`) : k)

const renderLabel = (o: Opt) => h('div', { class: 'hit' }, [
  o.kind ? h(NTag, { size: 'tiny', bordered: false, style: 'margin-right: 8px; flex: none' }, { default: () => kindLabel(String(o.kind)) }) : null,
  h('span', { class: o.kind ? 'mono hit-label' : 'hit-label' }, String(o.label)),
])

function select(v: string) {
  const i = v.indexOf(SEP)
  if (i < 0) return
  emit('go', { kind: v.slice(0, i), key: v.slice(i + 1) })
  q.value = ''
}
</script>

<template>
  <NAutoComplete v-model:value="q" :options="options" :loading="loading" :render-label="renderLabel" clearable
                 :get-show="() => q.trim().length > 0" :placeholder="t('crashdump.search.placeholder')"
                 class="dump-search" :input-props="{ autocomplete: 'off' }" @select="(v) => select(String(v))">
    <template #prefix><NIcon :component="SearchOutline" /></template>
  </NAutoComplete>
</template>

<style scoped>
.dump-search {
  width: 340px;
  max-width: 100%;
}
:global(.hit) {
  display: flex;
  align-items: center;
  min-width: 0;
}
:global(.hit-label) {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>
