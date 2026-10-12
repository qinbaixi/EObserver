# EObserver

一个更美观的 Erlang 节点观察工具，用来替代 OTP 自带的 `observer`。界面运行在浏览器里，后端是一个 Erlang 隐藏节点。

- **随连随用**：用节点名和 cookie 连接，目标节点不需要预装任何代码。EObserver 以隐藏节点身份连接，不会出现在目标节点的 `nodes()` 里。
- **对生产节点友好**：连接时临时加载一个小的采集模块 `eobs_agent`，排序、过滤、分页都在目标节点本地完成；断开时卸载。
- **多节点**：可以同时观察多个节点并随时切换。
- **深色/浅色主题**。

目标节点支持 OTP 22 及以上；EObserver 本身用 OTP 26 构建。

## 使用

```sh
make release
_build/default/rel/eobserver/bin/eobs --node app@myhost --cookie secret
```

启动后会自动打开浏览器（默认 http://localhost:8090/）。也可以不带参数启动，在页面里添加节点。

| 参数 | 说明 |
|---|---|
| `--node NAME@HOST` | 启动后立即连接的节点 |
| `--cookie COOKIE` | 该节点的 cookie，不填则用 `~/.erlang.cookie` |
| `--port 8090` | 网页端口 |
| `--listen 127.0.0.1` | 监听地址。默认只监听本机，因为页面可以操作目标节点 |
| `--no-browser` | 不自动打开浏览器 |

短节点名（`app@host`）和长节点名（`app@host.example.com`）会自动识别，但同一次运行中只能用其中一种。

## 开发

需要 OTP 26、rebar3 和 Node 22。

```sh
make web          # 构建前端到 apps/eobserver/priv/www
make test         # eunit + common test（会启动真实的目标节点）
make shell        # 启动后端（端口 8090）
cd web && npm run dev   # 前端热更新，/ws 代理到 8090
```

目录结构：

```
apps/eobserver/        工具节点：连接管理、HTTP/WebSocket、API
apps/eobserver_agent/  注入到目标节点的采集模块（只能用 OTP 22 已有的 API）
web/                   Vue 3 + TypeScript + Naive UI + ECharts 前端
```

## 进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | 骨架、连接、采集模块注入、界面框架、系统概览 | ✅ |
| M1 | System 完整信息 + Load Charts | ✅ |
| M2 | Processes | ✅ |
| M3 | Applications / supervisor 树 | ✅ |
| M4 | Ports + Sockets | ⏳ |
| M5 | ETS / Mnesia 表浏览 | ⏳ |
| M6 | Memory Allocators | ⏳ |
| M7 | 集群拓扑、可分享链接、访问控制、多版本 agent、发布 | ⏳ |

Trace 相关功能暂不在计划内。
