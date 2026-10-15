<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { NAlert } from 'naive-ui'
import { useNodes } from '../stores/nodes'
import { useLoad, MAX_PEERS } from '../stores/load'
import PageHeader from '../components/PageHeader.vue'
import RefreshControl from '../components/RefreshControl.vue'
import NodeCard from '../components/overview/NodeCard.vue'

// The overview wall: one card per observed node. The load store samples
// every connected node in the background (up to MAX_PEERS) until paused
// here; with more nodes than that, the cards on screen are sampled too.
const { t } = useI18n()
const router = useRouter()
const nodes = useNodes()
const load = useLoad()

const limited = computed(() => nodes.list.length > MAX_PEERS)
const visible = reactive(new Set<string>())
const grid = ref<HTMLElement | null>(null)
let observer: IntersectionObserver | null = null

load.useSampling('overview', () => {
  if (!limited.value || load.paused) return []
  return nodes.list.map((n) => n.node).filter((n) => visible.has(n)).slice(0, MAX_PEERS)
}, true)

// Watches the cards only when sampling has to be limited to them.
function observe() {
  observer?.disconnect()
  observer = null
  visible.clear()
  if (!limited.value || !grid.value) return
  observer = new IntersectionObserver((entries) => {
    for (const e of entries) {
      const n = (e.target as HTMLElement).dataset.node
      if (!n) continue
      if (e.isIntersecting) visible.add(n)
      else visible.delete(n)
    }
  }, { rootMargin: '200px 0px' })
  for (const el of grid.value.querySelectorAll<HTMLElement>('[data-node]')) observer.observe(el)
}

watch(() => nodes.list.map((n) => n.node).join('\n'), () => void nextTick(observe))
onMounted(observe)
onBeforeUnmount(() => observer?.disconnect())

// useUrlSync selects the node from the query; selecting it here as well
// would race its own router.replace and cancel the navigation.
function open(node: string) {
  void router.push({ name: 'system', query: { node } })
}
</script>

<template>
  <PageHeader :title="t('overview.title')" :subtitle="t('overview.subtitle', { n: nodes.list.length })">
    <RefreshControl v-model:paused="load.paused" v-model:interval="load.peerInterval" @refresh="load.refresh" />
  </PageHeader>
  <p class="hint">{{ t('overview.hint') }}</p>
  <NAlert v-if="limited" type="info" :show-icon="false" style="margin-bottom: 16px">
    {{ t('overview.limited', { max: MAX_PEERS }) }}
  </NAlert>
  <div ref="grid" class="wall">
    <div v-for="n in nodes.list" :key="n.node" :data-node="n.node" class="cell">
      <NodeCard :node="n.node" @open="open" />
    </div>
  </div>
</template>

<style scoped>
.hint {
  margin: -8px 0 16px;
  font-size: 13px;
  opacity: 0.6;
}
.wall {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(300px, 100%), 1fr));
  gap: 16px;
}
.cell {
  display: flex;
  min-width: 0;
}
.cell > * {
  flex: 1;
}
</style>
