// Turns backend error reasons (atoms or printed terms) into text in the
// current UI language (shell.errors.*).
import { i18n } from '../i18n'
import shellZh from '../i18n/areas/shell.zh'

const KEYS = Object.keys(shellZh.errors).filter((k) => k !== 'wrapped')
const known = new Set(KEYS)
const t = (key: string, named: Record<string, unknown> = {}) => i18n.global.t(`shell.errors.${key}`, named)

export function errorText(e: unknown): string {
  const msg = e instanceof Error ? e.message : String(e)
  if (known.has(msg)) return t(msg)
  for (const key of KEYS) {
    if (new RegExp(`\\b${key}\\b`).test(msg)) return t('wrapped', { text: t(key), msg })
  }
  return msg
}
