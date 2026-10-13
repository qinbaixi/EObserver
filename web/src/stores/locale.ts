import { defineStore } from 'pinia'
import { computed } from 'vue'
import { i18n, htmlLang, LOCALE_KEY, type Locale } from '../i18n'

// The UI language. Switching takes effect at once: vue-i18n, naive-ui
// (App.vue reads `locale`), <html lang> and the desktop app's own texts.
export const useLocale = defineStore('locale', () => {
  const locale = computed(() => i18n.global.locale.value as Locale)

  function tellDesktop(l: Locale) {
    try {
      window.eobsDesktop?.setLocale?.(l)
    } catch {
      /* older desktop build */
    }
  }

  function setLocale(l: Locale) {
    i18n.global.locale.value = l
    document.documentElement.lang = htmlLang(l)
    try {
      localStorage.setItem(LOCALE_KEY, l)
    } catch {
      /* storage unavailable */
    }
    tellDesktop(l)
  }

  function toggle() {
    setLocale(locale.value === 'zh' ? 'en' : 'zh')
  }

  tellDesktop(locale.value)
  return { locale, setLocale, toggle }
})
