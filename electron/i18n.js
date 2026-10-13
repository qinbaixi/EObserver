// Texts of the desktop shell (loading / error pages, startup errors) in
// the web UI's languages. The UI tells the main process its language over
// IPC (preload.js `setLocale`); until it has, the saved choice or the
// system language is used.
const fs = require('node:fs')
const path = require('node:path')

const TEXTS = {
  zh: {
    lang: 'zh-CN',
    starting: '正在启动 EObserver…',
    failed: 'EObserver 无法启动',
    report: '请把以上输出附在 {issue} 中。',
    noOutput: '（没有输出）',
    notFound: '在 {dir} 找不到 EObserver 发行包，请先运行 `make release`。',
    exited: 'EObserver 已退出，退出码 {code}',
    stopped: 'EObserver 意外停止（退出码 {code}）。',
    startTimeout: 'EObserver 在 60 秒内没有启动',
    github: 'GitHub 返回 {status}',
  },
  en: {
    lang: 'en',
    starting: 'Starting EObserver…',
    failed: 'EObserver could not start',
    report: 'Please attach the output above to a {issue}.',
    noOutput: '(no output)',
    notFound: 'EObserver release not found at {dir}. Run `make release` first.',
    exited: 'EObserver exited with code {code}',
    stopped: 'EObserver stopped unexpectedly (exit code {code}).',
    startTimeout: 'EObserver did not start within 60 seconds',
    github: 'GitHub returned {status}',
  },
}

let locale = null

function file(app) {
  return path.join(app.getPath('userData'), 'locale.json')
}

// Call once the app is ready (app.getLocale needs it).
function initLocale(app) {
  try {
    const saved = JSON.parse(fs.readFileSync(file(app), 'utf8')).locale
    if (TEXTS[saved]) locale = saved
  } catch {
    /* not saved yet */
  }
  if (!locale) locale = /^zh\b/i.test(app.getLocale()) ? 'zh' : 'en'
}

function setLocale(app, l) {
  if (!TEXTS[l] || l === locale) return
  locale = l
  try {
    fs.mkdirSync(path.dirname(file(app)), { recursive: true })
    fs.writeFileSync(file(app), JSON.stringify({ locale: l }))
  } catch {
    /* keep it for this run only */
  }
}

function tr(key, vars = {}) {
  const text = TEXTS[locale ?? 'en'][key]
  return text.replace(/\{(\w+)\}/g, (m, k) => (k in vars ? String(vars[k]) : m))
}

module.exports = { initLocale, setLocale, tr }
