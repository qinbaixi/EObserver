<script setup lang="ts">
import { computed } from 'vue'
import {
  NConfigProvider, NMessageProvider, NDialogProvider, NGlobalStyle,
  darkTheme, zhCN, dateZhCN, enUS, dateEnUS, type GlobalThemeOverrides,
} from 'naive-ui'
import { useTheme } from './stores/theme'
import { useLocale } from './stores/locale'
import AppLayout from './components/AppLayout.vue'

const theme = useTheme()
const lang = useLocale()
const naiveLocale = computed(() => (lang.locale === 'zh' ? zhCN : enUS))
const naiveDateLocale = computed(() => (lang.locale === 'zh' ? dateZhCN : dateEnUS))

// Softer than naive-ui's defaults on both ends: the light theme drops the
// pure white surfaces, the dark theme lifts its near-black ones.
const SURFACES = {
  light: { body: '#E8EBEF', chrome: '#F0F2F5', card: '#F7F8FA', raised: '#FAFBFC', header: '#EEF0F3', hover: '#EDEFF3' },
  dark: { body: '#1C1E23', chrome: '#212329', card: '#26292F', raised: '#2D3037', header: '#2B2E35', hover: '#30343B' },
}

const overrides = computed<GlobalThemeOverrides>(() => {
  const primary = theme.isDark ? '#F0587A' : '#A90533'
  const c = theme.isDark ? SURFACES.dark : SURFACES.light
  return {
    common: {
      primaryColor: primary,
      primaryColorHover: theme.isDark ? '#F47A95' : '#C21245',
      primaryColorPressed: theme.isDark ? '#D9436A' : '#8A0429',
      primaryColorSuppl: primary,
      borderRadius: '8px',
      bodyColor: c.body,
      cardColor: c.card,
      modalColor: c.raised,
      popoverColor: c.raised,
      tableColor: c.card,
      tableHeaderColor: c.header,
      tableColorHover: c.hover,
      textColor1: theme.isDark ? 'rgba(255, 255, 255, 0.86)' : 'rgba(22, 26, 33, 0.88)',
      textColor2: theme.isDark ? 'rgba(255, 255, 255, 0.78)' : 'rgba(22, 26, 33, 0.78)',
    },
    Layout: { color: c.body, siderColor: c.chrome, headerColor: c.chrome },
    DataTable: { thColor: c.header, tdColor: c.card, tdColorHover: c.hover },
    Card: { borderRadius: '12px' },
  }
})
</script>

<template>
  <NConfigProvider :theme="theme.isDark ? darkTheme : null" :theme-overrides="overrides"
                   :locale="naiveLocale" :date-locale="naiveDateLocale">
    <NGlobalStyle />
    <NMessageProvider>
      <NDialogProvider>
        <AppLayout />
      </NDialogProvider>
    </NMessageProvider>
  </NConfigProvider>
</template>
