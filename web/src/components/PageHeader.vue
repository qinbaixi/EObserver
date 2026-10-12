<script setup lang="ts">
defineProps<{ title: string; subtitle?: string }>()
</script>

<template>
  <div class="page-header">
    <div class="titles">
      <h2>{{ title }}</h2>
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
h2 {
  margin: 0;
  font-size: 22px;
}
.sub {
  margin-top: 4px;
  opacity: 0.6;
  overflow-wrap: anywhere;
}
</style>
