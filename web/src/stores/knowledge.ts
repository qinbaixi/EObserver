import { defineStore } from 'pinia'
import { ref } from 'vue'

// The knowledge card drawer and the BEAM Book reader (components/KnowledgeDrawer
// and BookModal, mounted once in AppLayout).
export const useKnowledge = defineStore('knowledge', () => {
  const open = ref(false)
  // Cards visited since the drawer opened; the last one is shown.
  const stack = ref<string[]>([])
  // The term that opened the first card, shown above its excerpts.
  const from = ref<{ label: string; tip?: string } | null>(null)
  const readerOpen = ref(false)
  // A section or other anchor id in the book; null opens at the start.
  const readerTarget = ref<string | null>(null)

  function openCard(id: string, term?: { label: string; tip?: string }) {
    stack.value = [id]
    from.value = term ?? null
    open.value = true
  }

  function showCard(id: string) {
    if (stack.value[stack.value.length - 1] !== id) stack.value.push(id)
  }

  function back() {
    if (stack.value.length > 1) stack.value.pop()
  }

  function openBook(target: string | null = null) {
    readerTarget.value = target
    readerOpen.value = true
  }

  return { open, stack, from, readerOpen, readerTarget, openCard, showCard, back, openBook }
})
