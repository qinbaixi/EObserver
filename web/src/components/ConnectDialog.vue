<script setup lang="ts">
import { NModal, NCard } from 'naive-ui'
import ConnectForm from './ConnectForm.vue'

const show = defineModel<boolean>('show', { default: false })
</script>

<template>
  <NModal v-model:show="show">
    <NCard title="添加节点" style="width: 420px" :bordered="false" closable
           @close="show = false">
      <ConnectForm @connected="show = false" />
    </NCard>
  </NModal>
</template>
