// Starts a packaged desktop app in smoke mode (see EOBS_SMOKE_RESULT in
// electron/main.js), waits for it to report that the UI rendered, and exits
// with its result. Used by the release workflow:
//   node scripts/desktop-smoke.mjs <app executable> [app args...]
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const [exe, ...args] = process.argv.slice(2)
if (!exe) {
  console.error('usage: node scripts/desktop-smoke.mjs <app executable> [args...]')
  process.exit(2)
}
const resultFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'eobs-smoke-')), 'result.json')
console.log(`starting ${exe} ${args.join(' ')}`)
const child = spawn(exe, args, {
  env: { ...process.env, EOBS_SMOKE_RESULT: resultFile },
  stdio: ['ignore', 'inherit', 'inherit'],
})

const timer = setTimeout(() => {
  console.error('desktop smoke test FAILED: no result within 120 s')
  child.kill()
  process.exit(1)
}, 120000)

child.on('error', (err) => {
  console.error(`desktop smoke test FAILED: ${err.message}`)
  process.exit(1)
})
child.on('exit', (code) => {
  clearTimeout(timer)
  if (!fs.existsSync(resultFile)) {
    console.error(`desktop smoke test FAILED: app exited with code ${code} without a result`)
    process.exit(1)
  }
  const result = JSON.parse(fs.readFileSync(resultFile, 'utf8'))
  console.log(`--- backend output ---\n${result.log}\n---`)
  if (!result.ok) {
    console.error(`desktop smoke test FAILED: ${result.error}`)
    process.exit(1)
  }
  console.log(`desktop smoke test passed: UI rendered from ${result.url}`)
})
