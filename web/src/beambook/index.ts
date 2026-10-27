// Knowledge from The BEAM Book (Erik Stenman, CC BY 4.0; Chinese translation
// by Bycc), bundled for offline use. scripts/beambook/extract.py generates
// ./data from the book's HTML: a table of contents and one file per chapter
// for each language, the card excerpts, and the images. Everything except
// the image URLs is loaded on first use, so the book costs nothing until a
// card or the reader is opened.
import type { Locale } from '../i18n'
import terms from './terms.json'

export interface CardSection {
  id: string
  chapter: string
  title: string
  html: string
  more: boolean
}
export type Cards = Record<string, CardSection[]>

export interface TocChapter {
  id: string
  title: string
  part?: string
  sections: { id: string; title: string; level: number }[]
}
export interface Toc {
  chapters: TocChapter[]
  // Any id in the book (sections, figures, footnotes) -> its chapter.
  anchors: Record<string, string>
}
export interface Chapter {
  id: string
  title: string
  html: string
}

type Loader<T> = () => Promise<{ default: T }>
const cardFiles = import.meta.glob<{ default: Cards }>('./data/cards.*.json')
const tocFiles = import.meta.glob<{ default: Toc }>('./data/toc.*.json')
const chapterFiles = import.meta.glob<{ default: Chapter }>('./data/*/*.json')
const images = import.meta.glob<string>('./data/img/*', { eager: true, query: '?url', import: 'default' })

const CARDS = terms.cards as Record<string, { sections: string[]; related: string[] }>
const TERMS = terms.terms as Record<string, string>
const PAGES = terms.pages as Record<string, string[]>

export const cardIds = Object.keys(CARDS)
export const hasCard = (id: string) => id in CARDS
export const relatedCards = (id: string) => CARDS[id]?.related ?? []
// The card a glossary entry (by slug) opens, if any.
export const cardForSlug = (slug: string): string | undefined => TERMS[slug]
// Cards a page offers in its header, by route name.
export const pageCards = (route: string): string[] => PAGES[route] ?? []
// Glossary slugs that open a card, for search.
export const slugsForCard = (id: string) => Object.keys(TERMS).filter((s) => TERMS[s] === id)

const cache = new Map<string, Promise<unknown>>()
function load<T>(files: Record<string, Loader<T>>, path: string): Promise<T> {
  let p = cache.get(path) as Promise<T> | undefined
  if (!p) {
    const f = files[path]
    p = f ? f().then((m) => m.default) : Promise.reject(new Error(`missing ${path}`))
    p.catch(() => cache.delete(path))
    cache.set(path, p)
  }
  return p
}

export const loadCards = (lang: Locale) => load(cardFiles, `./data/cards.${lang}.json`)
export const loadToc = (lang: Locale) => load(tocFiles, `./data/toc.${lang}.json`)
export const loadChapter = (lang: Locale, id: string) => load(chapterFiles, `./data/${lang}/${id}.json`)

// The extracted HTML names images as bbimg:<file>.
export const withImages = (html: string) =>
  html.replace(/src="bbimg:([^"]+)"/g, (_, name: string) => `src="${images[`./data/img/${name}`] ?? ''}"`)
