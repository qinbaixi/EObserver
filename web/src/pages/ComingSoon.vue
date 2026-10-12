<script setup lang="ts">
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import { NEmpty, NIcon } from 'naive-ui'
import type { PageMeta } from '../router'
import PageHeader from '../components/PageHeader.vue'

const route = useRoute()
const meta = computed(() => route.meta.page as PageMeta)
</script>

<template>
  <PageHeader :title="meta.title" :subtitle="meta.subtitle" />
  <NEmpty :description="`该页面将在 ${meta.milestone} 里程碑实现`" style="padding: 80px 0">
    <template #icon><NIcon :component="meta.icon" /></template>
  </NEmpty>
</template>
