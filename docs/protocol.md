# WebSocket protocol

The browser talks to the tool node over a single WebSocket at `/ws`. Every
frame is a JSON text message with a `type`.

## Requests

```json
-> {"type": "req", "id": 1, "method": "process.info", "params": {"node": "app@host", "pid": "<0.50.0>"}}
<- {"type": "resp", "id": 1, "ok": true, "result": {...}}
<- {"type": "resp", "id": 1, "ok": false, "error": "not_found"}
```

## Subscriptions

A subscription is collected every `interval` milliseconds (minimum 500) until
it is cancelled or the socket closes. A tick is skipped while the previous
collection for the same subscription is still running.

```json
-> {"type": "sub", "id": "s1", "topic": "node.load", "params": {"node": "app@host"}, "interval": 1000}
<- {"type": "push", "id": "s1", "ok": true, "data": {...}}
-> {"type": "unsub", "id": "s1"}
```

Sending `sub` again with the same `id` replaces the subscription.

## Events

```json
<- {"type": "event", "event": "node_status", "data": {"node": "app@host", "status": "connected", ...}}
<- {"type": "event", "event": "node_removed", "data": {"node": "app@host"}}
```

## Conventions

- Pids, ports and references are strings formatted on the observed node, for
  example `"<0.50.0>"`, and are passed back unchanged.
- Arbitrary Erlang terms (messages, state, dictionary values) are pre-formatted
  strings with depth and length limits.
- Node names in `params` must belong to a node the tool already observes.
- When the tool runs with `--read-only`, `process.kill`, `process.send`,
  `port.close`, `table.write`, `table.delete` and `trace.start` fail with `read_only`.
- Nodes connected with a saved cookie (`cookie_id`) or the default cookie are
  remembered in `nodes.eterm` next to `cookies.eterm` and reconnected on the
  next start; `nodes.disconnect` forgets them.

## Security

- The socket only accepts upgrades whose `Origin` matches the `Host` header
  (or that send no `Origin`), so other web pages cannot drive it.
- With `--password` (or `EOBS_PASSWORD`) every HTTP request, including the
  WebSocket upgrade, needs HTTP Basic credentials; any user name is accepted.

## Methods

| Method | Params | Result |
|---|---|---|
| `settings.get` | | `read_only`, `version` |
| `nodes.list` / `nodes.connect` / `nodes.disconnect` | `node`, `cookie` or `cookie_id` | node status |
| `nodes.discover` | `host` (optional) | nodes in the local epmd as `name@host`, host candidates |
| `cookies.list` / `cookies.save` / `cookies.rename` / `cookies.delete` | `cookie`, `label` / `id`, `label` / `id` | saved cookies as `id`, `label`, `hint` (never the cookie) / `id` |
| `node.summary` | `node` | system overview |
| `process.info` / `process.state` | `node`, `pid` | details / `sys:get_state` |
| `process.kill` / `process.send` | `node`, `pid`, `message` | `ok` |
| `apps.list` / `apps.tree` | `node`, `app` | applications / supervision tree |
| `port.info` / `port.close` | `node`, `port` | port details / `ok` |
| `ets.rows` / `mnesia.rows` | `node`, `table`, `offset`, `limit`, `search` | one page of objects, with an opaque `keys` entry per row |
| `table.object` | `node`, `kind` (`ets` / `mnesia`), `table`, `key` | every object under the key, each with full `text`, opaque `ref` and `editable` |
| `table.write` | `node`, `kind`, `table`, `object` (Erlang term text), `ref` (object to replace, optional) | `ok` |
| `table.delete` | `node`, `kind`, `table`, `ref` | `ok` |
| `trace.start` | `node`, `targets` (pids or registered names, at most 10), `max_events`, `max_seconds` (optional) | `id`, traced `processes`, `refused` targets with a reason, `limits`; replaces a running trace |
| `trace.stop` | `node` | `ok` |
| `trace.stats` | `node`, `id` (trace, optional), `row` (optional) | call statistics of the trace, as the `trace.stats` topic, where each row also has `hist` (`low`, `high` in microseconds and `count` per non-empty latency bucket, about 9% wide) and `slowest` (the 10 slowest calls: `latency`, `t`, `peer`, `summary`); only row `row` when given, else every row (used to save a trace) |
| `diag.check` | `node` | health check: `checks` (each `id`, `level` = `ok` / `warn` / `crit` / `skip`, `value`, `warn` / `crit` thresholds, `items`), `memory_total`, `process_count`, `took_ms`; takes about 2 s; one diagnosis at a time per node (`busy`) |
| `diag.window` | `node`, `seconds` (1–60, default 10) | processes that grew most during the window: `reductions`, `memory`, `message_queue_len` (top 20 each, with `value` = growth), `created`, `exited`, `process_count`; refused with `too_many_processes` above 500 000 processes |

## Topics

| Topic | Params | Data |
|---|---|---|
| `node.load` | `node` | rates since the previous tick |
| `node.processes` | `node`, `sort`, `order`, `filter`, `offset`, `limit` | one page of processes |
| `node.summary` | `node` | system overview |
| `node.ports` / `node.inet` / `node.sockets` | `node` | ports, inet sockets, `socket` module sockets |
| `node.ets` / `node.mnesia` | `node` | table lists |
| `node.allocators` | `node` | block and carrier sizes per allocator |
| `trace.events` | `node` | the node's message trace: `status` (`running` / `stopped` / `none`), stop `reason`, `count`, `dropped`, `processes`, and the `events` since the previous push (direction, category, kind, peer, call/reply `ref`, summary, text) |
| `trace.stats` | `node` | gen call statistics of the message trace, counted on the node so they stay exact when events are dropped: `id`, `status`, `kinds` (distinct request kinds, at most `max_kinds` = 200), `rows`, one per traced process, direction (`in`: calls it served, `out`: calls it made) and request kind (a tuple's first element or an atom; `group` = `named`, `other` for any other shape, or `overflow` for kinds beyond the cap), each with `row` (number), `pid`, `dir`, `kind`, `calls`, `answered`, `pending` (waiting for a reply), `unanswered` (no reply within 60 s, pushed out by the cap of 1000 waiting calls, or still waiting when the trace stopped), and `avg` / `p95` / `max` latency in microseconds (`p95` is the upper bound of its histogram bucket) |
| `cluster` | | distribution links of every observed node |

The handlers live in
[`apps/eobserver/src/eobs_api.erl`](../apps/eobserver/src/eobs_api.erl).
