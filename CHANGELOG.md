# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.0.7] - 2026-10-13

### 新增

- 消息跟踪：选最多 10 个进程，实时查看它们收到和发出的消息。
  - 每条消息自动分类：业务（调用、投递、回复、普通消息）、系统（EXIT、DOWN、sys、io、定时器等，附中文说明）、网络（tcp / udp / ssl / 端口）。
  - gen_server 的调用和回复自动配对并显示耗时；调用只显示请求内容，去掉 `$gen_call` 外壳。
  - 可以按方向、类别和关键字筛选，点开看完整内容，导出为文本。
  - 入口：左侧「消息跟踪」页、进程列表右键菜单、进程详情的「操作」页。
  - 不会拖垮目标节点：只开 send / receive 两个跟踪标志，跟踪进程有内存上限；速率超过每秒 2000 条、处理不过来、超过条数或时长上限都会自动停止并说明原因；EObserver 断开（包括被强行结束）时目标节点上的跟踪会被撤销；已被 dbg / recon 跟踪的进程不抢占。只读模式下不能开始跟踪。

### 修复

- 进程列表的右键菜单关闭时浏览器控制台报错。

## [0.0.6] - 2026-10-12

### 新增

- 节点可以移除了：节点下拉框里每一行悬停时有移除按钮，底部可以一次移除所有未连接的节点或全部节点。移除会卸载 agent 并真正断开与该节点的分布式连接。
- 节点列表会保存：用已保存的 cookie 或默认 cookie 添加的节点，下次启动 EObserver 时自动重新连接；移除后不再恢复。用未保存的 cookie 添加的节点只在本次运行中保留。
- 已保存的 cookie 可以管理：在 cookie 选择框旁边打开「管理已保存的 cookie」，可以改名、单个删除或全部删除。
- 未连接的节点页面增加「立即重试」「换个 cookie 重连」「移除节点」，不再只有连接失败时才有重试按钮。
- ETS / Mnesia 表的记录可以查看完整内容（列表里的单元格只显示前 300 个字符），并且可以编辑、添加和删除。bag 表会列出同一个键下的所有记录。包含 pid、引用、fun 的记录只能查看和删除。Mnesia 的修改在事务中执行。只读模式下隐藏这些操作。
- 记录列表可以点表头在当前页内排序。
- 进程列表可以直接杀进程：每行右侧悬停出现按钮，或者右键菜单（还可以查看详情、复制 PID）。只读模式下隐藏。
- 系统概览、内存分配器、端口、Sockets、表、集群拓扑页面都有统一的刷新间隔、暂停 / 继续和立即刷新，刷新间隔按页面记住。
- 主题可以选择「跟随系统」「浅色」「深色」，之前切换过后就回不到跟随系统。

### 修复

- 在进程详情里杀死进程后，进程列表停止自动刷新。
- 节点重连过之后再移除，之前注入的 agent 没有被卸载。
- 应用页的刷新按钮现在也会重新读取应用列表，之前只刷新监督树。
- 后端返回的错误（如 `not_found`、`timeout`、`read_only`）统一显示为中文说明。
- 进程详情 Links / Monitors 里的端口可以点击，跳到端口页并打开详情。
- 本地节点扫描的主机名可以清空，清空后回到本机主机名。

## [0.0.5] - 2026-10-12

### 改进

- 集群拓扑图改为固定的环形布局：节点按名字排在圆上，EObserver 在中间，标签朝外。每次刷新不再重新计算布局，节点不会再来回跳动，拖动和缩放也会保留，只有节点或连接变化时才重排。
- 表格的列可以拖动表头边缘调宽或调窄，包括进程、端口、Sockets、ETS / Mnesia 表、内存分配器、集群连接列表。表格内容超出窗口时，横向滚动条固定显示在屏幕底部，不用翻到表格最下面。
- Mnesia 表的「读取节点」列默认加宽。

## [0.0.4] - 2026-10-12

### 新增

- 左下角检查更新：启动时和之后每 6 小时检查 GitHub 上的最新版本，也可以手动点击检查。Windows 安装版和 Linux AppImage 可以直接下载更新并重启安装；macOS、zip / tar.gz 版和命令行版会打开下载页。从 0.0.3 及更早版本升级仍需手动下载一次，之后的版本就能在应用内更新。
- 术语悬停提示：系统、负载、进程、端口、表、内存分配器等页面里的指标名（如 Reds、Reductions、运行队列、载体）悬停时显示解释，带虚线下划线的就是有提示的。

### 改进

- 页头在窄窗口下自动换行，本机节点列表里的长节点名不再挤压端口号。
- 顶栏的节点选择框按节点名长度自适应，窗口窄时才收缩并显示省略号；下拉列表显示完整节点名。
- 调整两个主题的配色：亮色主题去掉大面积纯白，暗色主题把底色调亮一些，减少刺眼和过暗。

## [0.0.3] - 2026-10-12

### 新增

- 「添加节点」对话框新增「本机节点」页签：列出本机 epmd 上注册的所有节点，勾选后用同一个 cookie 一次连接。epmd 不记录节点名 @ 后面的主机名，可以在本机短名、完整域名、`localhost`、`127.0.0.1` 中选择或手动输入，选择会被记住。
- Cookie 历史：连接时用过的 cookie 保存在用户配置目录的 `cookies.eterm` 中（仅本人可读），之后从下拉列表里选择即可，默认选中上次使用的。页面只能看到 id 和「ga…56」这样的提示，拿不到 cookie 明文。

### 修复

- 在节点页面点「重试」时，不再丢掉添加节点时使用的 cookie。

## [0.0.2] - 2026-10-12

### Fixed

- Windows: the desktop app and the command line release failed to start
  ("Could not load module ...erlexec.dll") anywhere except the build
  machine's path, because the release carried an `erl.ini` with build paths
  and could not rewrite it in a read-only install directory such as
  Program Files. The release now ships without `erl.ini`.

### Changed

- The release workflow unpacks every archive, dmg and AppImage outside the
  build directory, read-only and under a path with a space, and starts it
  before publishing.

## [0.0.1] - 2026-10-12

First public release.

### Added

- Connection management: hidden-node connections with per-node cookies,
  automatic reconnect, several nodes at once.
- `eobs_agent` collector loaded into the observed node on connect and removed
  on disconnect; works on OTP 22 and newer.
- System overview: versions, schedulers, memory breakdown, limits, statistics.
- Load charts: scheduler utilisation with per-scheduler heatmap, memory, IO,
  run queue, reductions.
- Processes: server-side sorting, filtering and paging; reductions delta;
  detail drawer with messages, dictionary, stack trace, `sys:get_state`,
  send message and kill.
- Applications: application list and supervision trees.
- Ports and sockets: port list with details and close, `gen_tcp`/`gen_udp`
  sockets with addresses and statistics, `socket` module sockets.
- Tables: ETS and Mnesia table lists and a row viewer that pages and searches
  on the observed node.
- Memory allocators: block and carrier sizes per allocator with history charts.
- Cluster topology: distribution links of every observed node.
- Shareable links: the selected node and open details are kept in the URL.
- `--read-only` mode, `--password` (or `EOBS_PASSWORD`) for HTTP Basic auth,
  and a refusal of cross-origin WebSocket connections.
- Agents precompiled for OTP 22 to 25 are bundled with the release.
- Release archives and desktop apps (Electron) for Linux x64, macOS arm64 and
  Windows x64.
- Light and dark themes.

[Unreleased]: https://github.com/qinbaixi/EObserver/compare/v0.0.7...HEAD
[0.0.7]: https://github.com/qinbaixi/EObserver/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/qinbaixi/EObserver/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/qinbaixi/EObserver/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/qinbaixi/EObserver/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/qinbaixi/EObserver/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/qinbaixi/EObserver/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/qinbaixi/EObserver/releases/tag/v0.0.1
