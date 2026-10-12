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

The full list of methods and topics lives in
[`apps/eobserver/src/eobs_api.erl`](../apps/eobserver/src/eobs_api.erl).
