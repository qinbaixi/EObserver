<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { NDrawer, NDrawerContent, NButton, NIcon, NTag, NSpin, NSpace } from 'naive-ui'
import { ArrowBackOutline, BookOutline } from '@vicons/ionicons5'
import { useI18n } from 'vue-i18n'
import { useKnowledge } from '../stores/knowledge'
import { useLocale } from '../stores/locale'
import { loadCards, relatedCards, withImages, type CardSection } from '../beambook'
import { useBookStyle } from '../beambook/useBookStyle'

// The knowledge card for a term: its short explanation, the opening of the
// matching BEAM Book sections, related cards, and links into the reader.
const { t } = useI18n()
const k = useKnowledge()
const lang = useLocale()
const bookStyle = useBookStyle()

const card = computed(() => k.stack[k.stack.length - 1])
const sections = ref<CardSection[] | null>(null)
const failed = ref(false)

watch([card, () => lang.locale, () => k.open], async ([id, l, open]) => {
  if (!open || !id) return
  failed.value = false
  sections.value = null
  try {
    const cards = await loadCards(l)
    if (card.value === id && lang.locale === l) sections.value = cards[id] ?? []
  } catch {
    failed.value = true
  }
}, { immediate: true })

// The term shown above the excerpts only belongs to the first card.
const from = computed(() => (k.stack.length === 1 ? k.from : null))
const related = computed(() => (card.value ? relatedCards(card.value) : []))

const body = ref<HTMLElement | null>(null)
watch(card, () => { body.value?.closest('.n-scrollbar-container')?.scrollTo({ top: 0 }) })

// Links inside an excerpt go to the reader at their target.
function onClick(e: MouseEvent) {
  const a = (e.target as HTMLElement).closest('a[data-ref]')
  if (!a) return
  e.preventDefault()
  k.openBook(a.getAttribute('data-ref'))
}
</script>

<template>
  <NDrawer v-model:show="k.open" :width="560" placement="right" :auto-focus="false">
    <NDrawerContent closable :native-scrollbar="false" body-content-class="kd-body">
      <template #header>
        <div class="kd-header">
          <NButton v-if="k.stack.length > 1" quaternary circle size="small" :title="t('book.drawer.back')" @click="k.back()">
            <template #icon><NIcon :component="ArrowBackOutline" /></template>
          </NButton>
          <span class="kd-kicker">{{ t('book.drawer.title') }}</span>
          <span class="kd-title">{{ card ? t(`book.cards.${card}`) : '' }}</span>
        </div>
      </template>

      <div ref="body" :style="bookStyle">
        <div v-if="from && (from.label !== t(`book.cards.${card}`) || from.tip)" class="kd-term">
          <div class="kd-term-label">{{ from.label }}</div>
          <div v-if="from.tip" class="kd-term-tip">{{ from.tip }}</div>
        </div>

        <div v-if="failed" class="kd-empty">{{ t('book.drawer.failed') }}</div>
        <NSpin v-else-if="!sections" size="small" class="kd-spin" />
        <template v-else>
          <div class="kd-section-label">{{ t('book.drawer.from_book') }}</div>
          <section v-for="s in sections" :key="s.id" class="kd-section">
            <a class="kd-section-title" href="#" @click.prevent="k.openBook(s.id)">{{ s.title }}</a>
            <!-- Generated from the bundled book by scripts/beambook/extract.py, which keeps only plain markup. -->
            <div class="bb-content" @click="onClick" v-html="withImages(s.html)" />
            <a v-if="s.more" class="kd-more" href="#" @click.prevent="k.openBook(s.id)">{{ t('book.drawer.read_more') }} →</a>
          </section>
        </template>

        <div v-if="related.length" class="kd-related">
          <div class="kd-section-label">{{ t('book.drawer.related') }}</div>
          <NSpace :size="6">
            <NTag v-for="r in related" :key="r" size="small" round class="kd-tag" @click="k.showCard(r)">
              {{ t(`book.cards.${r}`) }}
            </NTag>
          </NSpace>
        </div>
      </div>

      <template #footer>
        <div class="kd-footer">
          <span class="kd-credit">{{ t('book.credit') }}</span>
          <NButton size="small" secondary type="primary" @click="k.openBook(sections?.[0]?.id ?? null)">
            <template #icon><NIcon :component="BookOutline" /></template>
            {{ t('book.drawer.read') }}
          </NButton>
        </div>
      </template>
    </NDrawerContent>
  </NDrawer>
</template>

<style scoped>
.kd-header {
  display: flex;
  align-items: baseline;
  gap: 10px;
  min-width: 0;
}
.kd-header .n-button {
  align-self: center;
}
.kd-kicker {
  font-size: 12px;
  font-weight: 500;
  opacity: 0.55;
  white-space: nowrap;
}
.kd-title {
  font-size: 17px;
  font-weight: 650;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.kd-term {
  padding: 10px 12px;
  margin-bottom: 18px;
  border-radius: 8px;
  background: var(--bb-callout-bg);
  border: 1px solid var(--bb-border);
}
.kd-term-label {
  font-weight: 600;
  margin-bottom: 2px;
}
.kd-term-tip {
  font-size: 13px;
  line-height: 1.6;
  color: var(--bb-text);
}
.kd-section-label {
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.4px;
  text-transform: uppercase;
  color: var(--bb-muted);
  margin: 0 0 10px;
}
.kd-section {
  margin-bottom: 22px;
}
.kd-section-title {
  display: inline-block;
  font-size: 15px;
  font-weight: 650;
  margin-bottom: 6px;
  color: inherit;
  text-decoration: none;
}
.kd-section-title:hover {
  color: var(--bb-accent);
}
.kd-more {
  font-size: 13px;
  color: var(--bb-accent);
  text-decoration: none;
}
.kd-related {
  margin-top: 8px;
  padding-top: 16px;
  border-top: 1px solid var(--bb-border);
}
.kd-tag {
  cursor: pointer;
}
.kd-spin {
  display: block;
  margin: 40px auto;
}
.kd-empty {
  padding: 24px 0;
  color: var(--bb-muted);
}
.kd-footer {
  display: flex;
  align-items: center;
  gap: 12px;
  width: 100%;
}
.kd-credit {
  flex: 1;
  font-size: 11.5px;
  line-height: 1.5;
  opacity: 0.6;
}
</style>
