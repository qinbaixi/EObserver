// Chinese labels for the message trace.
import type { TraceEvent } from './types'

export const KIND_LABEL: Record<string, string> = {
  call: '调用',
  cast: '投递',
  reply: '回复',
  info: '消息',
  sys: 'sys 调试',
  exit: '退出信号',
  down: '监控通知',
  io: 'IO',
  timer: '定时器',
  proc_lib: '进程启动',
  node: '节点上下线',
  ets_transfer: 'ETS 转移',
  code: '代码加载',
  tcp: 'TCP 数据',
  tcp_closed: 'TCP 关闭',
  tcp_error: 'TCP 错误',
  tcp_passive: 'TCP 被动',
  udp: 'UDP 数据',
  udp_closed: 'UDP 关闭',
  udp_error: 'UDP 错误',
  udp_passive: 'UDP 被动',
  ssl: 'SSL 数据',
  ssl_closed: 'SSL 关闭',
  ssl_error: 'SSL 错误',
  ssl_passive: 'SSL 被动',
  sctp: 'SCTP',
  http: 'HTTP 包',
  inet_reply: 'inet 回执',
  inet_async: 'inet 异步',
  $socket: 'socket',
  port: '端口',
}

export const KIND_TIP: Record<string, string> = {
  call: 'gen_server:call / gen_statem:call 的请求，显示的是请求内容（去掉了 $gen_call 外壳）。',
  cast: 'gen_server:cast 的消息，显示的是消息内容（去掉了 $gen_cast 外壳）。',
  reply: 'gen call 的回复，和对应的调用通过引用配对。',
  info: '用 ! 直接发送的普通消息。',
  sys: 'sys 模块的调试 / 管理请求，例如 sys:get_state、sys:suspend。',
  exit: '链接的进程退出时收到的 {\'EXIT\', Pid, Reason}（需要 trap_exit）。',
  down: 'erlang:monitor 监控的对象结束时收到的 {\'DOWN\', ...}。',
  io: 'IO 协议消息，例如 io:format 的输出请求。',
  timer: 'erlang:start_timer 到期的 {timeout, Ref, Msg}。',
  proc_lib: 'proc_lib 启动握手（init_ack）。',
  node: 'net_kernel:monitor_nodes 的节点上下线通知。',
  ets_transfer: 'ETS 表的所有权转移。',
  code: '代码服务器的内部协议。',
  port: '与端口（外部程序、驱动）之间的消息。',
}

export const CATEGORY_LABEL: Record<string, string> = {
  business: '业务',
  system: '系统',
  network: '网络',
}

export const STOP_REASON: Record<string, string> = {
  max_events: '已达到条数上限',
  max_seconds: '已达到时长上限',
  max_rate: '消息速率超过上限，为保护目标节点已自动停止',
  backlog: '消息太多来不及处理，为保护目标节点已自动停止',
  overload: '消息过多或过大，跟踪进程超出内存上限，已自动停止',
  stopped_by_user: '已手动停止',
  owner_down: 'EObserver 与节点断开，已停止',
  idle: '长时间没有查看，已停止',
  no_process: '没有可跟踪的进程',
  stopped: '已停止',
  crashed: '跟踪进程异常退出，已停止',
}

export const REFUSED_REASON: Record<string, string> = {
  not_found: '进程不存在',
  already_traced: '已被其他工具（如 dbg、recon）跟踪，不抢占',
  not_allowed: '这是 EObserver 自己的进程',
}

export function formatTime(us: number): string {
  const d = new Date(Math.floor(us / 1000))
  const pad = (n: number, w = 2) => String(n).padStart(w, '0')
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`
}

export function formatLatency(us: number): string {
  if (us < 1000) return `${us} µs`
  if (us < 1000000) return `${(us / 1000).toFixed(us < 10000 ? 2 : 1)} ms`
  return `${(us / 1000000).toFixed(2)} s`
}

export function peerText(e: TraceEvent): string {
  if (e.peer_name && e.peer && e.peer.startsWith('<')) return `${e.peer_name} ${e.peer}`
  return e.peer_name ?? e.peer ?? ''
}

export function eventLine(e: TraceEvent, processName: (pid: string) => string): string {
  const dir = e.dir === 'in' ? '收到' : '发出'
  const peer = peerText(e)
  return `${formatTime(e.t)} ${processName(e.pid)} ${dir} ${CATEGORY_LABEL[e.cat] ?? e.cat}/${KIND_LABEL[e.kind] ?? e.kind}`
    + `${peer ? ` ${e.dir === 'in' ? '来自' : '发给'} ${peer}` : ''}: ${e.text.replace(/\s+/g, ' ')}`
}
