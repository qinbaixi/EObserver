<script setup lang="ts">
import { NModal, NCard, NButton, NIcon } from 'naive-ui'
import { OpenOutline, CloseOutline } from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'
import { useRouter } from 'vue-router'
import { useKnowledge } from '../stores/knowledge'
import BookReader from './BookReader.vue'

// The BEAM Book over the current page, opened from a knowledge card so the
// page and its open drawers stay where they were.
const { t } = useI18n()
const k = useKnowledge()
const router = useRouter()

function openPage() {
  const s = k.readerTarget
  k.readerOpen = false
  k.open = false
  void router.push({ path: '/book', query: s ? { s } : {} })
}
</script>

<template>
  <NModal v-model:show="k.readerOpen">
    <NCard class="book-modal" :bordered="false" size="small" role="dialog" content-class="book-modal-body">
      <template #header>
        <span class="book-modal-title">{{ t('book.reader.title') }}</span>
      </template>
      <template #header-extra>
        <NButton quaternary size="small" @click="openPage">
          <template #icon><NIcon :component="OpenOutline" /></template>
          {{ t('book.reader.open_page') }}
        </NButton>
        <NButton quaternary circle size="small" @click="k.readerOpen = false">
          <template #icon><NIcon :component="CloseOutline" /></template>
        </NButton>
      </template>
      <BookReader :target="k.readerTarget" @navigate="(s) => (k.readerTarget = s)" />
    </NCard>
  </NModal>
</template>

<style scoped>
.book-modal {
  width: min(1180px, 94vw);
  height: 88vh;
  display: flex;
  flex-direction: column;
}
.book-modal :deep(.book-modal-body) {
  flex: 1;
  min-height: 0;
  padding-top: 0;
}
.book-modal-title {
  font-size: 13px;
  font-weight: 500;
  opacity: 0.6;
}
.book-modal :deep(.n-card-header) {
  padding-top: 10px;
  padding-bottom: 6px;
}
</style>
