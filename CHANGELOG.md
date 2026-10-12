# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- "Local nodes" tab in the connect dialog: lists the nodes registered with
  this machine's epmd and connects the selected ones with one cookie.
- Cookie history: cookies used to connect are saved in the user config
  directory (`cookies.eterm`, owner-only permissions) and offered in a
  list; the page only ever sees an id and a short hint, never the cookie.

### Fixed

- Retrying a disconnected node from its page no longer drops the cookie it
  was added with.

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

[Unreleased]: https://github.com/qinbaixi/EObserver/compare/v0.0.2...HEAD
[0.0.2]: https://github.com/qinbaixi/EObserver/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/qinbaixi/EObserver/releases/tag/v0.0.1
