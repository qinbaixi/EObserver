<script setup lang="ts">
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import { NEmpty, NIcon } from 'naive-ui'
import { useI18n } from 'vue-i18n'
import { pageTitle, pageSubtitle, type PageMeta } from '../router'
import PageHeader from '../components/PageHeader.vue'

const { t } = useI18n()
const route = useRoute()
const meta = computed(() => route.meta.page as PageMeta)
</script>

<template>
  <PageHeader :title="pageTitle(meta)" :subtitle="pageSubtitle(meta)" />
  <NEmpty :description="t('shell.coming_soon', { milestone: meta.milestone })" style="padding: 80px 0">
    <template #icon><NIcon :component="meta.icon" /></template>
  </NEmpty>
</template>
