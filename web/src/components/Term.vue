<script setup lang="ts">
import { computed } from 'vue'
import { NTooltip, NIcon } from 'naive-ui'
import { BookOutline } from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'
import { termLabel, termTip, termSlug } from '../api/glossary'
import { cardForSlug } from '../beambook'
import { useKnowledge } from '../stores/knowledge'

// A label with an explanation on hover when the glossary has one. `label`
// is the glossary id (the Chinese label); it is shown in the UI language.
// Terms with a BEAM Book knowledge card open it on click. A `tip` override
// means the label stands for something else here, so it opens no card
// unless `card` names one.
const props = defineProps<{ label: string; tip?: string; card?: string }>()
const { t } = useI18n()
const knowledge = useKnowledge()
const shown = computed(() => termLabel(props.label))
const text = computed(() => props.tip ?? termTip(props.label))
const card = computed(() => {
  if (props.card) return props.card
  if (props.tip) return undefined
  const slug = termSlug(props.label)
  return slug ? cardForSlug(slug) : undefined
})

function open(e: MouseEvent) {
  // Table headers sort on click; the card should not.
  e.stopPropagation()
  if (card.value) knowledge.openCard(card.value, { label: shown.value, tip: text.value })
}
</script>

<template>
  <NTooltip v-if="text || card" :style="{ maxWidth: '320px' }">
    <template #trigger>
      <span class="term" :class="{ 'has-card': card }" @click="open">{{ shown }}<NIcon v-if="card" :component="BookOutline" class="term-book" /></span>
    </template>
    <template v-if="text">{{ text }}</template>
    <div v-if="card" class="term-hint">{{ t('book.hint') }}</div>
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
.term.has-card {
  cursor: pointer;
}
.term-book {
  margin-left: 3px;
  font-size: 0.85em;
  vertical-align: -1px;
  opacity: 0.5;
}
.term.has-card:hover .term-book {
  opacity: 0.9;
}
.term-hint {
  margin-top: 4px;
  font-size: 12px;
  opacity: 0.7;
}
.term-hint:first-child {
  margin-top: 0;
}
</style>
