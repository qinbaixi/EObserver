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
| 界面 | wxWidgets 桌面窗口 | 任意浏览器或桌面版，支持深色/浅色主题和中英文 |
| 目标节点的依赖 | `runtime_tools` | 无；连接时加载一个小的采集模块，断开时卸载 |
| 大进程表 | 把整张表拉到本机 | 排序、过滤、分页都在目标节点完成，只传当前页 |
| 可见性 | 以普通节点身份连接 | 以**隐藏节点**身份连接，不会出现在目标节点的 `nodes()` 中 |
| 多节点 | 一次只能看一个 | 可以同时连接多个节点，随时切换 |

## 功能

- **本机节点**：列出本机 epmd 上注册的所有节点，勾选后一次连接。用过的 cookie 会被记住（保存在用户配置目录，只有你自己能读），下次从列表里选，不用再粘贴；在 cookie 选择框旁边可以改名或删除。
- **节点管理**：用已保存的 cookie 添加的节点，下次启动 EObserver 时自动重连。节点菜单里可以移除单个节点、所有未连接的节点或全部节点，移除时会卸载采集模块并真正断开分布式连接。
- **总览墙**：所有已连接节点在一屏里显示内存、进程数、运行队列和最近 10 分钟趋势，有问题的节点标黄或标红并写明原因。
- **系统概览**：OTP/ERTS 版本、调度器与线程、内存分布、进程/端口/原子/ETS 上限的使用率，以及运行统计。
- **负载图表**：调度器利用率（平均值，加上各调度器热力图，64 核以上也看得清）、内存堆叠图、IO 吞吐、运行队列、reductions。切换页面后历史数据仍然保留。「对比」模式把多个节点的同一指标画在一张图上。
- **诊断**：一键健康体检，检查进程/端口/原子/ETS 上限占比、消息队列堆积、内存大户、大 ETS 表、binary 占比、运行队列、疑似卡住的进程、持有大量 binary 的进程和分布式发送队列，红黄绿显示并给出建议。
- **Recon 工具箱**：[recon](https://github.com/ferd/recon) 风格的工具直接内置在采集模块里，目标节点不需要装 recon 库：进程排行（按内存、reductions、消息队列、堆或 binary 取 Top N）、区间排行（N 秒内增长最快的进程）、binary 泄漏检查（对每个进程做一次 GC，看谁释放的 refc binary 最多）、网络排行（按字节数或包数排出最忙的 socket，可取快照或统计一段时间）、端口类型统计、分配器碎片（各实例使用率、缓存命中率、平均块大小、sbcs/mbcs）以及 N 秒内的调度器利用率。所有工具都是手动触发、有上限，同一节点一次只运行一个。
- **日志**：崩溃记录（同类崩溃合并计数、supervisor 重启统计）和实时日志（级别筛选、模块和关键字搜索、导出）。只在页面打开期间采集，离开页面 60 秒后或断开连接时自动撤掉。
- **进程**：可排序、可搜索、可分页的进程表。*Reds* 列是距上次刷新的 reductions 增量，方便找出当前最忙的进程。详情抽屉里可以查看 links/monitors（点击跳转）、消息、进程字典、调用栈、`sys:get_state`，也可以发送消息或 kill 进程；列表每行和右键菜单里也能直接 kill。
- **消息跟踪**：选最多 10 个进程，实时查看它们收到和发出的消息，自动分成业务（调用、投递、回复、普通消息）、系统（EXIT、DOWN、sys、io、定时器等）和网络三类，gen call 的调用和回复自动配对并显示耗时。速率、条数、时长和内存都有硬上限，超限自动停止，不会拖垮目标节点。
  - **调用统计**：按请求类型汇总 `gen_server:call` 的次数、平均、P95、最大耗时和未回复次数，在目标节点上计数，界面丢消息也不影响准确性。
  - **时序图**：选几个进程，按时间顺序画出它们之间的消息。
  - **跟踪文件**：跟踪记录可以保存成文件，以后不连接节点也能打开查看。
- **应用**：列出所有运行中的应用及其监督树，点击任意节点查看进程详情。
- **端口与 Socket**：所有端口及其所属进程、IO 与队列；`gen_tcp`/`gen_udp` 的地址与统计；`socket` 模块创建的 socket。
- **表**：ETS 与 Mnesia 表列表，以及在目标节点上分页、搜索的记录查看器，大表也不会拖垮节点。可以打开记录查看完整内容，也可以编辑、添加和删除记录（Mnesia 的修改在事务中执行；包含 pid、引用、fun 的记录只能查看和删除）。
- **内存分配器**：各分配器的块与载体大小、利用率和历史曲线，用来发现内存碎片。
- **集群拓扑**：已观察节点之间的分布式连接，点击相邻节点即可连接它。
- **崩溃转储**：打开 `erl_crash.dump`（对标 OTP 自带的 crashdump_viewer），不用连接任何节点，完全在本机解析。几 G 的文件也能打开：先扫描一遍建立索引，再按需读取，2 GB 的文件在缓存命中时几秒就能扫完，扫描期间可以先看概要。打开后默认进入诊断概要，把崩溃原因翻译成白话（内存耗尽、kernel 进程退出、系统上限、主动 halt 等）并给出排查建议，自动列出疑点（垃圾回收中的进程、内存大户、消息堆积、接近上限的资源、大 ETS 表等），每条都能点进去看明细。进程、端口、ETS、定时器、调度器、节点、内存与分配器、模块、fun、原子、persistent_term 等都有可排序、可筛选、服务端分页的表格；进程详情包括消息队列、进程字典、调用栈和堆数据还原，pid 之间可点击跳转。被截断的转储也能打开，并标出缺失的部分。
- **命令面板**：<kbd>Ctrl</kbd>+<kbd>K</kbd> / <kbd>⌘</kbd>+<kbd>K</kbd> 搜索并跳转到页面、节点、进程、表和应用，也能直接开始体检、连接节点、切换主题和语言。
- **中英文界面**：默认跟随系统语言，顶栏可以切换中文 / English。主题可以跟随系统，也可以固定为浅色或深色。
- **可分享链接**：节点以及打开的进程、端口、表、应用都会写进 URL。
- **应用内更新**：自动检查 GitHub 上的新版本；Windows 安装版和 Linux AppImage 可以直接下载并安装更新，其他版本会打开下载页。

<table>
  <tr>
    <td><img src="docs/images/overview-wall.png" alt="所有已连接节点的总览墙" /></td>
    <td><img src="docs/images/diagnosis.png" alt="诊断：健康体检" /></td>
  </tr>
  <tr>
    <td><img src="docs/images/recon.png" alt="Recon 工具箱" /></td>
    <td><img src="docs/images/trace-sequence.png" alt="消息跟踪时序图" /></td>
  </tr>
  <tr>
    <td><img src="docs/images/processes.png" alt="进程" /></td>
    <td><img src="docs/images/process-detail.png" alt="进程详情" /></td>
  </tr>
  <tr>
    <td><img src="docs/images/logs.png" alt="崩溃记录与实时日志" /></td>
    <td><img src="docs/images/system.png" alt="系统概览" /></td>
  </tr>
  <tr>
    <td><img src="docs/images/applications-dark.png" alt="监督树" /></td>
    <td><img src="docs/images/table-rows.png" alt="Mnesia 表记录" /></td>
  </tr>
  <tr>
    <td><img src="docs/images/allocators-dark.png" alt="内存分配器" /></td>
    <td><img src="docs/images/command-palette.png" alt="命令面板" /></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><img src="docs/images/connect-local.png" alt="本机节点" width="60%" /></td>
  </tr>
</table>

## 安装

从 [Releases](https://github.com/qinbaixi/EObserver/releases) 下载最新版本：

- **桌面版**（Linux AppImage、macOS dmg、Windows 安装包）：一个独立窗口，不需要安装其他东西。
- **命令行版**（`eobserver-cli-<版本>-<平台>.tar.gz` / `.zip`）：解压后运行 `bin/eobs`（Windows 上是 `bin\eobs.cmd`），会自动打开浏览器，适合在服务器上使用。

两种都自带 Erlang 运行时。目前还没有代码签名，macOS 和 Windows 首次打开的步骤见发布说明。

## 从源码构建

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
| `--password PASS` | 访问密码（HTTP Basic 认证，用户名任意），也可以用环境变量 `EOBS_PASSWORD`。配合 `--listen` 使用 |
| `--read-only` | 只读模式：禁止 kill 进程、发送消息、关闭端口、修改表记录、消息跟踪和二进制泄漏检查 |
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

### 从源码运行桌面版

```sh
make release
cd electron && npm ci && npm start          # 运行
npx electron-builder --publish never        # 打包当前平台
```

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
electron/              包装 release 的桌面应用
test/                  eunit 和 Common Test 测试
```

WebSocket 协议见 [docs/protocol.md](docs/protocol.md)。

## 路线图

- [x] 连接管理、隐藏节点、采集模块注入、界面框架
- [x] 系统概览与负载图表
- [x] 进程页（目标端排序、过滤、分页）
- [x] 应用与监督树
- [x] 端口与 Socket
- [x] ETS 与 Mnesia 表浏览
- [x] 内存分配器
- [x] 集群拓扑、可分享链接、访问控制、按 OTP 版本预编译的采集模块
- [x] Linux、macOS、Windows 的命令行版与桌面版发布包
- [x] 桌面版应用内更新
- [x] 节点管理、ETS / Mnesia 记录编辑
- [x] 消息跟踪（收发消息，按业务 / 系统分类）
- [x] 调用耗时统计、时序图、跟踪文件
- [x] 诊断（健康体检）与日志（崩溃记录、实时日志）
- [x] 总览墙、跨节点对比图表、命令面板、英文界面
- [x] 内置在采集模块中的 Recon 工具箱
- [ ] 代码签名、macOS Intel 与 Linux arm64 构建

## 参与贡献

欢迎贡献！请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，并遵守[行为准则](CODE_OF_CONDUCT.md)。安全问题请参见 [SECURITY.md](SECURITY.md)。

## 许可证

Copyright 2026 the EObserver authors.

基于 [Apache License 2.0](LICENSE) 发布，与 Erlang/OTP 使用相同的许可证。
