import { createRouter, createWebHistory } from 'vue-router'
import type { Component } from 'vue'
import {
  SpeedometerOutline, PulseOutline, HardwareChipOutline, AppsOutline,
  GitNetworkOutline, SwapHorizontalOutline, WifiOutline, GridOutline, ShareSocialOutline,
  ChatbubblesOutline, MedkitOutline,
} from '@vicons/ionicons5'
import SystemPage from './pages/SystemPage.vue'
import ComingSoon from './pages/ComingSoon.vue'
import LoadPage from './pages/LoadPage.vue'
import ProcessesPage from './pages/ProcessesPage.vue'
import TracePage from './pages/TracePage.vue'
import DiagnosisPage from './pages/DiagnosisPage.vue'
import ApplicationsPage from './pages/ApplicationsPage.vue'
import PortsPage from './pages/PortsPage.vue'
import SocketsPage from './pages/SocketsPage.vue'
import TablesPage from './pages/TablesPage.vue'
import AllocatorsPage from './pages/AllocatorsPage.vue'
import ClusterPage from './pages/ClusterPage.vue'

export interface PageMeta {
  title: string
  subtitle: string
  icon: Component
  milestone?: string
}

export const pages: { path: string; name: string; meta: PageMeta }[] = [
  { path: '/system', name: 'system', meta: { title: '系统概览', subtitle: 'System', icon: SpeedometerOutline } },
  { path: '/load', name: 'load', meta: { title: '负载图表', subtitle: 'Load Charts', icon: PulseOutline } },
  { path: '/allocators', name: 'allocators', meta: { title: '内存分配器', subtitle: 'Memory Allocators', icon: HardwareChipOutline } },
  { path: '/applications', name: 'applications', meta: { title: '应用', subtitle: 'Applications', icon: AppsOutline } },
  { path: '/diagnosis', name: 'diagnosis', meta: { title: '诊断', subtitle: 'Diagnosis', icon: MedkitOutline } },
  { path: '/processes', name: 'processes', meta: { title: '进程', subtitle: 'Processes', icon: GitNetworkOutline } },
  { path: '/trace', name: 'trace', meta: { title: '消息跟踪', subtitle: 'Message Trace', icon: ChatbubblesOutline } },
  { path: '/ports', name: 'ports', meta: { title: '端口', subtitle: 'Ports', icon: SwapHorizontalOutline } },
  { path: '/sockets', name: 'sockets', meta: { title: 'Sockets', subtitle: 'Sockets', icon: WifiOutline } },
  { path: '/tables', name: 'tables', meta: { title: '表', subtitle: 'ETS / Mnesia', icon: GridOutline } },
  { path: '/cluster', name: 'cluster', meta: { title: '集群拓扑', subtitle: 'Cluster', icon: ShareSocialOutline } },
]

const components: Record<string, Component> = {
  system: SystemPage, load: LoadPage, processes: ProcessesPage, trace: TracePage, diagnosis: DiagnosisPage, applications: ApplicationsPage,
  ports: PortsPage, sockets: SocketsPage, tables: TablesPage, allocators: AllocatorsPage, cluster: ClusterPage,
}

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', redirect: '/system' },
    ...pages.map((p) => ({
      path: p.path,
      name: p.name,
      meta: { page: p.meta },
      component: components[p.name] ?? ComingSoon,
    })),
    { path: '/:pathMatch(.*)*', redirect: '/system' },
  ],
})
