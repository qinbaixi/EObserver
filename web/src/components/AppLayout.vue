<script setup lang="ts">
import { computed, h, ref } from 'vue'
import { useRoute, useRouter, RouterView } from 'vue-router'
import {
  NLayout, NLayoutSider, NLayoutHeader, NLayoutContent, NMenu, NIcon, NButton,
  NTooltip, NSpace, type MenuOption,
} from 'naive-ui'
import { MoonOutline, SunnyOutline } from '@vicons/ionicons5'
import { pages } from '../router'
import { useTheme } from '../stores/theme'
import { useNodes } from '../stores/nodes'
import { client } from '../api/ws'
import NodeSwitcher from './NodeSwitcher.vue'
import WelcomePanel from './WelcomePanel.vue'

const route = useRoute()
const router = useRouter()
const theme = useTheme()
const nodes = useNodes()
const collapsed = ref(false)

const menuOptions = computed<MenuOption[]>(() =>
  pages.map((p) => ({
    key: p.name,
    label: () => h('span', { class: 'menu-label' }, [
      p.meta.title,
      p.meta.milestone ? h('span', { class: 'menu-soon' }, p.meta.milestone) : null,
    ]),
    icon: () => h(NIcon, null, { default: () => h(p.meta.icon) }),
  })),
)

const socketText = computed(() => ({
  open: '服务已连接',
  connecting: '正在连接服务…',
  closed: '服务连接已断开，正在重试',
}[client.state.value]))
</script>

<template>
  <NLayout has-sider position="absolute">
    <NLayoutSider bordered collapse-mode="width" :collapsed-width="64" :width="220"
                  :collapsed="collapsed" show-trigger @collapse="collapsed = true"
                  @expand="collapsed = false">
      <div class="brand" :class="{ collapsed }">
        <img src="/favicon.svg" alt="" class="brand-logo" />
        <span v-if="!collapsed" class="brand-name">EObserver</span>
      </div>
      <NMenu :value="String(route.name)" :options="menuOptions" :collapsed="collapsed"
             :collapsed-width="64" :collapsed-icon-size="20"
             @update:value="(k: string) => router.push({ name: k })" />
    </NLayoutSider>
    <NLayout>
      <NLayoutHeader bordered class="header">
        <div class="header-left">
          <NodeSwitcher />
        </div>
        <NSpace align="center" :size="12">
          <NTooltip>
            <template #trigger>
              <span class="socket-dot" :class="client.state.value" />
            </template>
            {{ socketText }}
          </NTooltip>
          <NButton quaternary circle class="theme-toggle" @click="theme.toggle()">
            <template #icon>
              <NIcon :component="theme.isDark ? SunnyOutline : MoonOutline" />
            </template>
          </NButton>
        </NSpace>
      </NLayoutHeader>
      <NLayoutContent class="content" :native-scrollbar="false">
        <div class="content-inner">
          <WelcomePanel v-if="nodes.loaded && nodes.list.length === 0" />
          <RouterView v-else />
        </div>
      </NLayoutContent>
    </NLayout>
  </NLayout>
</template>

<style scoped>
.brand {
  display: flex;
  align-items: center;
  gap: 10px;
  height: 60px;
  padding: 0 20px;
}
.brand.collapsed {
  justify-content: center;
  padding: 0;
}
.brand-logo {
  width: 28px;
  height: 28px;
}
.brand-name {
  font-weight: 700;
  font-size: 17px;
  letter-spacing: 0.2px;
}
.header {
  height: 60px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 20px;
}
.content {
  height: calc(100% - 60px);
}
.content-inner {
  padding: 24px;
  max-width: 1440px;
  margin: 0 auto;
}
.socket-dot {
  display: inline-block;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #18a058;
}
.socket-dot.connecting {
  background: #f0a020;
}
.socket-dot.closed {
  background: #d03050;
}
:deep(.menu-label) {
  display: inline-flex;
  align-items: center;
  gap: 8px;
}
:deep(.menu-soon) {
  font-size: 11px;
  line-height: 16px;
  padding: 0 6px;
  border-radius: 8px;
  opacity: 0.55;
  border: 1px solid currentColor;
}
</style>
