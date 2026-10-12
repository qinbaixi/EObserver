<script setup lang="ts">
import { computed } from 'vue'
import {
  NConfigProvider, NMessageProvider, NDialogProvider, NGlobalStyle,
  darkTheme, zhCN, dateZhCN, type GlobalThemeOverrides,
} from 'naive-ui'
import { useTheme } from './stores/theme'
import AppLayout from './components/AppLayout.vue'

const theme = useTheme()

const overrides = computed<GlobalThemeOverrides>(() => {
  const primary = theme.isDark ? '#F0587A' : '#A90533'
  return {
    common: {
      primaryColor: primary,
      primaryColorHover: theme.isDark ? '#F47A95' : '#C21245',
      primaryColorPressed: theme.isDark ? '#D9436A' : '#8A0429',
      primaryColorSuppl: primary,
      borderRadius: '8px',
      bodyColor: theme.isDark ? '#101014' : '#F5F6F8',
    },
    Card: { borderRadius: '12px' },
  }
})
</script>

<template>
  <NConfigProvider :theme="theme.isDark ? darkTheme : null" :theme-overrides="overrides"
                   :locale="zhCN" :date-locale="dateZhCN">
    <NGlobalStyle />
    <NMessageProvider>
      <NDialogProvider>
        <AppLayout />
      </NDialogProvider>
    </NMessageProvider>
  </NConfigProvider>
</template>
