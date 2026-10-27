<script setup lang="ts">
import { NIcon } from 'naive-ui'
import { BookOutline } from '@vicons/ionicons5'
import { useKnowledge } from '../stores/knowledge'

// A value in a table (such as an allocator name) that opens its BEAM Book
// knowledge card on click. Without a card it is shown as plain text.
const props = defineProps<{ text: string; card?: string }>()
const knowledge = useKnowledge()

function open(e: MouseEvent) {
  e.stopPropagation()
  if (props.card) knowledge.openCard(props.card)
}
</script>

<template>
  <span v-if="card" class="klink" @click="open">{{ text }}<NIcon :component="BookOutline" class="klink-book" /></span>
  <span v-else>{{ text }}</span>
</template>

<style scoped>
.klink {
  cursor: pointer;
  text-decoration: underline dotted;
  text-decoration-color: rgba(128, 128, 128, 0.6);
  text-underline-offset: 3px;
}
.klink-book {
  margin-left: 4px;
  font-size: 0.85em;
  vertical-align: -1px;
  opacity: 0.45;
}
.klink:hover .klink-book {
  opacity: 0.9;
}
</style>
