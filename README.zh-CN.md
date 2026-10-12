<div align="center">

<img src="web/public/favicon.svg" width="72" alt="EObserver logo" />

# EObserver

**现代化、基于浏览器的 Erlang/OTP 节点观察工具。**

用来替代 OTP 自带的 `observer`，界面更美观。只要有节点名和 cookie 就能连接正在运行的节点，目标节点不需要安装任何东西。

[![CI](https://github.com/qinbaixi/EObserver/actions/workflows/ci.yml/badge.svg)](https://github.com/qinbaixi/EObserver/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Erlang/OTP](https://img.shields.io/badge/target-OTP%2022%2B-A90533.svg)](#兼容性)

[English](README.md) | 简体中文

</div>

![负载图表](docs/images/load-charts-dark.png)

## 为什么做 EObserver

OTP 的 `observer` 很好用，但它基于 wxWidgets，有几个痛点：需要在装了 wx 的机器上开桌面窗口，界面比较陈旧，在几十万进程的节点上会变卡。EObserver 沿用相同的使用习惯，解决了这些问题。

| | OTP `observer` | EObserver |
|---|---|---|
| 界面 | wxWidgets 桌面窗口 | 任意浏览器，支持深色/浅色主题 |
| 目标节点的依赖 | `runtime_tools` | 无；连接时加载一个小的采集模块，断开时卸载 |
| 大进程表 | 把整张表拉到本机 | 排序、过滤、分页都在目标节点完成，只传当前页 |
| 可见性 | 以普通节点身份连接 | 以**隐藏节点**身份连接，不会出现在目标节点的 `nodes()` 中 |
| 多节点 | 一次只能看一个 | 可以同时连接多个节点，随时切换 |

## 功能

- **系统概览**：OTP/ERTS 版本、调度器与线程、内存分布、进程/端口/原子/ETS 上限的使用率，以及运行统计。
- **负载图表**：调度器利用率（平均值，加上各调度器热力图，64 核以上也看得清）、内存堆叠图、IO 吞吐、运行队列、reductions。切换页面后历史数据仍然保留。
- **进程**：可排序、可搜索、可分页的进程表。*Reds* 列是距上次刷新的 reductions 增量，方便找出当前最忙的进程。详情抽屉里可以查看 links/monitors（点击跳转）、消息、进程字典、调用栈、`sys:get_state`，也可以发送消息或 kill 进程。
- **应用**：列出所有运行中的应用及其监督树，点击任意节点查看进程详情。
- 即将推出：端口与 Socket、ETS/Mnesia 表浏览、内存分配器。详见[路线图](#路线图)。

<table>
  <tr>
    <td><img src="docs/images/processes.png" alt="进程" /></td>
    <td><img src="docs/images/process-detail.png" alt="进程详情" /></td>
  </tr>
  <tr>
    <td><img src="docs/images/system.png" alt="系统概览" /></td>
    <td><img src="docs/images/applications-dark.png" alt="监督树" /></td>
  </tr>
</table>

## 快速开始

构建 EObserver 需要 **Erlang/OTP 26**、**rebar3** 和 **Node.js 22**。

```sh
git clone https://github.com/qinbaixi/EObserver.git
cd EObserver
make release
_build/default/rel/eobserver/bin/eobs --node myapp@myhost --cookie secret
```

启动后会自动打开浏览器访问 <http://localhost:8090/>。也可以不带 `--node` 启动，然后在页面里添加节点。

### 命令行参数

| 参数 | 说明 |
|---|---|
| `--node NAME@HOST` | 启动后立即连接的节点 |
| `--cookie COOKIE` | 该节点的 cookie，不填则使用 `~/.erlang.cookie` |
| `--port 8090` | 网页端口 |
| `--listen 127.0.0.1` | 监听地址。默认只监听本机，因为页面可以 kill 目标节点上的进程 |
| `--no-browser` | 不自动打开浏览器 |

短节点名（`app@host`）和长节点名（`app@host.example.com`）会自动识别，但同一个 EObserver 实例只能使用其中一种。

## 工作原理

```
 浏览器（Vue 3 + Naive UI + ECharts）
        │  WebSocket（JSON）
        ▼
 EObserver 工具节点（隐藏节点，Cowboy）
        │  Erlang 分布式（erpc）
        ▼
 目标节点 ── eobs_agent（连接时加载，断开时卸载）
```

1. 工具启动时没有节点名。知道要连接的目标后，它按目标使用的短名或长名，以隐藏节点身份启动分布式。
2. 连接时用 `code:load_binary/3` 加载 `eobs_agent`。采集模块只使用 OTP 22 已有的 kernel/stdlib 接口，所以目标节点不需要额外的应用。
3. 浏览器只订阅当前屏幕上需要的数据。每个订阅都在工具节点上的独立进程里采集，一个慢节点不会拖累其他节点；上一轮采集还没结束时会跳过这一轮。

在 20 万进程的节点上实测：进程表每次刷新约 0.25 秒；按内存排序或带过滤条件时约 1 秒。

## 兼容性

| | 版本 |
|---|---|
| 目标节点 | OTP 22 及以上 |
| 构建 EObserver | OTP 26 |
| 浏览器 | 最新版 Chrome、Edge、Firefox、Safari |

## 开发

```sh
make web                 # 构建前端到 apps/eobserver/priv/www
make test                # eunit + Common Test（会启动真实的 peer 节点）
make shell               # 启动后端，端口 8090
cd web && npm run dev    # 前端热更新，/ws 代理到 8090
```

```
apps/eobserver/        工具节点：连接管理、HTTP/WebSocket、API
apps/eobserver_agent/  加载到目标节点的采集模块（兼容 OTP 22）
web/                   Vue 3 + TypeScript + Naive UI + ECharts 前端
test/                  eunit 和 Common Test 测试
```

WebSocket 协议见 [docs/protocol.md](docs/protocol.md)。

## 路线图

- [x] 连接管理、隐藏节点、采集模块注入、界面框架
- [x] 系统概览与负载图表
- [x] 进程页（目标端排序、过滤、分页）
- [x] 应用与监督树
- [ ] 端口与 Socket
- [ ] ETS 与 Mnesia 表浏览
- [ ] 内存分配器
- [ ] 集群拓扑、可分享链接、访问控制、按 OTP 版本预编译的采集模块、发布包
- Trace 相关功能暂不在计划内。

## 参与贡献

欢迎贡献！请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，并遵守[行为准则](CODE_OF_CONDUCT.md)。安全问题请参见 [SECURITY.md](SECURITY.md)。

## 许可证

Copyright 2026 the EObserver authors.

基于 [Apache License 2.0](LICENSE) 发布，与 Erlang/OTP 使用相同的许可证。
