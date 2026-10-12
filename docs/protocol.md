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
- When the tool runs with `--read-only`, `process.kill`, `process.send` and
  `port.close` fail with `read_only`.

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
| `cookies.list` / `cookies.save` / `cookies.delete` | `cookie`, `label` / `id` | saved cookies as `id`, `label`, `hint` (never the cookie) / `id` |
| `node.summary` | `node` | system overview |
| `process.info` / `process.state` | `node`, `pid` | details / `sys:get_state` |
| `process.kill` / `process.send` | `node`, `pid`, `message` | `ok` |
| `apps.list` / `apps.tree` | `node`, `app` | applications / supervision tree |
| `port.info` / `port.close` | `node`, `port` | port details / `ok` |
| `ets.rows` / `mnesia.rows` | `node`, `table`, `offset`, `limit`, `search` | one page of objects |

## Topics

| Topic | Params | Data |
|---|---|---|
| `node.load` | `node` | rates since the previous tick |
| `node.processes` | `node`, `sort`, `order`, `filter`, `offset`, `limit` | one page of processes |
| `node.summary` | `node` | system overview |
| `node.ports` / `node.inet` / `node.sockets` | `node` | ports, inet sockets, `socket` module sockets |
| `node.ets` / `node.mnesia` | `node` | table lists |
| `node.allocators` | `node` | block and carrier sizes per allocator |
| `cluster` | | distribution links of every observed node |

The handlers live in
[`apps/eobserver/src/eobs_api.erl`](../apps/eobserver/src/eobs_api.erl).
