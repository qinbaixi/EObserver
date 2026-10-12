# Security Policy

EObserver connects to Erlang nodes with their distribution cookie and can kill
processes, send messages and read process state on them. Treat access to an
EObserver instance like access to a remote shell on the observed node.

## Recommendations

- Keep the default `--listen 127.0.0.1`. If you need remote access, prefer an
  SSH tunnel. When you do listen on another address, set `--password` (or
  `EOBS_PASSWORD`) and put EObserver behind TLS, since HTTP Basic auth sends
  the password in clear text. EObserver prints a warning when it listens
  beyond localhost without a password.
- Use `--read-only` when you only need to look, which disables kill, send and
  port close.
- The WebSocket refuses connections whose `Origin` differs from the page's
  host, so other websites you visit cannot drive a local EObserver.
- Never expose Erlang distribution ports to untrusted networks.

## Reporting a vulnerability

Please report vulnerabilities privately using
[GitHub private vulnerability reporting](https://github.com/qinbaixi/EObserver/security/advisories/new)
rather than opening a public issue. We aim to acknowledge reports within a few
days.

## Supported versions

Only the latest release receives security fixes.
