// Turns backend error reasons (atoms or printed terms) into Chinese text.
const TEXTS: Record<string, string> = {
  not_found: '对象已不存在',
  not_observed: '该节点不在观察列表中',
  not_running: '目标已不在运行',
  timeout: '目标节点响应超时',
  read_only: '只读模式下不允许此操作',
  private: '这是 private 表，只有所属进程能读取',
  cookie_not_found: '保存的 cookie 已被删除，请重新选择',
  empty_cookie: 'cookie 不能为空',
  crashed: '请求处理时出错',
  internal_error: '服务内部错误',
  unsupported: '目标节点的 OTP 版本不支持此操作',
  no_holder: '这个 socket 没有所属进程',
  noconnection: '与目标节点的连接已断开',
  badarg: '参数无效',
  invalid_term: '无法解析输入的 Erlang 项，请检查语法',
  protected: '这是 protected 表，只有所属进程能写入',
  bad_object: '记录必须是一个元组，且长度不小于键的位置',
  bad_record: '记录名或字段数与 Mnesia 表的定义不一致',
  aborted: 'Mnesia 事务被中止',
  busy: '这个节点上已经有一次诊断在进行，请稍后再试',
  too_many_processes: '进程超过 50 万个，为保护目标节点不做区间统计',
  too_big: '数据量太大，为保护目标节点已中止',
}

export function errorText(e: unknown): string {
  const msg = e instanceof Error ? e.message : String(e)
  if (TEXTS[msg]) return TEXTS[msg]
  for (const [key, text] of Object.entries(TEXTS)) {
    if (new RegExp(`\\b${key}\\b`).test(msg)) return `${text}（${msg}）`
  }
  return msg
}
