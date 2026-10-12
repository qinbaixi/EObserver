<script setup lang="ts">
defineProps<{ title: string; subtitle?: string }>()
</script>

<template>
  <div class="page-header">
    <div>
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
  margin-bottom: 20px;
}
h2 {
  margin: 0;
  font-size: 22px;
}
.sub {
  margin-top: 4px;
  opacity: 0.6;
}
</style>
