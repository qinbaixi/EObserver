import { createRouter, createWebHistory } from 'vue-router'
import type { Component } from 'vue'
import {
  SpeedometerOutline, PulseOutline, HardwareChipOutline, AppsOutline,
  GitNetworkOutline, SwapHorizontalOutline, WifiOutline, GridOutline, ShareSocialOutline,
  ChatbubblesOutline, MedkitOutline, AlbumsOutline, DocumentTextOutline,
} from '@vicons/ionicons5'
import OverviewPage from './pages/OverviewPage.vue'
import SystemPage from './pages/SystemPage.vue'
import ComingSoon from './pages/ComingSoon.vue'
import LoadPage from './pages/LoadPage.vue'
import ProcessesPage from './pages/ProcessesPage.vue'
import TracePage from './pages/TracePage.vue'
import DiagnosisPage from './pages/DiagnosisPage.vue'
import LogsPage from './pages/LogsPage.vue'
import ApplicationsPage from './pages/ApplicationsPage.vue'
import PortsPage from './pages/PortsPage.vue'
import SocketsPage from './pages/SocketsPage.vue'
import TablesPage from './pages/TablesPage.vue'
import AllocatorsPage from './pages/AllocatorsPage.vue'
import ClusterPage from './pages/ClusterPage.vue'
import { i18n, type Locale } from './i18n'

// Titles are i18n keys (shell.nav.<name>.title / .subtitle); resolve them
// with pageTitle / pageSubtitle inside a computed or render so they follow
// the UI language.
export interface PageMeta {
  titleKey: string
  subtitleKey: string
  icon: Component
  milestone?: string
}

const meta = (name: string, icon: Component): PageMeta =>
  ({ titleKey: `shell.nav.${name}.title`, subtitleKey: `shell.nav.${name}.subtitle`, icon })

// locale: another language than the current one (e.g. for search).
export const pageTitle = (m: PageMeta, locale?: Locale) =>
  (locale ? i18n.global.t(m.titleKey, {}, { locale }) : i18n.global.t(m.titleKey))
export const pageSubtitle = (m: PageMeta) => i18n.global.t(m.subtitleKey)

export const pages: { path: string; name: string; meta: PageMeta }[] = [
  { path: '/overview', name: 'overview', meta: meta('overview', AlbumsOutline) },
  { path: '/system', name: 'system', meta: meta('system', SpeedometerOutline) },
  { path: '/load', name: 'load', meta: meta('load', PulseOutline) },
  { path: '/allocators', name: 'allocators', meta: meta('allocators', HardwareChipOutline) },
  { path: '/applications', name: 'applications', meta: meta('applications', AppsOutline) },
  { path: '/diagnosis', name: 'diagnosis', meta: meta('diagnosis', MedkitOutline) },
  { path: '/logs', name: 'logs', meta: meta('logs', DocumentTextOutline) },
  { path: '/processes', name: 'processes', meta: meta('processes', GitNetworkOutline) },
  { path: '/trace', name: 'trace', meta: meta('trace', ChatbubblesOutline) },
  { path: '/ports', name: 'ports', meta: meta('ports', SwapHorizontalOutline) },
  { path: '/sockets', name: 'sockets', meta: meta('sockets', WifiOutline) },
  { path: '/tables', name: 'tables', meta: meta('tables', GridOutline) },
  { path: '/cluster', name: 'cluster', meta: meta('cluster', ShareSocialOutline) },
]

const components: Record<string, Component> = {
  overview: OverviewPage, system: SystemPage, load: LoadPage, processes: ProcessesPage, trace: TracePage, diagnosis: DiagnosisPage, logs: LogsPage, applications: ApplicationsPage,
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
