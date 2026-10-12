<script setup lang="ts">
import { NModal, NCard } from 'naive-ui'
import { useUi } from '../stores/ui'
import ConnectForm from './ConnectForm.vue'

const ui = useUi()
</script>

<template>
  <NModal v-model:show="ui.connectOpen">
    <NCard title="添加节点" style="width: 520px; max-width: 94vw" :bordered="false" closable
           @close="ui.connectOpen = false">
      <ConnectForm @connected="ui.connectOpen = false" />
    </NCard>
  </NModal>
</template>
