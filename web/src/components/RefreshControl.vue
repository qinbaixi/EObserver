<script setup lang="ts">
// Refresh interval, pause / resume and manual refresh, shared by every
// page that shows periodically refreshed data.
import { computed } from 'vue'
import { NButton, NIcon, NSelect, NSpace, NTooltip } from 'naive-ui'
import { PauseOutline, PlayOutline, RefreshOutline } from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'

const paused = defineModel<boolean>('paused', { required: true })
const interval = defineModel<number>('interval', { required: true })
const emit = defineEmits<{ refresh: [] }>()
const { t } = useI18n()

const STEPS = [1000, 2000, 3000, 5000, 10000, 30000]
const options = computed(() =>
  [...new Set([...STEPS, interval.value])].sort((a, b) => a - b)
    .map((v) => ({ label: t('shell.refresh.every', { n: v / 1000 }), value: v })))
</script>

<template>
  <NSpace align="center" :size="8" :wrap="false">
    <NSelect v-model:value="interval" :options="options" :disabled="paused" style="width: 110px" />
    <NTooltip>
      <template #trigger>
        <NButton secondary @click="paused = !paused">
          <template #icon><NIcon :component="paused ? PlayOutline : PauseOutline" /></template>
          {{ paused ? t('shell.refresh.resume') : t('shell.refresh.pause') }}
        </NButton>
      </template>
      {{ paused ? t('shell.refresh.resume_tip') : t('shell.refresh.pause_tip') }}
    </NTooltip>
    <NTooltip>
      <template #trigger>
        <NButton quaternary circle @click="emit('refresh')">
          <template #icon><NIcon :component="RefreshOutline" /></template>
        </NButton>
      </template>
      {{ t('shell.refresh.now') }}
    </NTooltip>
  </NSpace>
</template>
