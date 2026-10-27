<script setup lang="ts">
import { ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { NButton, useMessage } from 'naive-ui'
import { dumpRequest, type DumpTerm } from '../../api/dump'
import { errorText } from '../../api/errors'
import { formatBytes } from '../../api/format'

// A term from the dump, pretty printed by the backend and cut to a bounded
// size; "Expand" fetches the next, larger rendering.
const props = defineProps<{ id: string; term: DumpTerm; inline?: boolean }>()
const { t } = useI18n()
const message = useMessage()
const shown = ref<DumpTerm>(props.term)
const loading = ref(false)
watch(() => props.term, (v) => { shown.value = v })

async function expand() {
  if (!shown.value.more) return
  loading.value = true
  try {
    shown.value = await dumpRequest<DumpTerm>('dump.expand', { id: props.id, token: shown.value.more })
  } catch (e) {
    message.error(errorText(e))
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="dump-term" :class="{ inline }">
    <pre class="mono">{{ shown.text }}</pre>
    <div v-if="shown.more" class="more">
      <NButton size="tiny" secondary :loading="loading" @click="expand">{{ t('crashdump.term.expand') }}</NButton>
      <span v-if="shown.size" class="size">{{ t('crashdump.term.size', { size: formatBytes(shown.size) }) }}</span>
    </div>
  </div>
</template>

<style scoped>
.dump-term {
  border-radius: 6px;
  background: rgba(128, 128, 128, 0.08);
  padding: 8px 10px;
}
.dump-term.inline {
  background: transparent;
  padding: 0;
}
pre {
  margin: 0;
  font-size: 12px;
  line-height: 1.5;
  white-space: pre-wrap;
  word-break: break-all;
  max-height: 420px;
  overflow: auto;
}
.more {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: 6px;
}
.size {
  font-size: 12px;
  opacity: 0.55;
}
</style>
