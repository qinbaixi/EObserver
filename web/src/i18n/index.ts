import { createI18n } from 'vue-i18n'
import zh from './zh'
import en from './en'
import shellZh from './areas/shell.zh'
import shellEn from './areas/shell.en'
import pagesZh from './areas/pages.zh'
import pagesEn from './areas/pages.en'
import procsZh from './areas/procs.zh'
import procsEn from './areas/procs.en'
import reconZh from './areas/recon.zh'
import reconEn from './areas/recon.en'
import crashdumpZh from './areas/crashdump.zh'
import crashdumpEn from './areas/crashdump.en'
import bookZh from './areas/book.zh'
import bookEn from './areas/book.en'

export type Locale = 'zh' | 'en'
export const LOCALES: Locale[] = ['zh', 'en']
export const LOCALE_KEY = 'eobs.locale'

// The saved choice, else the system language: any Chinese variant gets
// Chinese, everything else English.
export function initialLocale(): Locale {
  try {
    const saved = localStorage.getItem(LOCALE_KEY)
    if (saved === 'zh' || saved === 'en') return saved
  } catch {
    /* storage unavailable */
  }
  const langs = navigator.languages?.length ? navigator.languages : [navigator.language]
  return langs.some((l) => /^zh\b/i.test(l ?? '')) ? 'zh' : 'en'
}

export const htmlLang = (l: Locale) => (l === 'zh' ? 'zh-CN' : 'en')

const locale = initialLocale()
document.documentElement.lang = htmlLang(locale)

// Each area file owns one top-level key: shell (layout, nodes, connect,
// shared components), pages (system / load / allocators / applications /
// ports / sockets / cluster), procs (processes, tables, trace basics),
// recon (the Recon toolbox page), crashdump (the crash dump viewer), book
// (BEAM Book knowledge cards and reader).
export const i18n = createI18n({
  legacy: false,
  locale,
  fallbackLocale: 'zh',
  messages: {
    zh: { ...zh, shell: shellZh, pages: pagesZh, procs: procsZh, recon: reconZh, crashdump: crashdumpZh, book: bookZh },
    en: { ...en, shell: shellEn, pages: pagesEn, procs: procsEn, recon: reconEn, crashdump: crashdumpEn, book: bookEn },
  },
})

export const currentLocale = () => i18n.global.locale.value as Locale
