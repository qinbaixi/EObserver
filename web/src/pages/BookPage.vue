<script setup lang="ts">
import { computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import BookReader from '../components/BookReader.vue'

// The bundled BEAM Book as a page; ?s= is the section being read, so a
// link or reload comes back to it. Needs no node.
const route = useRoute()
const router = useRouter()
const target = computed(() => (typeof route.query.s === 'string' ? route.query.s : null))

function onNavigate(s: string) {
  if (s !== target.value) void router.replace({ query: { ...route.query, s } })
}
</script>

<template>
  <div class="book-page">
    <BookReader :target="target" @navigate="onNavigate" />
  </div>
</template>

<style scoped>
.book-page {
  /* The layout pads the content by 24px and its header is 60px tall. */
  height: calc(100vh - 60px - 48px);
}
</style>
