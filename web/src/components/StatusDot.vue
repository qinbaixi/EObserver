<script setup lang="ts">
import type { NodeStatus } from '../api/types'
defineProps<{ status: NodeStatus }>()
</script>

<template>
  <span class="dot" :class="status" />
</template>

<style scoped>
.dot {
  display: inline-block;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  flex: none;
}
.connected { background: #18a058; box-shadow: 0 0 0 3px rgba(24, 160, 88, 0.18); }
.connecting { background: #f0a020; }
.disconnected { background: #d03050; }
.failed { background: #909399; }
</style>
