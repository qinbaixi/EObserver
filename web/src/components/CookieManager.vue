<script setup lang="ts">
import { ref, watch } from 'vue'
import {
  NModal, NCard, NInput, NButton, NIcon, NEmpty, NPopconfirm, NText, useMessage,
} from 'naive-ui'
import { TrashOutline } from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'
import { useCookies } from '../stores/cookies'
import { errorText } from '../api/errors'
import { formatDateTime } from '../api/format'

// Lists the cookies stored on the EObserver side: rename their labels or
// delete them. The cookie values themselves are never sent to the page.
const show = defineModel<boolean>('show', { required: true })
const cookies = useCookies()
const message = useMessage()
const { t } = useI18n()
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
    message.success(t('shell.cookie.label_saved'))
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

const lastUsed = (s: number) => (s ? formatDateTime(s * 1000) : '-')
</script>

<template>
  <NModal v-model:show="show">
    <NCard :title="t('shell.cookie.manager_title')" style="width: 560px; max-width: calc(100vw - 32px)" closable
           @close="show = false">
      <NEmpty v-if="!cookies.saved.length" :description="t('shell.cookie.empty')" style="padding: 24px 0" />
      <div v-else class="list">
        <div v-for="c in cookies.saved" :key="c.id" class="row">
          <span class="mono hint">{{ c.hint }}</span>
          <NInput v-model:value="labels[c.id]" size="small" :placeholder="t('shell.cookie.label')"
                  @blur="saveLabel(c.id)" @keyup.enter="saveLabel(c.id)" />
          <NText depth="3" class="used">{{ lastUsed(c.last_used) }}</NText>
          <NPopconfirm @positive-click="remove(c.id)">
            <template #trigger>
              <NButton quaternary circle size="small" :title="t('shell.cookie.delete')">
                <template #icon><NIcon :component="TrashOutline" /></template>
              </NButton>
            </template>
            {{ t('shell.cookie.delete_confirm') }}
          </NPopconfirm>
        </div>
      </div>
      <template #footer>
        <div class="footer">
          <NText depth="3" class="note">{{ t('shell.cookie.note') }}</NText>
          <NPopconfirm v-if="cookies.saved.length" @positive-click="removeAll">
            <template #trigger><NButton size="small" type="error" secondary>{{ t('shell.cookie.delete_all') }}</NButton></template>
            {{ t('shell.cookie.delete_all_confirm', { n: cookies.saved.length }) }}
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
