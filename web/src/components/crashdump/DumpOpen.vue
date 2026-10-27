<script setup lang="ts">
import { computed, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { NButton, NIcon, NInput, NCard, NEmpty, NTooltip } from 'naive-ui'
import { BugOutline, FolderOpenOutline, TimeOutline, ArrowForwardOutline } from '@vicons/ionicons5'
import { basename, toMs } from '../../api/dump'
import { formatBytes, formatDateTime } from '../../api/format'
import { useDumps } from '../../stores/dump'

// Shown when no dump is selected: open button, a path field and the
// recently opened files. Dropping a file on the page is handled by the page.
defineProps<{ opening: boolean; desktop: boolean }>()
const emit = defineEmits<{ open: [path: string]; pick: [] }>()
const { t } = useI18n()
const dumps = useDumps()
const path = ref('')

const recent = computed(() => dumps.recent.slice(0, 8))
const dirOf = (p: string) => p.slice(0, Math.max(0, p.length - basename(p).length)).replace(/[\\/]$/, '')

function submit() {
  const p = path.value.trim()
  if (p) emit('open', p)
}
</script>

<template>
  <div class="open">
    <NCard class="hero" size="large">
      <div class="hero-icon"><NIcon :component="BugOutline" :size="40" /></div>
      <h3>{{ t('crashdump.open_page.title') }}</h3>
      <p class="intro">{{ t('crashdump.open_page.intro') }}</p>
      <NButton type="primary" size="large" :loading="opening" class="big" @click="emit('pick')">
        <template #icon><NIcon :component="FolderOpenOutline" /></template>
        {{ t('crashdump.open_page.button') }}
      </NButton>
      <p class="drop">{{ t(desktop ? 'crashdump.open_page.drop' : 'crashdump.open_page.browser_note') }}</p>
      <div class="path-row">
        <NInput v-model:value="path" class="mono" :placeholder="t('crashdump.open_page.path')" clearable
                @keydown.enter="submit" />
        <NButton :disabled="!path.trim()" :loading="opening" @click="submit">
          <template #icon><NIcon :component="ArrowForwardOutline" /></template>
          {{ t('crashdump.open') }}
        </NButton>
      </div>
    </NCard>

    <NCard size="small" :title="t('crashdump.open_page.recent')" class="recent">
      <div v-if="recent.length" class="recent-list">
        <button v-for="r in recent" :key="r.path" type="button" class="recent-row" @click="emit('open', r.path)">
          <NIcon :component="BugOutline" class="recent-icon" />
          <span class="recent-main">
            <span class="recent-name mono">{{ basename(r.path) }}</span>
            <NTooltip>
              <template #trigger><span class="recent-dir mono">{{ dirOf(r.path) }}</span></template>
              {{ r.path }}
            </NTooltip>
          </span>
          <span class="recent-size mono">{{ formatBytes(r.size) }}</span>
          <span class="recent-time"><NIcon :component="TimeOutline" /> {{ formatDateTime(toMs(r.opened || r.mtime)) }}</span>
        </button>
      </div>
      <NEmpty v-else :description="t('crashdump.open_page.no_recent')" size="small" style="padding: 16px 0" />
    </NCard>
  </div>
</template>

<style scoped>
.open {
  max-width: 760px;
  margin: 16px auto 0;
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.hero {
  text-align: center;
}
.hero-icon {
  width: 72px;
  height: 72px;
  margin: 4px auto 12px;
  border-radius: 18px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #d03050;
  background: rgba(208, 48, 80, 0.1);
}
h3 {
  margin: 0;
  font-size: 20px;
}
.intro {
  margin: 8px auto 20px;
  max-width: 520px;
  opacity: 0.65;
  line-height: 1.6;
}
.big {
  min-width: 200px;
  height: 44px;
  font-size: 16px;
}
.drop {
  font-size: 13px;
  opacity: 0.5;
  margin: 12px 0 20px;
}
.path-row {
  display: flex;
  gap: 8px;
  max-width: 560px;
  margin: 0 auto;
}
.recent-list {
  display: flex;
  flex-direction: column;
}
.recent-row {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 8px 10px;
  border: none;
  border-radius: 8px;
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
}
.recent-row:hover {
  background: rgba(128, 128, 128, 0.1);
}
.recent-icon {
  flex: none;
  color: #d03050;
}
.recent-main {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}
.recent-name {
  font-weight: 600;
  font-size: 13px;
}
.recent-dir {
  font-size: 12px;
  opacity: 0.5;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.recent-size {
  flex: none;
  font-size: 12px;
  opacity: 0.7;
  font-variant-numeric: tabular-nums;
}
.recent-time {
  flex: none;
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: 12px;
  opacity: 0.5;
}
@media (max-width: 640px) {
  .recent-time { display: none; }
}
</style>
