// EObserver desktop: starts the bundled EObserver release on a free
// localhost port and shows its web UI in a window.
const { app, BrowserWindow, shell, dialog, ipcMain, net: enet } = require('electron')
const { spawn, execFile, execFileSync } = require('node:child_process')
const path = require('node:path')
const fs = require('node:fs')
const net = require('node:net')

const isWin = process.platform === 'win32'
let child = null
let win = null
let quitting = false
const log = []
// EOBS_SMOKE_RESULT=<file>: start, check that the UI rendered, write the
// outcome to <file> as JSON and quit. Used by the release workflow to test
// the packaged app on every platform before publishing.
const smokeFile = process.env.EOBS_SMOKE_RESULT

function releaseDir() {
  return app.isPackaged
    ? path.join(process.resourcesPath, 'eobserver')
    : path.join(__dirname, '..', '_build', 'default', 'rel', 'eobserver')
}

// A stable port keeps the UI's origin, and with it the saved theme and
// last node, across launches; fall back to any free port.
const PREFERRED_PORT = 18090

function portFree(port) {
  return new Promise((resolve) => {
    const srv = net.createServer()
    srv.once('error', () => resolve(false))
    srv.listen(port, '127.0.0.1', () => srv.close(() => resolve(true)))
  })
}

async function startBackend() {
  const port = (await portFree(PREFERRED_PORT)) ? PREFERRED_PORT : 0
  return launch(port)
}

function launch(port) {
  const dir = releaseDir()
  const bin = path.join(dir, 'bin', isWin ? 'eobs.cmd' : 'eobs')
  if (!fs.existsSync(bin)) {
    return Promise.reject(new Error(`EObserver release not found at ${dir}. Run \`make release\` first.`))
  }
  const args = ['--port', String(port), '--no-browser']
  child = isWin
    // Same quoting as Node's shell option: cmd /s strips the outer quotes.
    ? spawn('cmd.exe', ['/d', '/s', '/c', `""${bin}" ${args.join(' ')}"`], { windowsHide: true, windowsVerbatimArguments: true })
    : spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] })

  return new Promise((resolve, reject) => {
    let out = ''
    const onData = (chunk) => {
      const text = chunk.toString()
      log.push(text)
      out += text
      const m = /running at (http:\/\/\S+)/.exec(out)
      if (m) resolve(m[1])
    }
    child.stdout.on('data', onData)
    child.stderr.on('data', (c) => log.push(c.toString()))
    child.on('error', reject)
    child.on('exit', (code) => {
      child = null
      if (!quitting) {
        reject(new Error(`EObserver exited with code ${code}`))
        if (win) showError(new Error(`EObserver stopped unexpectedly (exit code ${code}).`))
      }
    })
    setTimeout(() => reject(new Error('EObserver did not start within 60 seconds')), 60000)
  })
}

function stopBackend({ wait = false } = {}) {
  quitting = true
  if (!child) return
  if (isWin) {
    // cmd.exe -> erl.exe: kill the whole tree. The installer can only
    // replace the files once erl.exe has exited, hence `wait`.
    const args = ['/pid', String(child.pid), '/t', '/f']
    if (wait) {
      try { execFileSync('taskkill', args, { windowsHide: true }) } catch { /* already gone */ }
    } else {
      execFile('taskkill', args, () => {})
    }
  } else {
    child.kill('SIGTERM')
  }
}

function showError(err) {
  const details = log.join('').slice(-4000)
  const html = fs.readFileSync(path.join(__dirname, 'pages', 'error.html'), 'utf8')
    .replace('{{message}}', escapeHtml(err.message))
    .replace('{{log}}', escapeHtml(details || '(no output)'))
  win?.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html))
}

function escapeHtml(s) {
  return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]))
}

async function createWindow() {
  win = new BrowserWindow({
    width: 1440,
    height: 920,
    minWidth: 960,
    minHeight: 600,
    title: 'EObserver',
    show: !smokeFile,
    backgroundColor: '#1C1E23',
    autoHideMenuBar: true,
    webPreferences: { contextIsolation: true, sandbox: true, preload: path.join(__dirname, 'preload.js') },
  })
  win.on('closed', () => { win = null })
  // Links to other sites open in the system browser.
  win.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url)
    return { action: 'deny' }
  })
  let origin = null
  win.webContents.on('will-navigate', (e, target) => {
    if (origin && target.startsWith(origin)) return
    e.preventDefault()
    if (/^https?:/.test(target)) void shell.openExternal(target)
  })
  await win.loadFile(path.join(__dirname, 'pages', 'loading.html'))
  try {
    const url = await startBackend()
    origin = new URL(url).origin
    await win.loadURL(url)
    if (smokeFile) await smokeCheck(url)
  } catch (err) {
    if (smokeFile) smokeDone({ ok: false, error: err.message })
    showError(err)
  }
}

async function smokeCheck(url) {
  // The Vue app mounts into #app; give it a moment to render.
  for (let i = 0; i < 40; i++) {
    const n = await win.webContents.executeJavaScript(
      "document.querySelector('#app')?.childElementCount ?? 0")
    if (n > 0) return smokeDone({ ok: true, url })
    await new Promise((r) => setTimeout(r, 250))
  }
  smokeDone({ ok: false, url, error: 'UI did not render' })
}

function smokeDone(result) {
  fs.writeFileSync(smokeFile, JSON.stringify({ ...result, log: log.join('') }, null, 2))
  // app.exit skips before-quit, so stop the backend here.
  stopBackend()
  setTimeout(() => app.exit(result.ok ? 0 : 1), 1000)
}

// Updates. electron-updater replaces the app in place where it can: the
// Windows installer build and the Linux AppImage. Everywhere else (macOS,
// which needs a signed app, and the zip / tar.gz builds) the UI links to
// the release page instead.
const RELEASES_API = 'https://api.github.com/repos/qinbaixi/EObserver/releases/latest'
let updater = null

function canSelfUpdate() {
  if (!app.isPackaged && !process.env.EOBS_UPDATE_URL) return false
  if (process.platform === 'linux') return Boolean(process.env.APPIMAGE)
  if (isWin) return fs.existsSync(path.join(path.dirname(process.execPath), 'Uninstall EObserver.exe'))
  return false
}

function getUpdater() {
  if (updater) return updater
  const { autoUpdater } = require('electron-updater')
  autoUpdater.autoDownload = false
  autoUpdater.autoInstallOnAppQuit = true
  autoUpdater.logger = { info: (m) => log.push(`[update] ${m}\n`), warn: (m) => log.push(`[update] ${m}\n`),
    error: (m) => log.push(`[update] ${m}\n`), debug: () => {} }
  // EOBS_UPDATE_URL=<dir url>: read latest*.yml from there instead of
  // GitHub, to test updating against a local server.
  if (process.env.EOBS_UPDATE_URL) {
    autoUpdater.forceDevUpdateConfig = !app.isPackaged
    autoUpdater.setFeedURL({ provider: 'generic', url: process.env.EOBS_UPDATE_URL })
  }
  autoUpdater.on('download-progress', (p) => win?.webContents.send('update:progress', p.percent))
  updater = autoUpdater
  return updater
}

async function latestRelease() {
  const res = await enet.fetch(RELEASES_API, { headers: { Accept: 'application/vnd.github+json' } })
  if (!res.ok) throw new Error(`GitHub 返回 ${res.status}`)
  const r = await res.json()
  return { version: String(r.tag_name).replace(/^v/, ''), url: r.html_url, notes: r.body ?? '' }
}

function registerUpdateIpc() {
  ipcMain.handle('update:check', async () => {
    const current = app.getVersion()
    if (canSelfUpdate()) {
      const result = await getUpdater().checkForUpdates()
      const info = result?.updateInfo
      const version = info?.version ?? current
      const notes = typeof info?.releaseNotes === 'string' ? info.releaseNotes : ''
      return { current, version, auto: true, url: `https://github.com/qinbaixi/EObserver/releases/tag/v${version}`, notes }
    }
    return { current, auto: false, ...(await latestRelease()) }
  })
  ipcMain.handle('update:download', async () => {
    await getUpdater().downloadUpdate()
    return true
  })
  ipcMain.handle('update:install', () => {
    stopBackend({ wait: true })
    // isSilent = false shows the installer's progress on Windows;
    // isForceRunAfter = true starts the new version afterwards.
    setImmediate(() => getUpdater().quitAndInstall(false, true))
    return true
  })
}

if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  app.on('second-instance', () => {
    if (win) {
      if (win.isMinimized()) win.restore()
      win.focus()
    }
  })
  registerUpdateIpc()
  app.whenReady().then(createWindow).catch((err) => {
    dialog.showErrorBox('EObserver', String(err))
    app.quit()
  })
  app.on('window-all-closed', () => app.quit())
  app.on('before-quit', stopBackend)
}
