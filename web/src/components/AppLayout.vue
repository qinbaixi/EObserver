<script setup lang="ts">
import { computed, h, ref } from 'vue'
import { useRoute, useRouter, RouterView } from 'vue-router'
import {
  NLayout, NLayoutSider, NLayoutHeader, NLayoutContent, NMenu, NIcon, NButton,
  NTooltip, NSpace, NDropdown, useMessage, type MenuOption,
} from 'naive-ui'
import { MoonOutline, SunnyOutline, LinkOutline, ContrastOutline } from '@vicons/ionicons5'
import { pages } from '../router'
import { useTheme, type Mode } from '../stores/theme'
import { useNodes } from '../stores/nodes'
import { useSettings } from '../stores/settings'
import { client } from '../api/ws'
import NodeSwitcher from './NodeSwitcher.vue'
import WelcomePanel from './WelcomePanel.vue'
import ConnectDialog from './ConnectDialog.vue'
import UpdateChecker from './UpdateChecker.vue'
import { useUrlSync } from '../composables/useUrlSync'

const route = useRoute()
const router = useRouter()
const theme = useTheme()
const nodes = useNodes()
const settings = useSettings()
const collapsed = ref(false)
const message = useMessage()
useUrlSync()

const themeOptions = computed(() => ([
  ['system', '跟随系统', ContrastOutline], ['light', '浅色', SunnyOutline], ['dark', '深色', MoonOutline],
] as const).map(([key, label, icon]) => ({
  key,
  label: theme.mode === key ? `${label} ✓` : label,
  icon: () => h(NIcon, { component: icon }),
})))

async function copyLink() {
  try {
    await navigator.clipboard.writeText(window.location.href)
    message.success('已复制当前页面链接')
  } catch {
    message.info(window.location.href)
  }
}

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
             style="padding-bottom: 96px"
             @update:value="(k: string) => router.push({ name: k })" />
      <UpdateChecker v-if="settings.version" :collapsed="collapsed" />
    </NLayoutSider>
    <NLayout>
      <NLayoutHeader bordered class="header">
        <div class="header-left">
          <NodeSwitcher />
        </div>
        <NSpace align="center" :size="12">
          <NTooltip v-if="settings.readOnly">
            <template #trigger>
              <span class="ro">只读</span>
            </template>
            以 --read-only 启动：不能 kill 进程、发送消息或关闭端口
          </NTooltip>
          <NTooltip>
            <template #trigger>
              <span class="socket-dot" :class="client.state.value" />
            </template>
            {{ socketText }}
          </NTooltip>
          <NTooltip>
            <template #trigger>
              <NButton quaternary circle @click="copyLink">
                <template #icon><NIcon :component="LinkOutline" /></template>
              </NButton>
            </template>
            复制当前页面链接（包含节点与打开的详情）
          </NTooltip>
          <NDropdown trigger="click" :options="themeOptions" :value="theme.mode"
                     @select="(m: Mode) => theme.setMode(m)">
            <NButton quaternary circle class="theme-toggle" title="主题">
              <template #icon>
                <NIcon :component="theme.mode === 'system' ? ContrastOutline : theme.isDark ? MoonOutline : SunnyOutline" />
              </template>
            </NButton>
          </NDropdown>
        </NSpace>
      </NLayoutHeader>
      <NLayoutContent class="content" :native-scrollbar="false">
        <div class="content-inner">
          <WelcomePanel v-if="nodes.loaded && nodes.list.length === 0" />
          <RouterView v-else />
        </div>
      </NLayoutContent>
    </NLayout>
    <ConnectDialog />
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
  gap: 16px;
  padding: 0 20px;
}
.header-left {
  flex: 1 1 auto;
  min-width: 0;
}
.header > :last-child {
  flex: none;
}
.content {
  height: calc(100% - 60px);
}
.content-inner {
  padding: 24px;
  max-width: 1440px;
  margin: 0 auto;
}
.ro {
  font-size: 12px;
  padding: 1px 8px;
  border-radius: 10px;
  border: 1px solid currentColor;
  opacity: 0.7;
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
