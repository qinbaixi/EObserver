import { computed } from 'vue'
import { useTheme } from '../stores/theme'

// Categorical slots in fixed order (validated light/dark steps), plus the
// sequential blue ramp used for the scheduler heatmap.
const SERIES_LIGHT = ['#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4', '#008300', '#6250d6', '#e34948']
const SERIES_DARK = ['#3987e5', '#d95926', '#199e70', '#c98500', '#d55181', '#008300', '#9085e9', '#e66767']

export function useChartTheme() {
  const theme = useTheme()
  return computed(() => {
    const dark = theme.isDark
    return {
      dark,
      series: dark ? SERIES_DARK : SERIES_LIGHT,
      text: dark ? 'rgba(255,255,255,0.82)' : 'rgba(0,0,0,0.82)',
      muted: dark ? 'rgba(255,255,255,0.45)' : 'rgba(0,0,0,0.45)',
      grid: dark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.07)',
      axis: dark ? 'rgba(255,255,255,0.18)' : 'rgba(0,0,0,0.15)',
      surface: dark ? '#26292F' : '#F7F8FA',  // matches the card color in App.vue
      tooltipBg: dark ? '#2D3037' : '#FAFBFC',
      // Sequential blue, near-surface to dark (reversed on dark surfaces).
      ramp: dark
        ? ['#2a3442', '#184f95', '#256abf', '#3987e5', '#6da7ec', '#b7d3f6']
        : ['#e6eef9', '#b7d3f6', '#86b6ef', '#3987e5', '#256abf', '#104281'],
    }
  })
}
