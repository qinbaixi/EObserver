// WebSocket client for the EObserver backend. Requests return promises,
// subscriptions survive reconnects, and backend events fan out to listeners.
import { ref } from 'vue'
import { i18n } from '../i18n'

const t = (key: string) => i18n.global.t(`shell.ws.${key}`)

type Json = any // eslint-disable-line @typescript-eslint/no-explicit-any

interface Pending {
  resolve: (v: Json) => void
  reject: (e: Error) => void
  timer: number
}

interface Subscription {
  topic: string
  params: Json
  interval: number
  onData: (data: Json) => void
  onError?: (err: string) => void
}

export type SocketState = 'connecting' | 'open' | 'closed'

class Client {
  readonly state = ref<SocketState>('connecting')
  private ws?: WebSocket
  private nextId = 1
  private pending = new Map<number, Pending>()
  private subs = new Map<string, Subscription>()
  private listeners = new Map<string, Set<(data: Json) => void>>()
  private retry = 500
  private retryTimer?: number

  connect() {
    if (this.retryTimer) {
      clearTimeout(this.retryTimer)
      this.retryTimer = undefined
    }
    const prev = this.ws
    const proto = location.protocol === 'https:' ? 'wss' : 'ws'
    const ws = new WebSocket(`${proto}://${location.host}/ws`)
    this.ws = ws
    if (prev && prev.readyState <= WebSocket.OPEN) {
      try { prev.close() } catch { /* ignore */ }
    }
    this.state.value = 'connecting'
    // The server drops a socket it has not heard from for 120 s, which a
    // page that only listens (the overview wall) would otherwise hit.
    let keepalive = 0
    ws.onopen = () => {
      if (this.ws !== ws) return
      this.state.value = 'open'
      this.retry = 500
      keepalive = window.setInterval(() => this.send({ type: 'ping' }), 30000)
      for (const [id, sub] of this.subs) this.sendSub(id, sub)
      this.emit('socket_open', null)
    }
    ws.onmessage = (ev) => {
      if (this.ws !== ws) return
      let msg: Json
      try {
        msg = JSON.parse(ev.data)
      } catch {
        return
      }
      this.onMessage(msg)
    }
    ws.onclose = () => {
      clearInterval(keepalive)
      if (this.ws !== ws) return
      this.state.value = 'closed'
      for (const [, p] of this.pending) {
        clearTimeout(p.timer)
        p.reject(new Error(t('closed')))
      }
      this.pending.clear()
      this.retryTimer = window.setTimeout(() => this.connect(), this.retry)
      this.retry = Math.min(this.retry * 2, 8000)
    }
  }

  request<T = Json>(method: string, params: Json = {}, timeout = 20000): Promise<T> {
    return new Promise((resolve, reject) => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
        reject(new Error(t('not_connected')))
        return
      }
      const id = this.nextId++
      const timer = window.setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(t('timeout')))
      }, timeout)
      this.pending.set(id, { resolve, reject, timer })
      try {
        this.ws.send(JSON.stringify({ type: 'req', id, method, params }))
      } catch (e) {
        clearTimeout(timer)
        this.pending.delete(id)
        reject(e instanceof Error ? e : new Error(String(e)))
      }
    })
  }

  subscribe(topic: string, params: Json, interval: number,
            onData: (d: Json) => void, onError?: (e: string) => void): () => void {
    const id = `s${this.nextId++}`
    const sub = { topic, params, interval, onData, onError }
    this.subs.set(id, sub)
    this.sendSub(id, sub)
    return () => {
      this.subs.delete(id)
      this.send({ type: 'unsub', id })
    }
  }

  on(event: string, fn: (data: Json) => void): () => void {
    if (!this.listeners.has(event)) this.listeners.set(event, new Set())
    this.listeners.get(event)!.add(fn)
    return () => this.listeners.get(event)?.delete(fn)
  }

  private sendSub(id: string, s: Subscription) {
    this.send({ type: 'sub', id, topic: s.topic, params: s.params, interval: s.interval })
  }

  private send(msg: Json) {
    if (this.ws?.readyState !== WebSocket.OPEN) return
    try {
      this.ws.send(JSON.stringify(msg))
    } catch {
      /* socket closing; onclose will handle reconnect */
    }
  }

  private emit(event: string, data: Json) {
    const set = this.listeners.get(event)
    if (!set) return
    for (const fn of [...set]) {
      try { fn(data) } catch (e) { console.error(`ws event handler (${event}) failed`, e) }
    }
  }

  private onMessage(msg: Json) {
    switch (msg.type) {
      case 'resp': {
        const p = this.pending.get(msg.id)
        if (!p) return
        this.pending.delete(msg.id)
        clearTimeout(p.timer)
        if (msg.ok) p.resolve(msg.result)
        else p.reject(new Error(msg.error))
        break
      }
      case 'push': {
        const s = this.subs.get(msg.id)
        if (!s) return
        if (msg.ok) s.onData(msg.data)
        else s.onError?.(msg.error)
        break
      }
      case 'event':
        this.emit(msg.event, msg.data)
        break
    }
  }
}

export const client = new Client()
