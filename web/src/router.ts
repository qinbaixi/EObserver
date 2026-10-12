import { createRouter, createWebHistory } from 'vue-router'
import type { Component } from 'vue'
import {
  SpeedometerOutline, PulseOutline, HardwareChipOutline, AppsOutline,
  GitNetworkOutline, SwapHorizontalOutline, WifiOutline, GridOutline,
} from '@vicons/ionicons5'
import SystemPage from './pages/SystemPage.vue'
import ComingSoon from './pages/ComingSoon.vue'
import LoadPage from './pages/LoadPage.vue'
import ProcessesPage from './pages/ProcessesPage.vue'

export interface PageMeta {
  title: string
  subtitle: string
  icon: Component
  milestone?: string
}

export const pages: { path: string; name: string; meta: PageMeta }[] = [
  { path: '/system', name: 'system', meta: { title: '系统概览', subtitle: 'System', icon: SpeedometerOutline } },
  { path: '/load', name: 'load', meta: { title: '负载图表', subtitle: 'Load Charts', icon: PulseOutline } },
  { path: '/allocators', name: 'allocators', meta: { title: '内存分配器', subtitle: 'Memory Allocators', icon: HardwareChipOutline, milestone: 'M6' } },
  { path: '/applications', name: 'applications', meta: { title: '应用', subtitle: 'Applications', icon: AppsOutline, milestone: 'M3' } },
  { path: '/processes', name: 'processes', meta: { title: '进程', subtitle: 'Processes', icon: GitNetworkOutline } },
  { path: '/ports', name: 'ports', meta: { title: '端口', subtitle: 'Ports', icon: SwapHorizontalOutline, milestone: 'M4' } },
  { path: '/sockets', name: 'sockets', meta: { title: 'Sockets', subtitle: 'Sockets', icon: WifiOutline, milestone: 'M4' } },
  { path: '/tables', name: 'tables', meta: { title: '表', subtitle: 'ETS / Mnesia', icon: GridOutline, milestone: 'M5' } },
]

const components: Record<string, Component> = {
  system: SystemPage, load: LoadPage, processes: ProcessesPage,
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
