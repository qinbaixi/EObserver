import { createRouter, createWebHistory, type RouteComponent } from 'vue-router'
import type { Component } from 'vue'
import {
  SpeedometerOutline, PulseOutline, HardwareChipOutline, AppsOutline,
  GitNetworkOutline, SwapHorizontalOutline, WifiOutline, GridOutline, ShareSocialOutline,
  ChatbubblesOutline, MedkitOutline, AlbumsOutline, DocumentTextOutline, ConstructOutline, BugOutline,
  LibraryOutline,
} from '@vicons/ionicons5'
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
  { path: '/recon', name: 'recon', meta: meta('recon', ConstructOutline) },
  { path: '/logs', name: 'logs', meta: meta('logs', DocumentTextOutline) },
  { path: '/processes', name: 'processes', meta: meta('processes', GitNetworkOutline) },
  { path: '/trace', name: 'trace', meta: meta('trace', ChatbubblesOutline) },
  { path: '/ports', name: 'ports', meta: meta('ports', SwapHorizontalOutline) },
  { path: '/sockets', name: 'sockets', meta: meta('sockets', WifiOutline) },
  { path: '/tables', name: 'tables', meta: meta('tables', GridOutline) },
  { path: '/cluster', name: 'cluster', meta: meta('cluster', ShareSocialOutline) },
  // Reads a crash dump file on the EObserver machine; needs no node.
  { path: '/crashdump', name: 'crashdump', meta: meta('crashdump', BugOutline) },
  // The bundled BEAM Book; needs no node either.
  { path: '/book', name: 'book', meta: meta('book', LibraryOutline) },
]

// All pages are code-split so initial boot only fetches the active route.
const components: Record<string, () => Promise<RouteComponent>> = {
  overview: () => import('./pages/OverviewPage.vue').then((m) => m.default),
  system: () => import('./pages/SystemPage.vue').then((m) => m.default),
  load: () => import('./pages/LoadPage.vue').then((m) => m.default),
  processes: () => import('./pages/ProcessesPage.vue').then((m) => m.default),
  trace: () => import('./pages/TracePage.vue').then((m) => m.default),
  diagnosis: () => import('./pages/DiagnosisPage.vue').then((m) => m.default),
  recon: () => import('./pages/ReconPage.vue').then((m) => m.default),
  logs: () => import('./pages/LogsPage.vue').then((m) => m.default),
  applications: () => import('./pages/ApplicationsPage.vue').then((m) => m.default),
  ports: () => import('./pages/PortsPage.vue').then((m) => m.default),
  sockets: () => import('./pages/SocketsPage.vue').then((m) => m.default),
  tables: () => import('./pages/TablesPage.vue').then((m) => m.default),
  allocators: () => import('./pages/AllocatorsPage.vue').then((m) => m.default),
  cluster: () => import('./pages/ClusterPage.vue').then((m) => m.default),
  crashdump: () => import('./pages/CrashDumpPage.vue').then((m) => m.default),
  book: () => import('./pages/BookPage.vue').then((m) => m.default),
}

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', redirect: '/system' },
    ...pages.map((p) => ({
      path: p.path,
      name: p.name,
      meta: { page: p.meta },
      component: components[p.name] ?? (() => import('./pages/ComingSoon.vue').then((m) => m.default)),
    })),
    { path: '/:pathMatch(.*)*', redirect: '/system' },
  ],
})
