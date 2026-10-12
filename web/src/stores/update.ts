import { defineStore } from 'pinia'
import { computed, ref, watch } from 'vue'
import { useSettings } from './settings'

// Checks GitHub for a newer release. The desktop app can download and
// install it in place (see electron/preload.js); the browser UI and the
// desktop builds that can't update themselves link to the release page.
interface UpdateInfo { current?: string; version: string; url: string; notes: string; auto: boolean }
interface DesktopBridge {
  platform: string
  update: {
    check: () => Promise<UpdateInfo>
    download: () => Promise<boolean>
    install: () => Promise<boolean>
    onProgress: (cb: (percent: number) => void) => () => void
  }
}
declare global {
  interface Window { eobsDesktop?: DesktopBridge }
}

const RELEASES_API = 'https://api.github.com/repos/qinbaixi/EObserver/releases/latest'
const CHECK_EVERY_MS = 6 * 60 * 60 * 1000

export type UpdateState = 'idle' | 'checking' | 'latest' | 'available' | 'downloading' | 'ready' | 'error'

// -1 / 0 / 1 for a < b, a == b, a > b ("0.0.10" > "0.0.9"; "1.0.0-rc" < "1.0.0").
export function compareVersions(a: string, b: string): number {
  const parse = (v: string) => {
    const [core, pre] = v.replace(/^v/, '').split('-', 2)
    return { nums: core.split('.').map((n) => parseInt(n, 10) || 0), pre }
  }
  const x = parse(a)
  const y = parse(b)
  for (let i = 0; i < Math.max(x.nums.length, y.nums.length); i++) {
    const d = (x.nums[i] ?? 0) - (y.nums[i] ?? 0)
    if (d) return Math.sign(d)
  }
  if (x.pre === y.pre) return 0
  if (!x.pre) return 1
  if (!y.pre) return -1
  return x.pre < y.pre ? -1 : 1
}

export const useUpdate = defineStore('update', () => {
  const settings = useSettings()
  const desktop = window.eobsDesktop
  const state = ref<UpdateState>('idle')
  const info = ref<UpdateInfo | null>(null)
  const progress = ref(0)
  const error = ref('')
  const current = computed(() => info.value?.current ?? settings.version)
  const canInstall = computed(() => Boolean(info.value?.auto))

  desktop?.update.onProgress((p) => { progress.value = p })

  async function fetchLatest(): Promise<UpdateInfo> {
    if (desktop) return desktop.update.check()
    const res = await fetch(RELEASES_API, { headers: { Accept: 'application/vnd.github+json' } })
    if (!res.ok) throw new Error(`GitHub 返回 ${res.status}`)
    const r = await res.json()
    return { version: String(r.tag_name).replace(/^v/, ''), url: r.html_url, notes: r.body ?? '', auto: false }
  }

  async function check() {
    if (state.value === 'checking' || state.value === 'downloading' || state.value === 'ready') return
    state.value = 'checking'
    error.value = ''
    try {
      const latest = await fetchLatest()
      info.value = latest
      state.value = current.value && compareVersions(latest.version, current.value) > 0 ? 'available' : 'latest'
    } catch (e) {
      error.value = (e as Error).message
      state.value = 'error'
    }
  }

  async function download() {
    if (!desktop || !canInstall.value) return
    state.value = 'downloading'
    progress.value = 0
    try {
      await desktop.update.download()
      state.value = 'ready'
    } catch (e) {
      error.value = (e as Error).message
      state.value = 'error'
    }
  }

  async function install() {
    await desktop?.update.install()
  }

  function openRelease() {
    window.open(info.value?.url ?? 'https://github.com/qinbaixi/EObserver/releases/latest', '_blank')
  }

  // First check once the backend has told us its version, then periodically.
  let timer: ReturnType<typeof setInterval> | undefined
  watch(() => settings.version, (v) => {
    if (!v || timer) return
    void check()
    timer = setInterval(() => {
      if (state.value === 'idle' || state.value === 'latest' || state.value === 'error') void check()
    }, CHECK_EVERY_MS)
  }, { immediate: true })

  return { state, info, progress, error, current, canInstall, check, download, install, openRelease }
})
