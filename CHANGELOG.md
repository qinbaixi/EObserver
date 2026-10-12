# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
- Light and dark themes.
