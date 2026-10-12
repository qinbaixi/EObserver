<script setup lang="ts">
import { ref, watch } from 'vue'
import {
  NModal, NCard, NInput, NButton, NIcon, NEmpty, NPopconfirm, NText, useMessage,
} from 'naive-ui'
import { TrashOutline } from '@vicons/ionicons5'
import { useCookies } from '../stores/cookies'
import { errorText } from '../api/errors'

// Lists the cookies stored on the EObserver side: rename their labels or
// delete them. The cookie values themselves are never sent to the page.
const show = defineModel<boolean>('show', { required: true })
const cookies = useCookies()
const message = useMessage()
const labels = ref<Record<string, string>>({})

watch(show, async (open) => {
  if (!open) return
  await cookies.refresh().catch(() => {})
  labels.value = Object.fromEntries(cookies.saved.map((c) => [c.id, c.label]))
})

async function saveLabel(id: string) {
  const saved = cookies.saved.find((c) => c.id === id)
  const label = (labels.value[id] ?? '').trim()
  if (!saved || saved.label === label) return
  try {
    await cookies.rename(id, label)
    message.success('备注已保存')
  } catch (e) {
    message.error(errorText(e))
  }
}

async function remove(id: string) {
  try {
    await cookies.remove(id)
  } catch (e) {
    message.error(errorText(e))
  }
}

async function removeAll() {
  try {
    for (const c of [...cookies.saved]) await cookies.remove(c.id)
  } catch (e) {
    message.error(errorText(e))
  }
}

const lastUsed = (s: number) => (s ? new Date(s * 1000).toLocaleString() : '-')
</script>

<template>
  <NModal v-model:show="show">
    <NCard title="已保存的 cookie" style="width: 560px; max-width: calc(100vw - 32px)" closable
           @close="show = false">
      <NEmpty v-if="!cookies.saved.length" description="还没有保存过 cookie" style="padding: 24px 0" />
      <div v-else class="list">
        <div v-for="c in cookies.saved" :key="c.id" class="row">
          <span class="mono hint">{{ c.hint }}</span>
          <NInput v-model:value="labels[c.id]" size="small" placeholder="备注"
                  @blur="saveLabel(c.id)" @keyup.enter="saveLabel(c.id)" />
          <NText depth="3" class="used">{{ lastUsed(c.last_used) }}</NText>
          <NPopconfirm @positive-click="remove(c.id)">
            <template #trigger>
              <NButton quaternary circle size="small" title="删除">
                <template #icon><NIcon :component="TrashOutline" /></template>
              </NButton>
            </template>
            删除这个 cookie？已经连上的节点不受影响。
          </NPopconfirm>
        </div>
      </div>
      <template #footer>
        <div class="footer">
          <NText depth="3" class="note">只显示 cookie 的首尾字符，完整内容只保存在本机的配置目录中。</NText>
          <NPopconfirm v-if="cookies.saved.length" @positive-click="removeAll">
            <template #trigger><NButton size="small" type="error" secondary>全部删除</NButton></template>
            删除全部 {{ cookies.saved.length }} 个已保存的 cookie？
          </NPopconfirm>
        </div>
      </template>
    </NCard>
  </NModal>
</template>

<style scoped>
.list { display: flex; flex-direction: column; gap: 8px; max-height: 50vh; overflow-y: auto; }
.row { display: grid; grid-template-columns: 90px 1fr auto auto; align-items: center; gap: 10px; }
.hint { font-size: 13px; }
.used { font-size: 12px; white-space: nowrap; }
.footer { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.note { font-size: 12px; }
</style>
