import { computed } from 'vue'
import { useThemeVars } from 'naive-ui'
import { useTheme } from '../stores/theme'
import './book.css'

// The --bb-* colour variables book.css reads, from the current theme.
export function useBookStyle() {
  const vars = useThemeVars()
  const theme = useTheme()
  return computed(() => {
    const dark = theme.isDark
    return {
      '--bb-text': vars.value.textColor2,
      '--bb-muted': vars.value.textColor3,
      '--bb-border': vars.value.dividerColor,
      '--bb-accent': vars.value.primaryColor,
      '--bb-code-bg': dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.045)',
      '--bb-callout-bg': dark ? 'rgba(255,255,255,0.04)' : 'rgba(0,0,0,0.025)',
      '--bb-flash': dark ? 'rgba(99,226,183,0.25)' : 'rgba(24,160,88,0.18)',
      '--bb-kw': dark ? '#c792ea' : '#8250df',
      '--bb-str': dark ? '#c3e88d' : '#0a7d38',
      '--bb-num': dark ? '#f78c6c' : '#b35900',
      '--bb-fn': dark ? '#82aaff' : '#0550ae',
      '--bb-var': dark ? '#ffcb6b' : '#953800',
    }
  })
}
