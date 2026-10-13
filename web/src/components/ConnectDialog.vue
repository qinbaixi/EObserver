<script setup lang="ts">
import { NModal, NCard } from 'naive-ui'
import { useI18n } from 'vue-i18n'
import { useUi } from '../stores/ui'
import ConnectForm from './ConnectForm.vue'

const ui = useUi()
const { t } = useI18n()
</script>

<template>
  <NModal v-model:show="ui.connectOpen">
    <NCard :title="t('shell.connect.title')" style="width: 520px; max-width: 94vw" :bordered="false" closable
           @close="ui.connectOpen = false">
      <ConnectForm @connected="ui.connectOpen = false" />
    </NCard>
  </NModal>
</template>
