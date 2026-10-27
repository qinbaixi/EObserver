# Crash dump viewer: internal contract

Shared by the backend infrastructure (A), the parsers/views (B) and the UI (C).
Plan: /mnt/project-files/observer/crashdump-plan.md. Reference implementation:
OTP's `lib/observer/src/crashdump_viewer.erl` (source at
/opt/otpsrc/otp_src_26.2.5.6/lib/observer/src/).

Everything runs in the EObserver tool itself, never on an observed node.

## Backend modules

| Module | Owner | Role |
| --- | --- | --- |
| `eobs_dump_sup` | A | simple_one_for_one sup of `eobs_dump`, child of `eobs_sup` |
| `eobs_dump` | A | one gen_server per open dump: scan, index, reader API, close |
| `eobs_dump_scan` | A | chunked scan of `\n=tag[:id]\n` headers |
| `eobs_dump_files` | A | recent files (user config dir, `dumps.eterm`), directory browse |
| `eobs_dump_parse` | B | section text -> maps; per-section summaries during the scan |
| `eobs_dump_term` | B | heap / term text -> readable term text, bounded, with expand tokens |
| `eobs_dump_view` | B | overview + findings, generic `query/3`, process detail, search |
| `eobs_api` (dump.*) | A | WebSocket methods, delegating content to `eobs_dump_view` |

### Reader API (A implements in `eobs_dump`, B consumes)

`H` is an opaque handle (`eobs_dump:handle(Id) -> {ok, H} | {error, not_found}`).
Reads are concurrent: each read opens/uses a raw fd, not the gen_server.

```erlang
eobs_dump:info(H) -> #{id, path, name, size, status := scanning | ready | failed | cancelled,
                       scanned := Bytes, sections, truncated := boolean(),
                       last_tag := binary() | null, last_id := binary() | null,
                       skipped := integer(), error := atom() | null,
                       started (unix s), elapsed_ms, rate (bytes/s), eta (s | null),
                       memory (index bytes)}.
eobs_dump:sections(H, Tag) -> [{Id :: binary() | null, Offset, Len}]   % file order
eobs_dump:lookup(H, Tag, Id) -> [{Offset, Len}]                        % all matches, file order
eobs_dump:count(H, Tag) -> integer()
eobs_dump:read(H, Offset, Len) -> {ok, binary()} | {error, too_large | badarg | term()}
eobs_dump:reads(H, [{Offset, Len}]) -> [{ok, binary()} | {error, term()}] | {error, too_large}
eobs_dump:summaries(H, Tag) -> [{Id, map()}]                           % file order
eobs_dump:summary(H, Tag, Id) -> {ok, map()} | not_found
eobs_dump:entries(H, Tag) -> [{Id, Offset, Len, map() | none}]       % file order, one pass
eobs_dump:cache(H, Key, Fun) -> term()   % memoised per dump (ETS), for B's derived data
eobs_dump:id(H), eobs_dump:path(H)
```

Offsets/lengths cover the section body (after the header line, up to the next header),
without the newline before the next header (and without a final newline at the end of
the file). Tag is the binary between `=` and `:` (or end of line), Id the rest of the
header line (a trailing `\r` is dropped).

Notes:
- `read/3` and `reads/2` read at most 64 MB (in total) per call, else `{error, too_large}`;
  past the end of file they return `{ok, <<>>}` (or fewer bytes). `reads/2` uses one fd.
- `sections/2`, `summaries/2` and `entries/2` sort by offset on every call (1M sections
  ≈ 1 s): keep derived lists in `cache/3`.
- While scanning, summaries are made by worker processes and a summarised section only
  appears in the index together with its summary; still, two separate calls see
  different moments of the scan. Use `entries/2` to get sections and summaries that
  agree (`none` = no summary: skipped, or the parser returned `skip`).
- `cache/3`: a result computed while the scan runs is reused for 2 s only; one whose
  computation started after the scan ended is kept for good. Values are copied out of
  ETS on every hit.
- During a scan everything returns what has been indexed so far. After `dump.close` the
  handle's calls raise `badarg` (the API maps that to `{error, not_found}`).

### Scan hook (B implements, A calls)

```erlang
eobs_dump_parse:summary_tags() -> [binary()]          % e.g. [<<"proc">>, <<"port">>, <<"ets">>, ...]
eobs_dump_parse:summary(Tag, Id, Body) -> map() | skip  % pure; binaries in the map are copied
```

A stores the returned map in the index for `summaries/2`. The scanner must
cope with sections spanning chunk boundaries and with a truncated last
section (no `=end`).

- `summary/3` runs in up to 4 worker processes in parallel: keep it pure (no
  process dictionary state across calls, no side effects). A crash or a non-map
  return other than `skip` counts in `skipped` / is ignored.
- Bodies over 64 KB are passed with every line cut to 4096 bytes plus `...`, so the
  fields after a huge `Link list` still come through (bodies over 64 MB: skipped).
- Binaries in the map are copied before storing; keep the map small (it is the
  bulk of the index for `proc`: ~200 bytes per summary today) and flat.

## WebSocket methods (A wires, B fills content)

All params use `id` for the dump id (binary). Errors are `{error, atom}`.

| Method | Params | Result |
| --- | --- | --- |
| `dump.browse` | `path?` | `{path, parent, sep, roots: [{name, path, kind: home\|cwd\|root\|drive}], truncated, entries: [{name, path, dir, size, mtime, dump}]}` (`dump` = name looks like a crash dump; dirs first, hidden entries left out, at most 5000) |
| `dump.recent` | | `[{path, size, mtime, opened}]` (missing files dropped, max 20) |
| `dump.open` | `path` | `{id, info}` (an already-open path returns its id) |
| `dump.list` | | `[info]` of open dumps, oldest first |
| `dump.info` | `id` | `info` |
| `dump.cancel` | `id` | `ok` (stops the scan, keeps what was indexed; status `cancelled`) |
| `dump.close` | `id` | `ok` (cancels a running scan, frees the index) |
| `dump.overview` | `id` | see Overview (available while scanning; fields fill in) |
| `dump.query` | `id, kind, offset, limit, sort, order, filter` | `{total, columns, rows}` |
| `dump.process` | `id, pid` | process detail |
| `dump.process_part` | `id, pid, part, offset, limit` | `{total, items}` |
| `dump.detail` | `id, kind, key` | `{title, fields: [{key, value}], terms?}` for port/ets/node/module/... |
| `dump.expand` | `id, token` | Term |
| `dump.search` | `id, q` | `[{kind, key, label}]` (max 50) |

Event pushed to every socket during a scan, at most ~4/s plus a final one:
`dump_progress` = `info` (which carries `rate: bytes_per_sec, eta: seconds|null`).

Paths are absolute with `/` separators on every OS (`sep` is always `/`); `~` is expanded.
`dump.open` / `dump.browse` errors: `enoent`, `eacces`, `enotdir`, `eisdir`, `not_a_file`,
`empty`, `not_a_dump`, `badarg`; content methods: `not_found` (unknown or closed id).
`dump.query` `limit` is capped at 1000 (default 50), `sort` is passed as a binary (or
null), `order` as `asc | desc`; `dump.process_part` `limit` is capped at 1000 (default 100).
eobs_dump_view functions may return a value, `{ok, Value}` or `{error, Atom}`.

### Values

- **Term**: `{text, more: token|null}`: pretty printed (80 columns), bounded by level
  (L0 depth 6 / 20 items / 48 binary bytes / ~1500 chars; L1 12/100/256/12k; L2 30/1000/4k/120k;
  L3 100/10k/64k/1M). `more` is set when anything was cut; `dump.expand` returns the same
  term at the next level (L3 has `more: null`). Markers inside text: `...` (cut),
  `<incomplete heap>` (pointer not in the dump, e.g. truncated), `<binary not in dump>`,
  `<external term, N bytes>` (undecodable), binaries cut as `<<"abc"... 16000 bytes>>`.
  Tokens are opaque base64url strings; bad/foreign tokens give `{error, bad_token}`.
- **Column**: `{key, type, sortable}` where type is
  `text | int | bytes | words | pid | port | term | ms | bool`. UI labels come from
  i18n `crashdump.col.<key>`; `pid`/`port` cells link to the detail.
- Row values are JSON scalars (null when unknown); `term` columns carry a Term.

### kinds for `dump.query`

`processes, ports, ets, timers, schedulers, nodes, modules, funs, atoms,
persistent_terms, allocators, memory, allocated_areas, hash_tables, index_tables,
internal_tables`; anything else is `{error, unknown_kind}`. `filter` is a case-insensitive
substring over the text/pid/port/term columns. Unknown `sort` keys fall back to the
kind's default. Columns (default sort):

| kind | columns |
| --- | --- |
| processes (memory desc) | pid, name, state, init, current, reds, memory, mq, heap (stack+heap+old heap bytes), bin (binary vheap bytes) |
| ports (id) | id, name, state, type (driver/spawn/forker/file/fd), controls, connected, slot, input, output, queue |
| ets (memory) | table (detail key), name, owner, type, protection, objects, memory |
| timers (time_left) | owner (pid or registered name), message, time_left |
| schedulers | id, type (normal/dirty_cpu/dirty_io), process, port, run_queue, port_queue, sleep |
| nodes | channel (detail key), name, type (visible/hidden/not_connected), controller, creation, links, monitors, monitored_by, error |
| modules (current_size) | name (detail key `module`), current_size, old_size |
| funs (refc) | module, uniq, index, address, refc |
| atoms | index (1 = oldest; only sortable column), name (as printed, quoted when needed) |
| persistent_terms | key (Term), value (Term); filter/sort on the key text |
| allocators (carriers_size) | name (type, detail key), instances, blocks_size, carriers_size, usage (%) |
| memory | key, value |
| allocated_areas | key, allocated, used |
| hash_tables / index_tables | name, size, used, objs, depth / name, size, limit, entries |
| internal_tables | name, type, objects, memory |

Processes while a scan of a dump with more than 100k processes is still running:
`{total, columns, rows: [], scanning: true}` (the table is built once the scan ends;
overview `top`/whole-table findings and process search wait likewise).

### Overview

```
{file: info,
 general: {slogan, node, time, system_version, otp_release, word_size, dump_version,
           compiled, taints, atoms, calling_thread, raw: [{key, value}]},
 reason: {code, params},          % classified slogan, UI translates crashdump.reason.<code>
 counts: {processes, ports, ets, timers, funs, modules, atoms, nodes},
 limits: {processes, ports, atoms, ets},   % null when unknown (only atoms is in a dump)
 memory: {total, processes, processes_used, system, atom, atom_used, binary, code, ets},
 findings: [{level: critical|warning|info, code, params, target: {kind, key}|null}],
 top: {memory: [process rows], mql: [process rows with mq > 0]}}   % 10 each
```

Findings are sorted critical, warning, info. `target.kind` is one of
`process | port | ets` (keys as in the detail/process methods).

Reason codes and params:

| code | params | slogan |
| --- | --- | --- |
| `out_of_memory_heap` | `{allocator, op, size, type}` | `eheap_alloc: Cannot allocate N bytes of memory (of type "heap"/"old_heap"/"heap_frag")` |
| `oom` | `{allocator, op, size, type}` (null when unknown) | other `X: Cannot (re)allocate ...`, `Out of virtual memory in ...` |
| `kernel_pid_terminated` | `{process, app (null unless application_start_failure), reason}` | `Kernel pid terminated (P) (R)` |
| `kernel_start_failed` | `{process, reason}` | `Could not start kernel pid (P) (R)` |
| `init_terminating` | `{reason, phase: boot}` | `Runtime terminating during boot (R)` / `init terminating in do_boot (R)` |
| `system_limit` | `{what: atoms/modules/exports/<table>, max}` | `no more index entries in atom_tab (max=N)` |
| `system_process_terminated` | `{process, reason}` | `System process P terminated: R` |
| `sigusr1` | `{}` | `Received SIGUSR1` |
| `user_requested` | `{}` | `Crash dump requested by user` (break menu) |
| `halt` | `{text}` | anything else, when `erlang:halt/1,2` is on the calling scheduler's stack |
| `unknown` | `{text}` | anything else |

Texts in params are cut at 4 KB (`general.slogan` at 64 KB).

Finding codes and params:

| code | level | params |
| --- | --- | --- |
| `truncated` | warning | `{at (file size), last_tag, last_id}` |
| `dump_aborted` | warning | `{reason}` (`=abort` section, e.g. size limit reached) |
| `skipped_sections` | info | `{count}` |
| `calling_process` | info | `{pid, scheduler, state, function}` process running on the thread that wrote the dump |
| `garbage_collecting` | critical | `{pid, name, memory}` processes in state Garbing when the reason is oom (likely culprit) |
| `top_memory_process` | info / warning (≥10% of total) / critical (≥30% and oom) | `{pid, name, memory, share (% of total)}` |
| `long_message_queue` | warning (≥1000) / critical (≥100000) | `{pid, name, len}` (top 5) |
| `limit_near` | warning (≥80%) / critical (≥95%) | `{what: atoms/modules/exports, used, limit}` |
| `big_ets` | warning | `{table, name, owner, bytes, objects}` (≥ max(100 MB, 20% of total); top 3) |
| `binary_heavy` | warning | `{binary, total, share, pid, pid_binary}` (binary ≥ 30% of total; pid = most binary vheap) |
| `many_processes_in_state` | warning | `{state, count, total}` (Scheduled ≥ max(50, 5%), Suspended/Exiting ≥ 100, Garbing ≥ 10) |
| `many_processes` | info | `{count}` (≥ 100000) |
| `run_queue_long` | warning | `{scheduler, type, length}` (≥ 100) |
| `port_queue` | warning | `{port, name, bytes}` (≥ 10 MB) |

### Process detail

```
{summary: process row, info: [{key, value, type: text|int|bytes|pid}], parent,
 links: [id], monitors: [id], monitored_by: [id],
 parts: {messages: count, dictionary: count, stack: count, heap: boolean},
 notes: [garbing | no_heap | truncated]}
```

Unknown pid: `{error, not_found}`. `info` keys: state, name, init, current, parent,
started, reds, mq, memory, stack_heap, old_heap, heap_unused, old_heap_unused, bin_vheap,
old_bin_vheap, bin_vheap_unused, old_bin_vheap_unused, heap_frags, heap_frag_data,
program_counter, cp, arity, internal_state, run_queue, last_calls, garbing heap pointers,
plus raw unknown lines (key = the dump's text); null values are left out. Monitors on
`{name,node}` of this node are resolved to the pid when it is registered.

`process_part` parts: `messages` (items: Term), `dictionary` (items: `{key: Term, value: Term}`),
`stack` (items: `{addr, kind: return|catch|var|frame, text}`; `var` items (y registers)
also carry `term: Term`). Other parts: `{error, unknown_part}`.

### Detail

`dump.detail` kinds and keys: `port` (`#Port<a.b>`), `ets` (the `table` column),
`node` (channel), `module` (name; `terms: [{key: cur_attrib|cur_comp|old_attrib|old_comp,
value: Term}]`), `allocator` (type or instance id; `instances: [{name, fields}]`),
`scheduler` (id; `stack: [line]`), `timer` (owner). Unknown: `{error, not_found}`.

## Frontend (C)

- Route `/crashdump` (sidebar item, icon `BugOutline`), shown even with no node connected
  (bypass WelcomePanel on this route).
- Desktop: preload exposes `eobsDesktop.openDumpFile(): Promise<string|null>` (native dialog)
  and `eobsDesktop.pathForFile(file): string` (drag & drop via `webUtils.getPathForFile`).
- i18n area files `crashdump.zh.ts` / `crashdump.en.ts`, keys under `crashdump.*`.
