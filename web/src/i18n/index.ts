import { createI18n } from 'vue-i18n'
import zh from './zh'
import en from './en'
import shellZh from './areas/shell.zh'
import shellEn from './areas/shell.en'
import pagesZh from './areas/pages.zh'
import pagesEn from './areas/pages.en'
import procsZh from './areas/procs.zh'
import procsEn from './areas/procs.en'

export type Locale = 'zh' | 'en'

// Each area file owns one top-level key: shell (layout, nodes, connect,
// shared components), pages (system / load / allocators / applications /
// ports / sockets / cluster), procs (processes, tables, trace basics).
export const i18n = createI18n({
  legacy: false,
  locale: 'zh' as Locale,
  fallbackLocale: 'zh',
  messages: {
    zh: { ...zh, shell: shellZh, pages: pagesZh, procs: procsZh },
    en: { ...en, shell: shellEn, pages: pagesEn, procs: procsEn },
  },
})
