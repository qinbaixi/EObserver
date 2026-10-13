import { i18n, currentLocale } from '../i18n'

export function formatBytes(n: number): string {
  if (!Number.isFinite(n)) return '-'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let i = 0
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024
    i++
  }
  return `${n.toFixed(i === 0 ? 0 : n >= 100 ? 0 : n >= 10 ? 1 : 2)} ${units[i]}`
}

export function formatNumber(n: number): string {
  return Number.isFinite(n) ? n.toLocaleString('en-US') : '-'
}

// The two largest units, in the UI language ("3 天 4 小时" / "3d 4h").
export function formatDuration(ms: number): string {
  const s = Math.floor(ms / 1000)
  const d = Math.floor(s / 86400)
  const h = Math.floor((s % 86400) / 3600)
  const m = Math.floor((s % 3600) / 60)
  const t = (key: string, named: Record<string, number>) => i18n.global.t(`shell.format.${key}`, named)
  if (d > 0) return t('days', { d, h })
  if (h > 0) return t('hours', { h, m })
  if (m > 0) return t('minutes', { m, s: s % 60 })
  return t('seconds', { s })
}

// A date and time (epoch ms) in the UI language's usual format.
export function formatDateTime(ms: number): string {
  return new Date(ms).toLocaleString(currentLocale() === 'zh' ? 'zh-CN' : 'en-US')
}
