import { createI18n } from 'vue-i18n'
import zh from './zh'
import en from './en'

export type Locale = 'zh' | 'en'

// Pages written since the i18n switch take their text from here; older
// pages still carry inline Chinese until they are migrated.
export const i18n = createI18n({
  legacy: false,
  locale: 'zh' as Locale,
  fallbackLocale: 'zh',
  messages: { zh, en },
})
