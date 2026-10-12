<script setup lang="ts">
import { NCard } from 'naive-ui'
import ConnectForm from './ConnectForm.vue'
</script>

<template>
  <div class="welcome">
    <img src="/favicon.svg" alt="" class="logo" />
    <h1>EObserver</h1>
    <p class="lead">连接一个 Erlang 节点开始观察。EObserver 以隐藏节点身份连接，不会出现在目标节点的 <code>nodes()</code> 中。</p>
    <NCard style="width: 400px">
      <ConnectForm />
    </NCard>
  </div>
</template>

<style scoped>
.welcome {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding-top: 8vh;
  text-align: center;
}
.logo {
  width: 56px;
  height: 56px;
}
h1 {
  margin: 16px 0 8px;
  font-size: 28px;
}
.lead {
  max-width: 460px;
  opacity: 0.7;
  margin: 0 0 24px;
  line-height: 1.6;
}
</style>
