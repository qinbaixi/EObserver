<script setup lang="ts">
// One table object in full, with edit / delete (hidden in read-only mode).
// key: the opaque key from ets.rows / mnesia.rows; '' adds a new object.
import { computed, ref, watch } from 'vue'
import {
  NModal, NCard, NInput, NButton, NSpace, NAlert, NSpin, NText, NPopconfirm, NTag, useMessage,
} from 'naive-ui'
import { client } from '../api/ws'
import { errorText } from '../api/errors'
import { useSettings } from '../stores/settings'

interface TableObject { text: string; ref: string; editable: boolean }

const props = defineProps<{
  node: string
  kind: 'ets' | 'mnesia'
  table: string
  objKey: string | null
  template?: string
}>()
const emit = defineEmits<{ 'update:objKey': [string | null]; changed: [] }>()

const settings = useSettings()
const message = useMessage()
const objects = ref<TableObject[]>([])
const drafts = ref<string[]>([])
const loading = ref(false)
const saving = ref(-1)
const error = ref<string | null>(null)

const adding = computed(() => props.objKey === '')
const show = computed({
  get: () => props.objKey !== null,
  set: (v) => { if (!v) emit('update:objKey', null) },
})
const canWrite = computed(() => !settings.readOnly)

async function load() {
  error.value = null
  objects.value = []
  if (props.objKey === null) return
  if (adding.value) {
    drafts.value = [props.template ?? '']
    return
  }
  loading.value = true
  try {
    objects.value = await client.request<TableObject[]>('table.object', {
      node: props.node, kind: props.kind, table: props.table, key: props.objKey,
    }, 60000)
    drafts.value = objects.value.map((o) => o.text)
  } catch (e) {
    error.value = errorText(e)
  } finally {
    loading.value = false
  }
}
watch(() => props.objKey, () => void load(), { immediate: true })

async function save(i: number) {
  saving.value = i
  try {
    await client.request('table.write', {
      node: props.node, kind: props.kind, table: props.table,
      object: drafts.value[i], ref: adding.value ? null : objects.value[i].ref,
    }, 60000)
    message.success(adding.value ? '已添加' : '已保存')
    emit('changed')
    emit('update:objKey', null)
  } catch (e) {
    message.error(`保存失败：${errorText(e)}`)
  } finally {
    saving.value = -1
  }
}

async function remove(i: number) {
  try {
    await client.request('table.delete', {
      node: props.node, kind: props.kind, table: props.table, ref: objects.value[i].ref,
    }, 60000)
    message.success('已删除')
    emit('changed')
    if (objects.value.length <= 1) emit('update:objKey', null)
    else await load()
  } catch (e) {
    message.error(`删除失败：${errorText(e)}`)
  }
}

function rows(text: string) {
  return Math.min(24, Math.max(4, text.split('\n').length + 1))
}
</script>

<template>
  <NModal v-model:show="show">
    <NCard :title="adding ? '添加记录' : '记录详情'" closable style="width: min(900px, 94vw)"
           @close="show = false">
      <template #header-extra>
        <NText depth="3" class="mono">{{ table }}</NText>
      </template>
      <NSpin v-if="loading" style="width: 100%; padding: 40px 0" />
      <NAlert v-else-if="error" type="warning">{{ error }}</NAlert>
      <NText v-else-if="!adding && !objects.length" depth="3">这条记录已不存在。</NText>
      <NSpace v-else vertical :size="16">
        <div v-for="(d, i) in drafts" :key="i">
          <NSpace v-if="objects.length > 1" align="center" style="margin-bottom: 6px">
            <NTag size="small" :bordered="false">第 {{ i + 1 }} / {{ objects.length }} 条（bag 表中同一个键的多条记录）</NTag>
          </NSpace>
          <NInput v-model:value="drafts[i]" type="textarea" class="mono-input"
                  :readonly="!canWrite || (!adding && !objects[i].editable)"
                  :autosize="{ minRows: rows(d), maxRows: 24 }"
                  :placeholder="adding ? 'Erlang 项，例如 {key, value}' : undefined" />
          <NText v-if="!adding && !objects[i].editable" depth="3" class="hint">
            这条记录包含 pid、引用、fun 或被截断的内容，无法以文本写回，只能查看{{ canWrite ? '和删除' : '' }}。
          </NText>
          <NSpace v-if="canWrite" justify="end" style="margin-top: 8px">
            <NPopconfirm v-if="!adding" @positive-click="remove(i)">
              <template #trigger><NButton size="small" type="error" secondary>删除</NButton></template>
              从目标节点的表中删除这条记录？
            </NPopconfirm>
            <NButton v-if="adding || objects[i].editable" size="small" type="primary"
                     :loading="saving === i" :disabled="!adding && d === objects[i].text"
                     @click="save(i)">
              {{ adding ? '添加' : '保存' }}
            </NButton>
          </NSpace>
        </div>
        <NText v-if="canWrite" depth="3" class="hint">
          修改会直接写入目标节点{{ kind === 'mnesia' ? '（在一个 Mnesia 事务中执行）' : '' }}。改了键等于移动这条记录：旧键下的记录会被删除。
        </NText>
      </NSpace>
    </NCard>
  </NModal>
</template>

<style scoped>
.mono-input :deep(textarea) {
  font-family: var(--mono, ui-monospace, SFMono-Regular, Menlo, monospace);
  font-size: 12.5px;
}
.hint {
  display: block;
  margin-top: 6px;
  font-size: 12px;
}
</style>
