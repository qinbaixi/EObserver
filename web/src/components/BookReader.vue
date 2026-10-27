<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { NButton, NIcon, NSpin } from 'naive-ui'
import { ChevronBackOutline, ChevronForwardOutline, LanguageOutline } from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'
import { useLocale } from '../stores/locale'
import type { Locale } from '../i18n'
import { loadChapter, loadToc, withImages, type Toc } from '../beambook'
import { useBookStyle } from '../beambook/useBookStyle'

// The whole BEAM Book, one chapter at a time, with its table of contents.
// `target` is any id in the book (chapter, section, figure, footnote).
// Reads in the UI language; the reader can switch to the other one to
// compare the translation with the original.
const props = defineProps<{ target: string | null }>()
const emit = defineEmits<{ navigate: [target: string] }>()
const { t } = useI18n()
const lang = useLocale()
const bookStyle = useBookStyle()

const readLang = ref<Locale>(lang.locale)
watch(() => lang.locale, (l) => { readLang.value = l })

const toc = ref<Toc | null>(null)
const chapterId = ref<string | null>(null)
const html = ref('')
const loading = ref(false)
const failed = ref(false)
const current = ref<string | null>(null)
const pane = ref<HTMLElement | null>(null)
const tocPane = ref<HTMLElement | null>(null)

const chapters = computed(() => toc.value?.chapters ?? [])
const index = computed(() => chapters.value.findIndex((c) => c.id === chapterId.value))
const prev = computed(() => (index.value > 0 ? chapters.value[index.value - 1] : null))
const next = computed(() => (index.value >= 0 && index.value < chapters.value.length - 1 ? chapters.value[index.value + 1] : null))

let seq = 0
async function go(target: string | null, emitNav = true) {
  const mine = ++seq
  loading.value = true
  failed.value = false
  try {
    const l = readLang.value
    const tc = await loadToc(l)
    if (mine !== seq) return
    toc.value = tc
    const ch = (target && tc.anchors[target]) || tc.chapters[0].id
    if (ch !== chapterId.value || !html.value) {
      const c = await loadChapter(l, ch)
      if (mine !== seq) return
      chapterId.value = ch
      html.value = withImages(c.html)
    }
    current.value = target ?? ch
    loading.value = false
    await nextTick()
    reveal(target && target !== ch ? target : null)
    if (emitNav) emit('navigate', current.value)
  } catch {
    if (mine === seq) { failed.value = true; loading.value = false }
  }
}

function reveal(id: string | null) {
  const root = pane.value
  if (!root) return
  const el = id ? root.querySelector<HTMLElement>(`[id="${CSS.escape(id)}"]`) : null
  if (!el) { root.scrollTo({ top: 0 }); return }
  // Layout offsets, not screen positions: the reader may be in a modal that
  // is still zooming in.
  let top = 0
  for (let n: HTMLElement | null = el; n && n !== root; n = n.offsetParent as HTMLElement | null) top += n.offsetTop
  root.scrollTo({ top: top - 12 })
  el.classList.remove('bb-flash')
  void el.offsetWidth
  el.classList.add('bb-flash')
  tocPane.value?.querySelector('.toc-item.active')?.scrollIntoView({ block: 'nearest' })
}

watch(() => props.target, (t) => { if (t !== current.value || !html.value) void go(t, false) }, { immediate: true })

function switchLang() {
  readLang.value = readLang.value === 'zh' ? 'en' : 'zh'
  html.value = ''
  void go(current.value, false)
}

function onClick(e: MouseEvent) {
  const a = (e.target as HTMLElement).closest('a[data-ref]')
  if (!a) return
  e.preventDefault()
  void go(a.getAttribute('data-ref'))
}

// The chapter a toc entry belongs to stays open; its sections are listed.
const subsections = (id: string) =>
  chapters.value.find((c) => c.id === id)?.sections.filter((s) => s.level === 3) ?? []
</script>

<template>
  <div class="reader" :style="bookStyle">
    <nav ref="tocPane" class="toc">
      <div class="toc-head">
        <div class="toc-book">{{ t('book.reader.title') }}</div>
        <div class="toc-sub">{{ t('book.reader.subtitle') }}</div>
        <NButton size="tiny" secondary class="toc-lang" @click="switchLang">
          <template #icon><NIcon :component="LanguageOutline" /></template>
          {{ readLang === lang.locale ? t('book.reader.other_lang') : t('book.reader.this_lang') }}
        </NButton>
      </div>
      <template v-for="c in chapters" :key="c.id">
        <div v-if="c.part" class="toc-part">{{ c.part }}</div>
        <a href="#" class="toc-item toc-chapter" :class="{ active: c.id === current, open: c.id === chapterId }"
           @click.prevent="go(c.id)">{{ c.title }}</a>
        <template v-if="c.id === chapterId">
          <a v-for="s in subsections(c.id)" :key="s.id" href="#" class="toc-item toc-section"
             :class="{ active: s.id === current }" @click.prevent="go(s.id)">{{ s.title }}</a>
        </template>
      </template>
    </nav>
    <div ref="pane" class="page">
      <NSpin v-if="loading && !html" size="small" class="reader-spin" />
      <div v-else-if="failed" class="reader-empty">{{ t('book.drawer.failed') }}</div>
      <template v-else>
        <!-- Generated from the bundled book by scripts/beambook/extract.py, which keeps only plain markup. -->
        <article class="bb-content" @click="onClick" v-html="html" />
        <div class="pager">
          <NButton v-if="prev" quaternary size="small" @click="go(prev.id)">
            <template #icon><NIcon :component="ChevronBackOutline" /></template>
            {{ prev.title }}
          </NButton>
          <span />
          <NButton v-if="next" quaternary size="small" icon-placement="right" @click="go(next.id)">
            <template #icon><NIcon :component="ChevronForwardOutline" /></template>
            {{ next.title }}
          </NButton>
        </div>
        <p class="credit">{{ t('book.credit') }}</p>
      </template>
    </div>
  </div>
</template>

<style scoped>
.reader {
  display: flex;
  height: 100%;
  min-height: 0;
}
.toc {
  flex: 0 0 260px;
  overflow-y: auto;
  border-right: 1px solid var(--bb-border);
  padding: 4px 12px 24px 4px;
  font-size: 13px;
}
.toc-head {
  padding: 4px 8px 12px;
  margin-bottom: 6px;
  border-bottom: 1px solid var(--bb-border);
}
.toc-book {
  font-weight: 700;
  font-size: 15px;
}
.toc-sub {
  font-size: 12px;
  color: var(--bb-muted);
  margin: 2px 0 8px;
}
.toc-part {
  font-size: 11.5px;
  font-weight: 600;
  color: var(--bb-muted);
  padding: 12px 8px 4px;
}
.toc-item {
  display: block;
  padding: 4px 8px;
  border-radius: 6px;
  color: var(--bb-text);
  text-decoration: none;
  line-height: 1.45;
}
.toc-item:hover {
  background: var(--bb-code-bg);
}
.toc-chapter.open {
  font-weight: 600;
}
.toc-section {
  padding-left: 20px;
  font-size: 12.5px;
  color: var(--bb-muted);
}
.toc-item.active {
  color: var(--bb-accent);
  background: var(--bb-callout-bg);
}
.page {
  position: relative;
  flex: 1;
  min-width: 0;
  overflow-y: auto;
  padding: 4px 28px 24px;
}
.page .bb-content {
  max-width: 820px;
}
.pager {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  max-width: 820px;
  margin-top: 24px;
  padding-top: 12px;
  border-top: 1px solid var(--bb-border);
}
.credit {
  max-width: 820px;
  font-size: 12px;
  color: var(--bb-muted);
  margin-top: 16px;
}
.reader-spin {
  display: block;
  margin: 80px auto;
}
.reader-empty {
  padding: 40px;
  color: var(--bb-muted);
}
@media (max-width: 760px) {
  .toc { display: none; }
  .page { padding: 4px 8px 24px; }
}
</style>
