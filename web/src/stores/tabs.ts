import { defineStore } from 'pinia'
import { ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useNodes } from './nodes'

// Node tabs: each tab observes one node and remembers the page it was on.
// Only the active tab's node is the current node, so pages subscribe to it
// alone and background tabs cost the target nodes nothing.

export interface NodeTab {
  id: string
  node: string
  // The tab's last route (path + query, with ?node=).
  path: string
}

const KEY = 'eobs.tabs'
// Drag data type of a node dragged out of the node switcher.
export const NODE_MIME = 'application/x-eobs-node'

interface Saved {
  tabs: NodeTab[]
  active: string | null
}

function load(): Saved {
  try {
    const s = JSON.parse(localStorage.getItem(KEY) ?? 'null') as Saved | null
    if (s && Array.isArray(s.tabs)) {
      return { tabs: s.tabs.filter((t) => t && typeof t.node === 'string' && typeof t.id === 'string'), active: s.active }
    }
  } catch {
    /* storage unavailable or corrupt */
  }
  return { tabs: [], active: null }
}

export const useTabs = defineStore('tabs', () => {
  const saved = load()
  const tabs = ref<NodeTab[]>(saved.tabs)
  const active = ref<string | null>(saved.active)
  let seq = tabs.value.reduce((m, t) => Math.max(m, Number(t.id.slice(1)) || 0), 0)
  let wired = false

  function save() {
    try {
      localStorage.setItem(KEY, JSON.stringify({ tabs: tabs.value, active: active.value }))
    } catch {
      /* storage unavailable */
    }
  }

  const activeTab = () => tabs.value.find((t) => t.id === active.value) ?? null

  // Called once from the layout, where the router is available.
  function wire() {
    if (wired) return
    wired = true
    const nodes = useNodes()
    const route = useRoute()
    const router = useRouter()

    const withNode = (fullPath: string, node: string) => {
      const r = router.resolve(fullPath)
      return router.resolve({ path: r.path, query: { ...r.query, node } }).fullPath
    }

    function activate(id: string) {
      const tab = tabs.value.find((t) => t.id === id)
      if (!tab) return
      active.value = id
      save()
      // The URL sync selects the node from ?node= once the route changes;
      // selecting it here first would rewrite the old page's URL instead.
      if (route.fullPath !== tab.path) void router.push(tab.path)
      else nodes.select(tab.node)
    }

    // A new tab for node, on the page the current tab shows (without its
    // page state, which belongs to the other node).
    function open(node: string, after: string | null = active.value) {
      const id = `t${++seq}`
      const path = route.matched.length && route.name !== 'crashdump' && route.name !== 'book'
        ? withNode(route.path, node)
        : withNode('/system', node)
      const at = tabs.value.findIndex((t) => t.id === after)
      tabs.value.splice(at < 0 ? tabs.value.length : at + 1, 0, { id, node, path })
      activate(id)
    }

    function close(ids: string[]) {
      if (!ids.length) return
      const gone = new Set(ids)
      const idx = tabs.value.findIndex((t) => t.id === active.value)
      tabs.value = tabs.value.filter((t) => !gone.has(t.id))
      if (active.value && gone.has(active.value)) {
        active.value = null
        const next = tabs.value[Math.min(Math.max(idx, 0), tabs.value.length - 1)]
        if (next) activate(next.id)
      }
      save()
    }

    function move(id: string, before: string | null) {
      const from = tabs.value.findIndex((t) => t.id === id)
      if (from < 0 || id === before) return
      const [tab] = tabs.value.splice(from, 1)
      const to = before ? tabs.value.findIndex((t) => t.id === before) : -1
      tabs.value.splice(to < 0 ? tabs.value.length : to, 0, tab)
      save()
    }

    // Removing a node closes its tabs (before the current-node watch below
    // would hand the closing tab to whichever node the store picks next).
    watch(() => nodes.loaded && nodes.list.map((n) => n.node).join('\n'), (keys) => {
      if (keys === false) return
      const known = new Set(nodes.list.map((n) => n.node))
      close(tabs.value.filter((t) => !known.has(t.node)).map((t) => t.id))
    }, { immediate: true })

    // The node switcher, the palette and ?node= links change the current
    // tab's node; a node with no tab yet gets the first one.
    watch(() => nodes.current, (cur) => {
      if (!cur) return
      const tab = activeTab()
      if (tab) {
        if (tab.node !== cur) {
          tab.node = cur
          tab.path = withNode(route.fullPath, cur)
          save()
        }
      } else {
        const id = `t${++seq}`
        tabs.value.push({ id, node: cur, path: withNode(route.fullPath, cur) })
        active.value = id
        save()
      }
    }, { immediate: true })

    // Remember where each tab is.
    watch(() => route.fullPath, (path) => {
      const tab = activeTab()
      if (!tab || !route.matched.length) return
      const q = route.query.node
      if (q === undefined || q === tab.node) {
        tab.path = q === undefined ? withNode(path, tab.node) : path
        save()
      }
    })

    Object.assign(api, { activate, open, close, move })
  }

  const api = {
    activate: (_id: string) => {},
    open: (_node: string, _after?: string | null) => {},
    close: (_ids: string[]) => {},
    move: (_id: string, _before: string | null) => {},
  }

  return {
    tabs, active, wire,
    activate: (id: string) => api.activate(id),
    open: (node: string, after?: string | null) => api.open(node, after),
    close: (ids: string[]) => api.close(ids),
    move: (id: string, before: string | null) => api.move(id, before),
  }
})
