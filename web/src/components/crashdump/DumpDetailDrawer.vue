<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { NDrawer, NDrawerContent, NSpin, NEmpty, NAlert, NTag, NSpace, NCollapse, NCollapseItem } from 'naive-ui'
import { dumpRequest, isTerm, type DumpDetail, type DumpTarget, type DumpTerm } from '../../api/dump'
import { errorText } from '../../api/errors'
import DumpTermBlock from './DumpTermBlock.vue'
import { colLabel, formatValue, keyType, refLink, useNav } from './cells'

// A port, ETS table, node, module, ... from the dump (dump.detail).
const props = defineProps<{ id: string; target: DumpTarget | null }>()
const emit = defineEmits<{ 'update:target': [DumpTarget | null] }>()
const { t, te } = useI18n()
const nav = useNav()

const detail = ref<DumpDetail | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)

const show = computed({
  get: () => props.target !== null,
  set: (v) => { if (!v) emit('update:target', null) },
})

watch(() => props.target, async (tg) => {
  if (!tg) return
  loading.value = true
  error.value = null
  detail.value = null
  try {
    const d = await dumpRequest<DumpDetail>('dump.detail', { id: props.id, kind: tg.kind, key: tg.key })
    if (props.target !== tg) return
    detail.value = d
  } catch (e) {
    error.value = errorText(e)
  } finally {
    loading.value = false
  }
}, { immediate: true })

const kindLabel = computed(() => {
  const k = props.target?.kind ?? ''
  return te(`crashdump.kind.${k}`) ? t(`crashdump.kind.${k}`) : k
})

const terms = computed<{ key: string; value: DumpTerm }[]>(() => {
  const ts = detail.value?.terms
  if (!ts) return []
  return Array.isArray(ts) ? ts : Object.entries(ts).map(([key, value]) => ({ key, value }))
})

const fields = computed(() => (detail.value?.fields ?? []).filter((f) => f.value !== null && f.value !== undefined))
const pairs = computed(() => (['links', 'monitors', 'monitored_by'] as const)
  .map((k) => ({ key: k, items: detail.value?.[k] ?? [] }))
  .filter((g) => g.items.length))

const REF_RE = /<\d+\.\d+\.\d+>|#Port<\d+\.\d+>/g
const refs = (v: unknown) => (typeof v === 'string' ? v.match(REF_RE) ?? [] : [])
// A pid, a port, or a comma-separated list of them: shown as links.
const onlyRefs = (v: unknown) => typeof v === 'string' && refs(v).length > 0 && v.replace(REF_RE, '').replace(/[,\s]/g, '') === ''
const val = (k: string, v: unknown) => (isTerm(v) ? v.text : formatValue(keyType(k), v, nav.wordSize()))
</script>

<template>
  <NDrawer v-model:show="show" :width="640" placement="right">
    <NDrawerContent :native-scrollbar="false" closable>
      <template #header>
        <NSpace align="center" :size="8">
          <NTag size="small" :bordered="false">{{ kindLabel }}</NTag>
          <span class="mono">{{ detail?.title ?? target?.key }}</span>
        </NSpace>
      </template>
      <NSpin v-if="loading" style="width: 100%; padding: 60px 0" />
      <NEmpty v-else-if="error === 'not_found'" :description="t('crashdump.detail.not_found')" style="padding: 60px 0" />
      <NAlert v-else-if="error" type="error">{{ error }}</NAlert>
      <template v-else-if="detail">
        <table class="kv">
          <tr v-for="f in fields" :key="f.key">
            <td class="k">{{ colLabel(f.key) }}</td>
            <td>
              <span v-if="onlyRefs(f.value)" class="refs">
                <component :is="() => refLink(r, nav)" v-for="r in refs(f.value)" :key="r" />
              </span>
              <span v-else class="mono v">{{ val(f.key, f.value) }}</span>
            </td>
          </tr>
        </table>
        <div v-for="g in pairs" :key="g.key" class="term">
          <div class="term-title">{{ t(`crashdump.proc.${g.key}`) }} <span class="count">{{ g.items.length }}</span></div>
          <table class="kv">
            <tr><th>{{ t('crashdump.detail.local') }}</th><th>{{ t('crashdump.detail.remote') }}</th></tr>
            <tr v-for="(p, i) in g.items" :key="i">
              <td><component :is="() => refLink(p.local, nav)" /></td>
              <td class="mono">{{ p.remote }}</td>
            </tr>
          </table>
        </div>
        <div v-if="detail.stack?.length" class="term">
          <div class="term-title">{{ t('crashdump.proc.tabs.stack') }}</div>
          <pre class="mono stack">{{ detail.stack.join('\n') }}</pre>
        </div>
        <NCollapse v-if="detail.instances?.length" class="term" :default-expanded-names="[detail.instances[0].name]">
          <NCollapseItem v-for="inst in detail.instances" :key="inst.name" :name="inst.name" :title="inst.name">
            <table class="kv">
              <tr v-for="f in inst.fields" :key="f.key">
                <td class="k mono">{{ f.key }}</td>
                <td class="mono v">{{ f.value }}</td>
              </tr>
            </table>
          </NCollapseItem>
        </NCollapse>
        <div v-for="x in terms" :key="x.key" class="term">
          <div class="term-title">{{ colLabel(x.key) }}</div>
          <DumpTermBlock :id="id" :term="x.value" />
        </div>
      </template>
    </NDrawerContent>
  </NDrawer>
</template>

<style scoped>
.kv {
  width: 100%;
  border-collapse: collapse;
  font-size: 13px;
}
.kv td {
  padding: 6px 8px;
  vertical-align: top;
  border-bottom: 1px solid rgba(128, 128, 128, 0.15);
}
.kv .k {
  width: 34%;
  opacity: 0.75;
}
.v {
  word-break: break-all;
}
.refs {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 8px;
}
.term {
  margin-top: 16px;
}
.count {
  opacity: 0.55;
  font-weight: normal;
}
.kv th {
  text-align: left;
  font-weight: normal;
  opacity: 0.55;
  padding: 4px 8px;
  font-size: 12px;
}
.stack {
  margin: 0;
  font-size: 12px;
  line-height: 1.5;
  white-space: pre-wrap;
  word-break: break-all;
  padding: 8px 10px;
  border-radius: 6px;
  background: rgba(128, 128, 128, 0.08);
}
.term-title {
  font-weight: 600;
  margin-bottom: 6px;
}
</style>
