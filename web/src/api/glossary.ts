// Short explanations shown when hovering a term (see components/Term.vue).
// The texts live in the shell language files (shell.glossary.*). A term is
// looked up by its Chinese label, which stays the id that term() and
// <Term label> take, and is shown in the current UI language; an English
// label is accepted too. Read as plain data rather than vue-i18n messages,
// so the explanations may contain { } and @.
import { currentLocale } from '../i18n'
import shellZh from '../i18n/areas/shell.zh'
import shellEn from '../i18n/areas/shell.en'

type Slug = keyof typeof shellZh.glossary
const TEXTS = { zh: shellZh.glossary, en: shellEn.glossary }

const byLabel = new Map<string, Slug>()
for (const [slug, e] of Object.entries(shellEn.glossary)) byLabel.set(e.label, slug as Slug)
for (const [slug, e] of Object.entries(shellZh.glossary)) byLabel.set(e.label, slug as Slug)

// The label in the current language; unknown labels come back as given.
export function termLabel(label: string): string {
  const slug = byLabel.get(label)
  return slug ? TEXTS[currentLocale()][slug].label : label
}

// The explanation in the current language, if the glossary has one.
export function termTip(label: string): string | undefined {
  const slug = byLabel.get(label)
  return slug ? TEXTS[currentLocale()][slug].tip : undefined
}

// The glossary slug of a label (Chinese or English), if it has one.
export function termSlug(label: string): string | undefined {
  return byLabel.get(label)
}
