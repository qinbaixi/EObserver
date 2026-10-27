<script setup lang="ts">
import { NIcon, NTooltip } from 'naive-ui'
import { BookOutline } from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'
import { useKnowledge } from '../stores/knowledge'

// A small book button opening a BEAM Book knowledge card, for rows that are
// themselves clickable (findings, health checks) or have no term to click.
const props = defineProps<{ card: string }>()
const { t } = useI18n()
const knowledge = useKnowledge()

function open(e: MouseEvent) {
  e.stopPropagation()
  knowledge.openCard(props.card)
}
</script>

<template>
  <NTooltip>
    <template #trigger>
      <button type="button" class="kicon" :aria-label="t(`book.cards.${card}`)" @click="open">
        <NIcon :component="BookOutline" />
      </button>
    </template>
    {{ t(`book.cards.${card}`) }} · {{ t('book.hint') }}
  </NTooltip>
</template>

<style scoped>
.kicon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 2px;
  border: none;
  background: none;
  color: inherit;
  font-size: 14px;
  opacity: 0.45;
  cursor: pointer;
  border-radius: 4px;
}
.kicon:hover {
  opacity: 1;
  background: rgba(128, 128, 128, 0.15);
}
</style>
