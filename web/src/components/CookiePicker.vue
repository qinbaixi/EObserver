<script setup lang="ts">
import { computed, onMounted } from 'vue'
import {
  NSelect, NInput, NCheckbox, NButton, NIcon, NSpace, NPopconfirm, type SelectOption,
} from 'naive-ui'
import { TrashOutline } from '@vicons/ionicons5'
import { useCookies, type CookieChoice } from '../stores/cookies'

// Picks the cookie to connect with from the saved ones, the default
// ~/.erlang.cookie, or a new one (saved unless "remember" is unticked).
const choice = defineModel<CookieChoice>({ required: true })
const cookies = useCookies()

onMounted(async () => {
  await cookies.refresh().catch(() => {})
  // Start from the cookie used last time once the list is known.
  if (choice.value.kind === 'new' && !choice.value.cookie) choice.value = cookies.lastChoice()
})

const options = computed<SelectOption[]>(() => [
  ...cookies.saved.map((c) => ({
    value: `saved:${c.id}`,
    label: c.label ? `${c.label}（${c.hint}）` : c.hint,
  })),
  { value: 'new', label: '输入新的 cookie…' },
  { value: 'default', label: '默认（~/.erlang.cookie）' },
])

const selected = computed({
  get: () => (choice.value.kind === 'saved' ? `saved:${choice.value.id}` : choice.value.kind),
  set: (v: string) => {
    if (v.startsWith('saved:')) choice.value = { kind: 'saved', id: v.slice(6) }
    else if (v === 'default') choice.value = { kind: 'default' }
    else choice.value = { kind: 'new', cookie: '', label: '', remember: true }
    cookies.rememberChoice(choice.value)
  },
})

const fresh = computed(() => (choice.value.kind === 'new' ? choice.value : null))

async function removeSelected() {
  if (choice.value.kind !== 'saved') return
  await cookies.remove(choice.value.id)
  choice.value = cookies.lastChoice()
}
</script>

<template>
  <NSpace vertical :size="8" style="width: 100%">
    <div class="row">
      <NSelect v-model:value="selected" :options="options" />
      <NPopconfirm v-if="choice.kind === 'saved'" @positive-click="removeSelected">
        <template #trigger>
          <NButton quaternary circle title="从历史中删除这个 cookie">
            <template #icon><NIcon :component="TrashOutline" /></template>
          </NButton>
        </template>
        从历史中删除这个 cookie？
      </NPopconfirm>
    </div>
    <template v-if="fresh">
      <NInput v-model:value="fresh.cookie" type="password" show-password-on="click"
              placeholder="Cookie" class="mono" />
      <div class="row">
        <NInput v-model:value="fresh.label" placeholder="备注（可选），如：本地开发服"
                :disabled="!fresh.remember" />
        <NCheckbox v-model:checked="fresh.remember" style="white-space: nowrap">记住</NCheckbox>
      </div>
    </template>
  </NSpace>
</template>

<style scoped>
.row {
  display: flex;
  align-items: center;
  gap: 8px;
}
</style>
