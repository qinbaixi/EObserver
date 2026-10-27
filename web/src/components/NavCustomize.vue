<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { NModal, NCard, NButton, NIcon, NCheckbox, NSpace } from 'naive-ui'
import { ArrowUpOutline, ArrowDownOutline } from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'
import { pages, pageTitle } from '../router'
import { useNav, DEFAULT_PINNED } from '../stores/nav'

// Choose and order the pages the sidebar shows; the rest go under "More".
const show = defineModel<boolean>('show', { required: true })
const { t } = useI18n()
const nav = useNav()

const draft = ref<string[]>([])
watch(show, (s) => { if (s) draft.value = [...nav.pinned] }, { immediate: true })

const byName = Object.fromEntries(pages.map((p) => [p.name, p]))
// Chosen pages first, in their order, then the others in menu order.
const rows = computed(() => [
  ...draft.value,
  ...pages.map((p) => p.name).filter((n) => !draft.value.includes(n)),
])

function toggle(name: string, on: boolean) {
  draft.value = on ? [...draft.value, name] : draft.value.filter((n) => n !== name)
}
function move(name: string, by: number) {
  const i = draft.value.indexOf(name)
  const j = i + by
  if (i < 0 || j < 0 || j >= draft.value.length) return
  const next = [...draft.value]
  ;[next[i], next[j]] = [next[j], next[i]]
  draft.value = next
}
function save() {
  nav.setPinned(draft.value)
  show.value = false
}
</script>

<template>
  <NModal v-model:show="show">
    <NCard :title="t('shell.nav_custom.title')" :bordered="false" size="small" class="nav-custom" closable
           @close="show = false">
      <p class="hint">{{ t('shell.nav_custom.hint', { n: draft.length }) }}</p>
      <div class="list">
        <div v-for="n in rows" :key="n" class="row" :class="{ on: draft.includes(n) }">
          <NCheckbox :checked="draft.includes(n)" @update:checked="(v: boolean) => toggle(n, v)">
            <span class="label">
              <NIcon :component="byName[n].meta.icon" />
              {{ pageTitle(byName[n].meta) }}
            </span>
          </NCheckbox>
          <span v-if="draft.includes(n)" class="order">
            <NButton quaternary circle size="tiny" :disabled="draft.indexOf(n) === 0" @click="move(n, -1)">
              <template #icon><NIcon :component="ArrowUpOutline" /></template>
            </NButton>
            <NButton quaternary circle size="tiny" :disabled="draft.indexOf(n) === draft.length - 1" @click="move(n, 1)">
              <template #icon><NIcon :component="ArrowDownOutline" /></template>
            </NButton>
          </span>
          <span v-else class="more-tag">{{ t('shell.nav_custom.in_more') }}</span>
        </div>
      </div>
      <template #footer>
        <NSpace justify="space-between">
          <NButton size="small" quaternary @click="draft = [...DEFAULT_PINNED]">{{ t('shell.nav_custom.reset') }}</NButton>
          <NSpace>
            <NButton size="small" @click="show = false">{{ t('shell.nav_custom.cancel') }}</NButton>
            <NButton size="small" type="primary" @click="save">{{ t('shell.nav_custom.save') }}</NButton>
          </NSpace>
        </NSpace>
      </template>
    </NCard>
  </NModal>
</template>

<style scoped>
.nav-custom {
  width: 420px;
  max-width: calc(100vw - 32px);
}
.hint {
  margin: 0 0 10px;
  font-size: 13px;
  opacity: 0.7;
}
.list {
  max-height: 60vh;
  overflow-y: auto;
}
.row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  height: 36px;
  padding: 0 8px;
  border-radius: 6px;
}
.row.on {
  background: rgba(128, 128, 128, 0.08);
}
.label {
  display: inline-flex;
  align-items: center;
  gap: 8px;
}
.more-tag {
  font-size: 12px;
  opacity: 0.45;
}
</style>
