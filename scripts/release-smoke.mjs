// Starts a built release, checks the page and a WebSocket round trip, and
// stops it. Used by the release workflow on every platform:
//   node scripts/release-smoke.mjs _build/default/rel/eobserver
import { spawn, execFileSync } from 'node:child_process'
import path from 'node:path'

const dir = path.resolve(process.argv[2] ?? '_build/default/rel/eobserver')
const isWin = process.platform === 'win32'
const bin = path.join(dir, 'bin', isWin ? 'eobs.cmd' : 'eobs')
const args = ['--port', '0', '--no-browser']
const child = isWin
  ? spawn('cmd.exe', ['/d', '/s', '/c', `""${bin}" ${args.join(' ')}"`], { windowsVerbatimArguments: true })
  : spawn(bin, args)

let output = ''
function stop() {
  if (child.exitCode !== null) return
  if (isWin) {
    try { execFileSync('taskkill', ['/pid', String(child.pid), '/t', '/f']) } catch { /* already gone */ }
  } else {
    child.kill('SIGTERM')
  }
}
function fail(msg) {
  console.error(`release smoke test FAILED: ${msg}\n--- output ---\n${output}`)
  stop()
  process.exit(1)
}

const url = await new Promise((resolve) => {
  const timer = setTimeout(() => fail('no "running at" line within 60 s'), 60000)
  const onData = (chunk) => {
    output += chunk
    const m = /running at (http:\/\/\S+)/.exec(output)
    if (m) { clearTimeout(timer); resolve(m[1]) }
  }
  child.stdout.on('data', onData)
  child.stderr.on('data', (c) => { output += c })
  child.on('exit', (code) => fail(`exited early with code ${code}`))
})
console.log(`started at ${url}`)

const page = await fetch(url).then((r) => r.text()).catch((e) => fail(String(e)))
if (!page.includes('<div id="app">')) fail('index page does not look like the UI')

const ws = new WebSocket(url.replace(/^http/, 'ws') + 'ws')
const result = await new Promise((resolve) => {
  const timer = setTimeout(() => fail('no WebSocket reply within 10 s'), 10000)
  ws.onopen = () => ws.send(JSON.stringify({ type: 'req', id: 1, method: 'settings.get', params: {} }))
  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data)
    if (msg.type === 'resp' && msg.id === 1) { clearTimeout(timer); resolve(msg) }
  }
  ws.onerror = () => fail('WebSocket error')
})
if (!result.ok) fail(`settings.get returned ${JSON.stringify(result)}`)
console.log(`settings.get -> ${JSON.stringify(result.result)}`)
ws.close()

child.removeAllListeners('exit')
stop()
console.log('release smoke test passed')
