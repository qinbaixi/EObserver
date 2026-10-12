<div align="center">

<img src="web/public/favicon.svg" width="72" alt="EObserver logo" />

# EObserver

**A modern, browser-based observer for Erlang/OTP nodes.**

A better-looking replacement for OTP's built-in `observer`: connect to any running node with its name and cookie, nothing to install on the target.

[![CI](https://github.com/qinbaixi/EObserver/actions/workflows/ci.yml/badge.svg)](https://github.com/qinbaixi/EObserver/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Erlang/OTP](https://img.shields.io/badge/target-OTP%2022%2B-A90533.svg)](#compatibility)

English | [简体中文](README.zh-CN.md)

</div>

![Load charts](docs/images/load-charts-dark.png)

## Why EObserver

OTP's `observer` is indispensable but built on wxWidgets: it needs a desktop session on a machine with wx, it looks dated, and it gets sluggish on nodes with hundreds of thousands of processes. EObserver keeps the same mental model and fixes those pain points.

| | OTP `observer` | EObserver |
|---|---|---|
| UI | wxWidgets desktop window | Any browser, light and dark themes |
| Requirements on the target | `runtime_tools` | Nothing; a small collector is loaded on connect and removed on disconnect |
| Large process tables | The whole table is pulled to your machine | Sorting, filtering and paging run on the target; only one page is sent |
| Visibility | Connects as a normal node | Connects as a **hidden** node, never in the target's `nodes()` |
| Several nodes | One at a time | Switch between any number of nodes |

## Features

- **System**: OTP/ERTS versions, schedulers and threads, memory breakdown, usage of process, port, atom and ETS limits, runtime statistics.
- **Load charts**: scheduler utilisation (average plus a per-scheduler heatmap that stays readable with 64+ cores), stacked memory, IO throughput, run queue and reductions. History survives page switches.
- **Processes**: sortable, searchable, paged process table with *Reds* (reductions since the last refresh) to spot busy processes. The detail drawer shows links and monitors (click to follow), messages, process dictionary, stack trace and `sys:get_state`, and can send a message or kill the process.
- **Applications**: every running application with its supervision tree; click any node to inspect the process.
- Coming next: Ports & Sockets, ETS/Mnesia table viewer, memory allocators. See the [roadmap](#roadmap).

<table>
  <tr>
    <td><img src="docs/images/processes.png" alt="Processes" /></td>
    <td><img src="docs/images/process-detail.png" alt="Process details" /></td>
  </tr>
  <tr>
    <td><img src="docs/images/system.png" alt="System overview" /></td>
    <td><img src="docs/images/applications-dark.png" alt="Supervision tree" /></td>
  </tr>
</table>

## Quick start

EObserver itself needs **Erlang/OTP 26**, **rebar3** and **Node.js 22** to build.

```sh
git clone https://github.com/qinbaixi/EObserver.git
cd EObserver
make release
_build/default/rel/eobserver/bin/eobs --node myapp@myhost --cookie secret
```

Your browser opens at <http://localhost:8090/>. You can also start without `--node` and add nodes from the page.

### Command line options

| Option | Description |
|---|---|
| `--node NAME@HOST` | Node to connect to on start |
| `--cookie COOKIE` | Cookie for that node (defaults to `~/.erlang.cookie`) |
| `--port 8090` | HTTP port |
| `--listen 127.0.0.1` | Listen address. Localhost by default because the UI can kill processes on the target |
| `--no-browser` | Do not open a browser |

Short names (`app@host`) and long names (`app@host.example.com`) are detected automatically, but one EObserver instance uses one kind at a time.

## How it works

```
 Browser (Vue 3 + Naive UI + ECharts)
        │  WebSocket (JSON)
        ▼
 EObserver tool node (hidden, Cowboy)
        │  Erlang distribution (erpc)
        ▼
 Target node  ── eobs_agent (loaded on connect, removed on disconnect)
```

1. The tool starts without a node name and enables distribution as a hidden node once it knows the target, matching its short or long names.
2. On connect it loads `eobs_agent` with `code:load_binary/3`. The agent only uses kernel/stdlib APIs from OTP 22, so the target needs no extra applications.
3. The browser subscribes only to what is on screen. Each subscription is collected in its own process on the tool node, so one slow node never blocks another, and a tick is skipped while the previous one is still running.

Measured on a node with 200,000 processes: a process-table refresh takes about 0.25 s (about 1 s when sorted by memory or filtered).

## Compatibility

| | Version |
|---|---|
| Target nodes | OTP 22 or newer |
| EObserver build | OTP 26 |
| Browsers | Current Chrome, Edge, Firefox, Safari |

## Development

```sh
make web                 # build the frontend into apps/eobserver/priv/www
make test                # eunit + Common Test (starts real peer nodes)
make shell               # backend on :8090
cd web && npm run dev    # frontend with hot reload, proxies /ws to :8090
```

```
apps/eobserver/        tool node: connections, HTTP/WebSocket, API
apps/eobserver_agent/  collector loaded into observed nodes (OTP 22 compatible)
web/                   Vue 3 + TypeScript + Naive UI + ECharts frontend
test/                  eunit and Common Test suites
```

The WebSocket protocol is described in [docs/protocol.md](docs/protocol.md).

## Roadmap

- [x] Connection management, hidden node, agent injection, UI shell
- [x] System overview and load charts
- [x] Processes with server-side sorting, filtering and paging
- [x] Applications and supervision trees
- [ ] Ports and sockets
- [ ] ETS and Mnesia table viewer
- [ ] Memory allocators
- [ ] Cluster topology, shareable URLs, access control, prebuilt agents per OTP release, release packages
- Tracing is out of scope for now.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and follow the [Code of Conduct](CODE_OF_CONDUCT.md). Security issues: see [SECURITY.md](SECURITY.md).

## License

Copyright 2026 the EObserver authors.

Licensed under the [Apache License, Version 2.0](LICENSE), the same license as Erlang/OTP.
