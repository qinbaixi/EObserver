<script setup lang="ts">
// Refresh interval, pause / resume and manual refresh, shared by every
// page that shows periodically refreshed data.
import { computed } from 'vue'
import { NButton, NIcon, NSelect, NSpace, NTooltip } from 'naive-ui'
import { PauseOutline, PlayOutline, RefreshOutline } from '@vicons/ionicons5'

const paused = defineModel<boolean>('paused', { required: true })
const interval = defineModel<number>('interval', { required: true })
const emit = defineEmits<{ refresh: [] }>()

const STEPS = [1000, 2000, 3000, 5000, 10000, 30000]
const options = computed(() =>
  [...new Set([...STEPS, interval.value])].sort((a, b) => a - b)
    .map((v) => ({ label: `每 ${v / 1000} 秒`, value: v })))
</script>

<template>
  <NSpace align="center" :size="8" :wrap="false">
    <NSelect v-model:value="interval" :options="options" :disabled="paused" style="width: 110px" />
    <NTooltip>
      <template #trigger>
        <NButton secondary @click="paused = !paused">
          <template #icon><NIcon :component="paused ? PlayOutline : PauseOutline" /></template>
          {{ paused ? '继续' : '暂停' }}
        </NButton>
      </template>
      {{ paused ? '恢复自动刷新' : '暂停自动刷新，数据停在当前这一刻' }}
    </NTooltip>
    <NTooltip>
      <template #trigger>
        <NButton quaternary circle @click="emit('refresh')">
          <template #icon><NIcon :component="RefreshOutline" /></template>
        </NButton>
      </template>
      立即刷新
    </NTooltip>
  </NSpace>
</template>
