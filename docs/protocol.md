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

The server closes a socket it has not heard from for 120 seconds, so the
browser sends `{"type": "ping"}` every 30 seconds; frames of an unknown
type are ignored.

The overview wall and the compare mode of the load charts subscribe
`node.load` every 2 seconds for each node they show (at most 50 at a time),
and the wall also `node.summary` every 5 seconds for the limits; the history
is kept in the browser only, and the subscriptions end when the view closes.

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
  `port.close`, `table.write`, `table.delete`, `trace.start` and `recon.bin_leak` fail
  with `read_only`.
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
| `recon.proc_count` | `node`, `attribute` (`memory` / `reductions` / `message_queue_len` / `total_heap_size` / `binary_memory`, default `memory`), `n` (1–50, default 20) | like `recon:proc_count/2`: `attribute`, `n`, `process_count`, `took_ms`, `items` sorted by `value` (each `pid`, `name`, `initial_call`, `current_function`, `value`, `memory`, `reductions`, `message_queue_len`, `total_heap_size` (bytes), `too_many`); for `binary_memory` the value is the refc binary bytes the process references, and a process with too many binaries to read has `value` null, `too_many` true and comes first; shares the diagnosis lock (`busy`), refused with `too_many_processes` above 500 000 processes |
| `recon.bin_leak` | `node`, `n` (1–50, default 20) | like `recon:bin_leak/1`: garbage-collects the processes one at a time at low priority (pausing every 100) and reports the `items` whose collection freed the most refc binary bytes (`before_bytes`, `after_bytes`, `before_count`, `after_count`, `freed` = `value`); `n`, `process_count`, `gc_count` (processes collected: only those referencing refc binaries), `skipped`, `skipped_items` (at most 20, with `reason` = `long_queue` (over 10 000 messages) / `big_heap` (over 1 GiB) / `too_many_binaries` / `gc_timeout` (did not collect within 5 s)), `binary_before` / `binary_after` (`erlang:memory(binary)`), `took_ms`, `complete` (false when stopped after 100 s); changes the node, so refused in read-only mode; refused with `too_many_processes` above 200 000 processes |
| `recon.inet_count` | `node`, `attribute` (`recv_oct` / `send_oct` / `recv_cnt` / `send_cnt` / `oct` / `cnt`, default `oct`), `n`, `seconds` (0–60, default 0) | like `recon:inet_count/2` (`seconds` 0: totals since each socket opened) and `inet_window/3` (growth during the window): `attribute`, `n`, `seconds` (actual), `socket_count`, `items` (`port`, `type` = `tcp` / `udp` / `sctp`, `owner`, `owner_name`, `local`, `remote`, the socket's current `recv_oct`, `send_oct`, `recv_cnt`, `send_cnt`, `value` = total or growth of the attribute, `new` = opened during the window); inet driver sockets only, refused with `too_many_sockets` above 100 000 |
| `recon.port_types` | `node` | like `recon:port_types/0`: `total`, `types` (`name`, `count`, most first; beyond 100 types the rest is summed as `other`) |
| `recon.alloc` | `node` | like `recon_alloc` fragmentation / average block sizes / sbcs-to-mbcs / cache hit rates, current values: `allocators`, one per allocator instance (`type`, `instance`, `mbcs_blocks`, `mbcs_carriers`, `sbcs_blocks`, `sbcs_carriers` in bytes, `*_block_count`, `*_carrier_count`, `mbcs_usage` / `sbcs_usage` (blocks / carriers), `mbcs_avg_block` / `sbcs_avg_block`, `sbcs_to_mbcs` (carrier counts), null where the divisor is 0), `cache_hit_rates` (per `mseg_alloc` instance: `instance`, `hits` = segment allocations not needing a new segment, `calls`, `ratio`), `memory_total` |
| `recon.scheduler_usage` | `node`, `seconds` (1–30, default 5) | like `recon:scheduler_usage/1`: `seconds` (actual), `schedulers` (`id`, `type` = `normal` / `dirty_cpu` / `dirty_io`, `usage` 0–1); shares the diagnosis lock |

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
| `logs.events` | `node` | the node's live log and crash records, collected only while someone pulls this topic (a logger handler is added on the first pull and removed 60 s after the last one, or when the tool disconnects); allowed in read-only mode. `status` (`running` / `stopped`), stop `reason`, `started`, target clock `now` (ms), `primary_level` (the node's logger level: less severe events are never produced), `received`, `lost` (overwritten in the 2000-line ring before this read), `dropped` (overload), `limited` (below warning, over 2000 events/s), `reset` (the collection restarted), and since the previous push: `logs` (`seq`, `t` in µs, `level`, `module`, `pid`, `text`), changed `crashes` (one per process and reason: `id`, `who`, `pid`, `class`, `reason`, `text`, `stack`, `count`, `first`, `last`) and changed `restarts` (one per supervisor and child: `id`, `supervisor`, `child`, `count`, `failed_starts`, `gave_up`, `restart_type`, `reason`, `last`, recent `times`) |
| `trace.stats` | `node` | gen call statistics of the message trace, counted on the node so they stay exact when events are dropped: `id`, `status`, `kinds` (distinct request kinds, at most `max_kinds` = 200), `rows`, one per traced process, direction (`in`: calls it served, `out`: calls it made) and request kind (a tuple's first element or an atom; `group` = `named`, `other` for any other shape, or `overflow` for kinds beyond the cap), each with `row` (number), `pid`, `dir`, `kind`, `calls`, `answered`, `pending` (waiting for a reply), `unanswered` (no reply within 60 s, pushed out by the cap of 1000 waiting calls, or still waiting when the trace stopped), and `avg` / `p95` / `max` latency in microseconds (`p95` is the upper bound of its histogram bucket) |
| `cluster` | | distribution links of every observed node |

The handlers live in
[`apps/eobserver/src/eobs_api.erl`](../apps/eobserver/src/eobs_api.erl).
