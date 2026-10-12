import { defineStore } from 'pinia'
import { ref } from 'vue'
import { client } from '../api/ws'
import type { SavedCookie } from '../api/types'

// Which cookie to connect with: one saved on the EObserver side (the UI
// only ever sees its id and a hint), the default ~/.erlang.cookie, or a
// new one typed in now.
export type CookieChoice =
  | { kind: 'saved'; id: string }
  | { kind: 'default' }
  | { kind: 'new'; cookie: string; label: string; remember: boolean }

const CHOICE_KEY = 'eobs.cookieChoice'

export const useCookies = defineStore('cookies', () => {
  const saved = ref<SavedCookie[]>([])

  async function refresh() {
    saved.value = await client.request<SavedCookie[]>('cookies.list')
  }

  async function rename(id: string, label: string) {
    await client.request('cookies.rename', { id, label: label.trim() })
    await refresh()
  }

  async function remove(id: string) {
    await client.request('cookies.delete', { id })
    await refresh()
  }

  // Turns a choice into nodes.connect parameters, saving a new cookie
  // first when asked to.
  async function params(choice: CookieChoice): Promise<Record<string, string>> {
    if (choice.kind === 'saved') return { cookie_id: choice.id }
    if (choice.kind === 'default') return {}
    const cookie = choice.cookie.trim()
    if (!cookie) return {}
    if (!choice.remember) return { cookie }
    const { id } = await client.request<{ id: string }>('cookies.save', { cookie, label: choice.label.trim() })
    await refresh()
    rememberChoice({ kind: 'saved', id })
    return { cookie_id: id }
  }

  function lastChoice(): CookieChoice {
    try {
      const raw = localStorage.getItem(CHOICE_KEY)
      const c = raw ? JSON.parse(raw) : null
      if (c?.kind === 'saved' && saved.value.some((s) => s.id === c.id)) return c
    } catch {
      /* storage unavailable or stale */
    }
    const recent = saved.value[0]
    return recent ? { kind: 'saved', id: recent.id } : { kind: 'new', cookie: '', label: '', remember: true }
  }

  function rememberChoice(choice: CookieChoice) {
    if (choice.kind === 'new') return
    try {
      localStorage.setItem(CHOICE_KEY, JSON.stringify(choice))
    } catch {
      /* storage unavailable */
    }
  }

  return { saved, refresh, rename, remove, params, lastChoice, rememberChoice }
})
