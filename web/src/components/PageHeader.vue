<script setup lang="ts">
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import { NButton, NDropdown, NIcon } from 'naive-ui'
import { BookOutline } from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'
import { pageCards } from '../beambook'
import { useKnowledge } from '../stores/knowledge'

defineProps<{ title: string; subtitle?: string }>()

// Each page offers the BEAM Book cards behind what it shows (beambook/terms.json).
const route = useRoute()
const { t } = useI18n()
const knowledge = useKnowledge()
const cards = computed(() => pageCards(String(route.name ?? '')))
const options = computed(() => cards.value.map((key) => ({ key, label: t(`book.cards.${key}`) })))
</script>

<template>
  <div class="page-header">
    <div class="titles">
      <div class="title-row">
        <h2>{{ title }}</h2>
        <NDropdown v-if="cards.length" trigger="click" :options="options" @select="(k: string) => knowledge.openCard(k)">
          <NButton quaternary size="tiny" class="knowledge">
            <template #icon><NIcon :component="BookOutline" /></template>
            {{ t('book.page_cards') }}
          </NButton>
        </NDropdown>
      </div>
      <div v-if="subtitle" class="sub">{{ subtitle }}</div>
    </div>
    <slot />
  </div>
</template>

<style scoped>
.page-header {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 12px 24px;
  margin-bottom: 20px;
}
.titles {
  min-width: 0;
}
.title-row {
  display: flex;
  align-items: center;
  gap: 10px;
}
h2 {
  margin: 0;
  font-size: 22px;
}
.knowledge {
  opacity: 0.65;
}
.knowledge:hover {
  opacity: 1;
}
.sub {
  margin-top: 4px;
  opacity: 0.6;
  overflow-wrap: anywhere;
}
</style>
