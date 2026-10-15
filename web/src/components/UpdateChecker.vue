<script setup lang="ts">
import { computed } from 'vue'
import { NButton, NProgress, NTooltip, NIcon, NSpin } from 'naive-ui'
import { ArrowUpCircleOutline } from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'
import { useUpdate } from '../stores/update'

// Bottom of the sidebar: the running version and the update status.
defineProps<{ collapsed: boolean }>()
const update = useUpdate()
const { t } = useI18n()

const statusText = computed(() => {
  const s = update.state
  if (s === 'available') return t('shell.update.available', { version: update.info?.version })
  if (s === 'downloading') return t('shell.update.downloading', { percent: Math.floor(update.progress) })
  return t(`shell.update.${s}`)
})
const notes = computed(() => toText(update.info?.notes ?? '').slice(0, 600))

// GitHub hands electron-updater the release notes as rendered HTML; show them
// as plain text with one line per heading, paragraph or list item.
function toText(notes: string) {
  let s = notes
  if (/<[a-z][^>]*>/i.test(s)) {
    s = s.replace(/<br\s*\/?>/gi, '\n').replace(/<\/(p|li|h[1-6]|ul|ol|div)>/gi, '\n')
      .replace(/<li[^>]*>/gi, '• ')
    s = new DOMParser().parseFromString(s, 'text/html').body.textContent ?? ''
  }
  return s.replace(/^#+\s*/gm, '').replace(/\*\*/g, '')
    .split('\n').map((l) => l.trim()).join('\n')
    .replace(/\n{2,}/g, '\n').trim()
}
</script>

<template>
  <div class="update" :class="{ collapsed }">
    <template v-if="collapsed">
      <NTooltip v-if="update.state === 'available' || update.state === 'ready'" placement="right">
        <template #trigger>
          <NButton quaternary circle type="primary" @click="update.state === 'ready' ? update.install() : update.canInstall ? update.download() : update.openRelease()">
            <template #icon><NIcon :component="ArrowUpCircleOutline" /></template>
          </NButton>
        </template>
        {{ statusText }}
      </NTooltip>
    </template>
    <template v-else>
      <div class="line">
        <span class="version mono">v{{ update.current }}</span>
        <NSpin v-if="update.state === 'checking'" :size="12" />
        <NTooltip v-else-if="update.state === 'error'">
          <template #trigger><a class="action muted" @click="update.check()">{{ statusText }}</a></template>
          {{ update.error }}
        </NTooltip>
        <a v-else-if="update.state === 'idle' || update.state === 'latest'" class="action muted"
           :title="t('shell.update.check_tip')" @click="update.check()">{{ statusText }}</a>
      </div>
      <div v-if="update.state === 'available'" class="box">
        <NTooltip :disabled="!notes" placement="right" :style="{ maxWidth: '360px', whiteSpace: 'pre-wrap' }">
          <template #trigger>
            <div class="headline"><NIcon :component="ArrowUpCircleOutline" /> {{ statusText }}</div>
          </template>
          {{ notes }}
        </NTooltip>
        <NButton v-if="update.canInstall" size="tiny" type="primary" block @click="update.download()">{{ t('shell.update.download') }}</NButton>
        <NButton v-else size="tiny" type="primary" secondary block @click="update.openRelease()">{{ t('shell.update.open_release') }}</NButton>
      </div>
      <div v-else-if="update.state === 'downloading'" class="box">
        <div class="headline">{{ statusText }}</div>
        <NProgress type="line" :percentage="Math.floor(update.progress)" :show-indicator="false" :height="4" />
      </div>
      <div v-else-if="update.state === 'ready'" class="box">
        <NTooltip :disabled="!notes" placement="right" :style="{ maxWidth: '360px', whiteSpace: 'pre-wrap' }">
          <template #trigger>
            <div class="headline">{{ t('shell.update.ready_headline', { version: update.info?.version }) }}</div>
          </template>
          {{ notes }}
        </NTooltip>
        <NButton size="tiny" type="primary" block @click="update.install()">{{ t('shell.update.install') }}</NButton>
      </div>
    </template>
  </div>
</template>

<style scoped>
.update {
  position: absolute;
  left: 16px;
  right: 16px;
  bottom: 14px;
  font-size: 12px;
}
.update.collapsed {
  left: 0;
  right: 0;
  display: flex;
  justify-content: center;
}
.line {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 0 8px;
}
.version {
  opacity: 0.45;
}
.action {
  cursor: pointer;
}
.muted {
  opacity: 0.55;
}
.action:hover {
  opacity: 0.9;
  text-decoration: underline;
}
.box {
  margin-top: 8px;
  padding: 8px 10px;
  border-radius: 8px;
  background: rgba(128, 128, 128, 0.1);
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.headline {
  display: flex;
  align-items: center;
  gap: 6px;
  font-weight: 600;
}
</style>
