<script setup lang="ts">
import { computed, h, ref, watch } from 'vue'
import { useRoute, useRouter, RouterView } from 'vue-router'
import {
  NLayout, NLayoutSider, NLayoutHeader, NLayoutContent, NMenu, NIcon, NButton,
  NTooltip, NSpace, NDropdown, NScrollbar, useMessage, useThemeVars, type MenuOption,
} from 'naive-ui'
import {
  MoonOutline, SunnyOutline, LinkOutline, ContrastOutline, SearchOutline, LanguageOutline,
  EllipsisHorizontalCircleOutline, OptionsOutline, SettingsOutline,
} from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'
import { pages, pageTitle } from '../router'
import { useTheme, type Mode } from '../stores/theme'
import { useLocale } from '../stores/locale'
import { LOCALES, type Locale } from '../i18n'
import { useNodes } from '../stores/nodes'
import { useLoad } from '../stores/load'
import { useAllocators } from '../stores/allocators'
import { useSettings } from '../stores/settings'
import { useTrace } from '../stores/trace'
import { client } from '../api/ws'
import NodeSwitcher from './NodeSwitcher.vue'
import WelcomePanel from './WelcomePanel.vue'
import ConnectDialog from './ConnectDialog.vue'
import UpdateChecker from './UpdateChecker.vue'
import CommandPalette from './CommandPalette.vue'
import KnowledgeDrawer from './KnowledgeDrawer.vue'
import BookModal from './BookModal.vue'
import NavCustomize from './NavCustomize.vue'
import { useUi } from '../stores/ui'
import { useNav } from '../stores/nav'
import { useUrlSync } from '../composables/useUrlSync'

const route = useRoute()
const router = useRouter()
const theme = useTheme()
const nodes = useNodes()
// Start background sampling (overview wall, allocators) as soon as the app
// opens; both can be paused on their pages.
useLoad()
useAllocators()
const settings = useSettings()
const trace = useTrace()
const collapsed = ref(false)
const message = useMessage()
const ui = useUi()
const { t } = useI18n()
const themeVars = useThemeVars()
const lang = useLocale()
const paletteKey = /Mac|iPhone|iPad/.test(navigator.platform) ? '⌘K' : 'Ctrl K'
useUrlSync()

const themeOptions = computed(() => ([
  ['system', t('shell.layout.theme_system'), ContrastOutline],
  ['light', t('shell.layout.theme_light'), SunnyOutline],
  ['dark', t('shell.layout.theme_dark'), MoonOutline],
] as const).map(([key, label, icon]) => ({
  key,
  label: theme.mode === key ? `${label} ✓` : label,
  icon: () => h(NIcon, { component: icon }),
})))

// Each language is named in itself, so it can be found from either one.
const localeOptions = computed(() => LOCALES.map((key) => {
  const label = t(`shell.locale.${key}`)
  return { key, label: lang.locale === key ? `${label} ✓` : label }
}))

async function copyLink() {
  try {
    await navigator.clipboard.writeText(window.location.href)
    message.success(t('shell.layout.copied'))
  } catch {
    message.info(window.location.href)
  }
}

const nav = useNav()
const byName = Object.fromEntries(pages.map((p) => [p.name, p]))
const pageOption = (name: string): MenuOption => {
  const p = byName[name]
  return {
    key: p.name,
    label: () => h('span', { class: 'menu-label' }, [
      pageTitle(p.meta),
      p.meta.milestone ? h('span', { class: 'menu-soon' }, p.meta.milestone) : null,
    ]),
    icon: () => h(NIcon, null, { default: () => h(p.meta.icon) }),
  }
}
const MORE = '__more'
const CUSTOMIZE = '__customize'
const customizing = ref(false)
// The chosen pages, then everything else under "More", whose row has a gear
// that opens the customize dialog.
const menuOptions = computed<MenuOption[]>(() => [
  ...nav.pinned.map(pageOption),
  {
    key: MORE,
    label: () => h('span', { class: 'menu-label menu-more' }, [
      t('shell.nav_more'),
      h('span', { class: 'menu-count' }, String(nav.rest.length)),
      h('span', {
        class: 'menu-gear',
        title: t('shell.nav_custom.title'),
        onClick: (e: MouseEvent) => { e.stopPropagation(); customizing.value = true },
      }, [h(NIcon, { component: SettingsOutline })]),
    ]),
    icon: () => h(NIcon, null, { default: () => h(EllipsisHorizontalCircleOutline) }),
    // The gear is in the row's label, which a collapsed sidebar hides, so the
    // popup menu offers the same entry instead.
    children: [
      ...nav.rest.map(pageOption),
      ...(collapsed.value ? [
        { type: 'divider', key: 'more-divider' },
        {
          key: CUSTOMIZE,
          label: () => h('span', { class: 'menu-custom' }, t('shell.nav_custom.open')),
          icon: () => h(NIcon, null, { default: () => h(OptionsOutline) }),
        },
      ] : []),
    ],
  },
])
// "More" opens by itself when the current page is in it.
const expanded = ref<string[]>([])
watch(() => route.name, (n) => {
  if (nav.rest.includes(String(n)) && !expanded.value.includes(MORE)) expanded.value = [...expanded.value, MORE]
}, { immediate: true })
function onSelect(k: string) {
  if (k === CUSTOMIZE) customizing.value = true
  else void router.push({ name: k })
}

// Pages that work without any observed node (the crash dump viewer, the book).
const nodeFree = computed(() => route.name === 'crashdump' || route.name === 'book')

const socketText = computed(() => t(`shell.layout.socket.${client.state.value}`))
</script>

<template>
  <NLayout has-sider position="absolute">
    <NLayoutSider bordered collapse-mode="width" :collapsed-width="64" :width="220"
                  :collapsed="collapsed" show-trigger @collapse="collapsed = true"
                  content-class="sider-body" @expand="collapsed = false">
      <div class="brand" :class="{ collapsed }">
        <img src="/favicon.svg" alt="" class="brand-logo" />
        <span v-if="!collapsed" class="brand-name">EObserver</span>
      </div>
      <NScrollbar class="nav-scroll">
      <NMenu class="nav-menu" :value="String(route.name)" :options="menuOptions" :collapsed="collapsed"
             :collapsed-width="64" :collapsed-icon-size="20"
             :expanded-keys="expanded" style="padding-bottom: 12px"
             @update:expanded-keys="(k: string[]) => (expanded = k)"
             @update:value="onSelect" />
      </NScrollbar>
      <UpdateChecker v-if="settings.version" :collapsed="collapsed" />
    </NLayoutSider>
    <NLayout>
      <NLayoutHeader bordered class="header" :style="{ '--search-border': themeVars.borderColor }">
        <div class="header-left">
          <NodeSwitcher v-if="!nodeFree" />
        </div>
        <NSpace align="center" :size="12">
          <button type="button" class="search-hint" :title="t('palette.open')" @click="ui.paletteOpen = true">
            <NIcon :component="SearchOutline" />
            <span class="search-text">{{ t('palette.open') }}</span>
            <kbd>{{ paletteKey }}</kbd>
          </button>
          <NTooltip v-if="settings.readOnly">
            <template #trigger>
              <span class="ro">{{ t('shell.layout.read_only') }}</span>
            </template>
            {{ t('shell.layout.read_only_tip') }}
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
            {{ t('shell.layout.copy_tip') }}
          </NTooltip>
          <NDropdown trigger="click" :options="themeOptions" :value="theme.mode"
                     @select="(m: Mode) => theme.setMode(m)">
            <NButton quaternary circle class="theme-toggle" :title="t('shell.layout.theme')">
              <template #icon>
                <NIcon :component="theme.mode === 'system' ? ContrastOutline : theme.isDark ? MoonOutline : SunnyOutline" />
              </template>
            </NButton>
          </NDropdown>
          <NDropdown trigger="click" :options="localeOptions" :value="lang.locale"
                     @select="(l: Locale) => lang.setLocale(l)">
            <NButton quaternary circle class="locale-toggle" :title="t('shell.layout.language')">
              <template #icon><NIcon :component="LanguageOutline" /></template>
            </NButton>
          </NDropdown>
        </NSpace>
      </NLayoutHeader>
      <NLayoutContent class="content" :native-scrollbar="false">
        <div class="content-inner">
          <WelcomePanel v-if="nodes.loaded && nodes.list.length === 0 && !trace.replay && !nodeFree" />
          <RouterView v-else />
        </div>
      </NLayoutContent>
    </NLayout>
    <ConnectDialog />
    <NavCustomize v-model:show="customizing" />
    <CommandPalette />
    <KnowledgeDrawer />
    <BookModal />
  </NLayout>
</template>

<style scoped>
/* The logo stays at the top and the version at the bottom; only the menu
   scrolls when "More" is open and the window is short. */
:deep(.sider-body) {
  display: flex;
  flex-direction: column;
  height: 100%;
}
.nav-scroll {
  flex: 1;
  min-height: 0;
}
.brand {
  flex: none;
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
.search-hint {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  height: 30px;
  padding: 0 6px 0 10px;
  border-radius: 6px;
  border: 1px solid var(--search-border);
  background: transparent;
  color: inherit;
  font: inherit;
  font-size: 13px;
  cursor: pointer;
  opacity: 0.75;
}
.search-hint:hover {
  opacity: 1;
}
.search-hint kbd {
  font-family: inherit;
  font-size: 11px;
  line-height: 18px;
  padding: 0 5px;
  border-radius: 4px;
  border: 1px solid var(--search-border);
}
@media (max-width: 720px) {
  .search-text, .search-hint kbd { display: none; }
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
:deep(.menu-count) {
  font-size: 11px;
  line-height: 16px;
  padding: 0 6px;
  border-radius: 8px;
  opacity: 0.5;
  background: rgba(128, 128, 128, 0.16);
}
:deep(.menu-custom) {
  opacity: 0.7;
}
/* The pinned pages are few, so they get room that grows with the window
   instead of the dense default rows; pages under "More" stay compact. */
.nav-menu {
  --nav-row: clamp(42px, 6vh, 56px);
  --nav-gap: clamp(4px, 1.1vh, 12px);
}
.nav-menu > :deep(.n-menu-item),
.nav-menu > :deep(.n-submenu) {
  margin-top: var(--nav-gap);
}
.nav-menu > :deep(.n-menu-item),
.nav-menu > :deep(.n-submenu > .n-menu-item),
.nav-menu > :deep(.n-submenu > .n-menu-item > .n-menu-item-content) {
  height: var(--nav-row);
}
.nav-menu > :deep(.n-menu-item .n-menu-item-content-header),
.nav-menu > :deep(.n-submenu > .n-menu-item .n-menu-item-content-header) {
  font-size: 15px;
}
.nav-menu > :deep(.n-menu-item .n-menu-item-content__icon),
.nav-menu > :deep(.n-submenu > .n-menu-item .n-menu-item-content__icon) {
  font-size: 21px !important;
}
.nav-menu > :deep(.n-submenu) {
  padding-top: var(--nav-gap);
}
.nav-menu > :deep(.n-submenu)::before {
  content: '';
  position: absolute;
  top: 0;
  left: 12px;
  right: 12px;
  border-top: 1px solid rgba(128, 128, 128, 0.14);
}
:deep(.menu-more) {
  display: flex;
  align-items: center;
  width: 100%;
}
:deep(.menu-gear) {
  margin-left: auto;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 26px;
  height: 26px;
  border-radius: 6px;
  font-size: 16px;
  opacity: 0.55;
}
:deep(.menu-gear:hover) {
  opacity: 1;
  background: rgba(128, 128, 128, 0.16);
}
</style>
