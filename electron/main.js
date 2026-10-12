// EObserver desktop: starts the bundled EObserver release on a free
// localhost port and shows its web UI in a window.
const { app, BrowserWindow, shell, dialog } = require('electron')
const { spawn, execFile } = require('node:child_process')
const path = require('node:path')
const fs = require('node:fs')
const net = require('node:net')

const isWin = process.platform === 'win32'
let child = null
let win = null
let quitting = false
const log = []

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

function stopBackend() {
  quitting = true
  if (!child) return
  if (isWin) {
    // cmd.exe -> erl.exe: kill the whole tree.
    execFile('taskkill', ['/pid', String(child.pid), '/t', '/f'], () => {})
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
    backgroundColor: '#101014',
    autoHideMenuBar: true,
    webPreferences: { contextIsolation: true, sandbox: true },
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
  } catch (err) {
    showError(err)
  }
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
  app.whenReady().then(createWindow).catch((err) => {
    dialog.showErrorBox('EObserver', String(err))
    app.quit()
  })
  app.on('window-all-closed', () => app.quit())
  app.on('before-quit', stopBackend)
}
