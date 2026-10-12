# Contributing to EObserver

Thanks for your interest! Bug reports, ideas and pull requests are all welcome.
中文贡献者同样欢迎，Issue 和 PR 用中文或英文都可以。

## Reporting bugs and asking for features

Open an issue using one of the templates. For bugs, include the EObserver
version, the OTP release of the observed node, your browser, and steps to
reproduce. Screenshots help a lot for UI issues.

## Development setup

You need Erlang/OTP 26, rebar3 and Node.js 22.

```sh
make web                 # build the frontend
make test                # eunit + Common Test
make shell               # run the backend on :8090
cd web && npm run dev    # frontend with hot reload
```

To have something to observe, start any node in another terminal:

```sh
erl -sname demo -setcookie demo
```

and connect to `demo@<your short hostname>` with cookie `demo`.

## Project layout

| Path | What lives there |
|---|---|
| `apps/eobserver` | The tool node: connection management, HTTP/WebSocket, API |
| `apps/eobserver_agent` | `eobs_agent`, the module loaded into observed nodes |
| `web` | Vue 3 + TypeScript + Naive UI + ECharts frontend |
| `electron` | Desktop wrapper around a bundled release |
| `test` | eunit and Common Test suites |
| `docs` | Protocol notes and screenshots |

## Rules for `eobs_agent`

The agent runs inside production nodes we do not control, so:

- Use only kernel/stdlib APIs that exist in **OTP 22**. Guard newer calls with
  `safe/1` or a feature check.
- Never call another EObserver module from the agent.
- Do the heavy work (sorting, filtering, paging, formatting) on the target and
  return only what the page shows.
- Cap everything that can grow: list lengths, term depth, string length.
- Bump `?VERSION` whenever exported functions or their return shapes change, so
  an older copy still loaded on a target is replaced.

## Pull requests

1. Fork and create a branch from `main`.
2. Keep each PR focused on one change. Add or update tests; Common Test suites
   start real peer nodes, so most agent features can be tested end to end.
3. Run `make test` and `cd web && npm run build` before pushing. CI runs the
   same steps.
4. Describe what a user would see before and after the change. Screenshots are
   appreciated for UI changes.

## Code style

- Erlang: follow the style of the surrounding code; four-space indentation,
  no tabs, `-spec` for exported functions where it helps.
- TypeScript/Vue: `<script setup lang="ts">`, Naive UI components, colors from
  the chart theme rather than hard-coded per chart.

By contributing, you agree that your contributions are licensed under the
Apache License 2.0.
