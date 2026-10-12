import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { client } from '../api/ws'
import type { NodeInfo } from '../api/types'

const CURRENT_KEY = 'eobs.currentNode'

function loadCurrent(): string | null {
  try {
    return localStorage.getItem(CURRENT_KEY)
  } catch {
    return null
  }
}

export const useNodes = defineStore('nodes', () => {
  const nodes = ref<Record<string, NodeInfo>>({})
  const current = ref<string | null>(loadCurrent())
  const loaded = ref(false)

  const list = computed(() => Object.values(nodes.value).sort((a, b) => a.node.localeCompare(b.node)))
  const currentInfo = computed(() => (current.value ? nodes.value[current.value] ?? null : null))

  function select(node: string | null) {
    current.value = node
    try {
      if (node) localStorage.setItem(CURRENT_KEY, node)
      else localStorage.removeItem(CURRENT_KEY)
    } catch {
      /* storage unavailable */
    }
  }

  async function refresh() {
    const result = await client.request<NodeInfo[]>('nodes.list')
    nodes.value = Object.fromEntries(result.map((n) => [n.node, n]))
    loaded.value = true
    if (!current.value || !nodes.value[current.value]) select(list.value[0]?.node ?? null)
  }

  // cookie: nodes.connect parameters from useCookies().params()
  async function connect(node: string, cookie: Record<string, string>) {
    await client.request('nodes.connect', { node, ...cookie })
    await refresh()
    select(node)
  }

  async function disconnect(node: string) {
    await client.request('nodes.disconnect', { node })
    delete nodes.value[node]
    if (current.value === node) select(list.value[0]?.node ?? null)
  }

  client.on('socket_open', () => void refresh())
  client.on('node_status', (info: NodeInfo) => {
    nodes.value[info.node] = info
    if (!current.value) select(info.node)
  })
  client.on('node_removed', ({ node }: { node: string }) => {
    delete nodes.value[node]
    if (current.value === node) select(list.value[0]?.node ?? null)
  })

  return { nodes, list, current, currentInfo, loaded, select, refresh, connect, disconnect }
})
