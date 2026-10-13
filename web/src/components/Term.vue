<script setup lang="ts">
import { computed } from 'vue'
import { NTooltip } from 'naive-ui'
import { termLabel, termTip } from '../api/glossary'

// A label with an explanation on hover when the glossary has one. `label`
// is the glossary id (the Chinese label); it is shown in the UI language.
const props = defineProps<{ label: string; tip?: string }>()
const shown = computed(() => termLabel(props.label))
const text = computed(() => props.tip ?? termTip(props.label))
</script>

<template>
  <NTooltip v-if="text" :style="{ maxWidth: '320px' }">
    <template #trigger>
      <span class="term">{{ shown }}</span>
    </template>
    {{ text }}
  </NTooltip>
  <span v-else>{{ shown }}</span>
</template>

<style scoped>
.term {
  cursor: help;
  text-decoration: underline dotted;
  text-decoration-color: rgba(128, 128, 128, 0.6);
  text-underline-offset: 3px;
}
</style>
