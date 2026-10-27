import { watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useNodes } from '../stores/nodes'
import { useUi } from '../stores/ui'

// Keeps ?node= in the URL in step with the selected node. Opening a link
// for a node that is not observed yet offers to connect to it.
export function useUrlSync() {
  const route = useRoute()
  const router = useRouter()
  const nodes = useNodes()
  const ui = useUi()
  const offered = new Set<string>()

  watch([() => nodes.loaded, () => route.query.node], ([loaded, q]) => {
    if (!loaded || typeof q !== 'string' || !q || q === nodes.current) return
    if (nodes.nodes[q]) {
      nodes.select(q)
    } else if (!offered.has(q)) {
      offered.add(q)
      // With no nodes yet the welcome panel already shows the form.
      if (nodes.list.length) ui.openConnect(q)
      else ui.connectNode = q
    }
  }, { immediate: true })

  watch([() => nodes.loaded, () => nodes.current, () => route.fullPath], ([loaded, cur], [, old]) => {
    // Until the first navigation finishes (a lazily loaded page such as the
    // crash dump viewer or the book) the route is still the start location,
    // and replacing its query would send the app to / instead.
    if (!loaded || !route.matched.length) return
    const q = route.query.node
    if (typeof q === 'string' && q && !nodes.nodes[q] && !offered.has(q)) return
    if ((cur ?? undefined) === q) return
    // Switching nodes drops page state such as an open pid, which belongs
    // to the previous node.
    const query = old && cur !== old ? {} : { ...route.query }
    if (cur) query.node = cur
    else delete query.node
    void router.replace({ query })
  })
}
