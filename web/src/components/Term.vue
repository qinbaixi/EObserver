<script setup lang="ts">
import { computed } from 'vue'
import { NTooltip } from 'naive-ui'
import { glossary } from '../api/glossary'

// A label with an explanation on hover when the glossary has one.
const props = defineProps<{ label: string; tip?: string }>()
const text = computed(() => props.tip ?? glossary[props.label])
</script>

<template>
  <NTooltip v-if="text" :style="{ maxWidth: '320px' }">
    <template #trigger>
      <span class="term">{{ label }}</span>
    </template>
    {{ text }}
  </NTooltip>
  <span v-else>{{ label }}</span>
</template>

<style scoped>
.term {
  cursor: help;
  text-decoration: underline dotted;
  text-decoration-color: rgba(128, 128, 128, 0.6);
  text-underline-offset: 3px;
}
</style>
