# Hierarchical Tracing Implementation Progress

Status: ready for client-driven acceptance; field presentation tuning is deferred.
Isolated OTLP ingestion and observation read-back
now pass against the user-reported Langfuse v3.188.0 EE deployment using its v1
read API. P3 plugin/skill and P4 manual recording code are now present; real guest
read-only success acceptance also passes. Interactive/media acceptance and global
rollout remain pending.
This is not a claim that all acceptance gates in [TRACING_PLAN.md](TRACING_PLAN.md)
have passed. Use [TRACING_CLIENT_TEST.md](TRACING_CLIENT_TEST.md) for the client
upgrade and interactive test session.

## Implemented

- Task and nested chain records persist generated trace/span identities across
  CLI and MCP processes. OpenTelemetry Swift/Core `2.6.0` remain pinned for
  toolchain compatibility. A GitHub release check returned 403; no newer-version
  claim is made.
- MCP discovers `trace_begin`, `chain_begin`, `chain_end`, `trace_end`, and
  `trace_status`. Desktop tools accept optional `context` and `reason`.
- CLI supports `trace|chain begin|end|status`; `action` accepts `--context`,
  `--reason`, and opt-in `--trace-envelope`. Default action output is unchanged.
- MCP results include correlation in `_meta["terminal-mac/tracing"]`, retaining
  existing content blocks and failure responses.
- `LANGFUSE_CONTENT_MODE=summary|content` defaults to summary. Content mode captures
  sanitized tool parameters, guest values, and text results, not image data.
  Credential values, common secret fields, and recognized inline token patterns
  are filtered before persistence/export; masking cannot detect every secret.
- Invalid action context falls back to an independent trace with a warning.
  End is idempotent; open children/active calls prevent premature completion.
- Completed observations enter a bounded persistent outbox. Failed batches retain
  stable IDs and retry without repeating guest actions.
- Expired tasks/chains recover as interrupted using a labeled expiry boundary,
  not a claim about the actual instant a process stopped.
- Public CLI dispatch now records validation failures and results. Parsed
  structured inputs are captured only after successful parsing, never raw argv.
  CLI exit intent is recorded; MCP failures include actual client-facing text.
- Actor provenance is optional and caller-reported for CLI/MCP; Viewer records
  `human` from its terminal input boundary. Process-local sequences and monotonic
  action/queue durations support ordering without asserting cross-process total order.
- Viewer opt-in recording supports explicit task attachment, queued input merging,
  dispatch/completion/drop outcomes, and capture pause, including in-flight actions.
- Screenshot media has a separate off-by-default switch. It uses the deployed
  media API, SHA-256 checksum, presigned upload, and a Langfuse media reference.
  It is tested with HTTP substitutes; real media storage is not yet verified.
- The repository plugin and build default are now `0.2.1` (build 7). MCP instructions
  and packaged skill guide optional tracing and old-binary fallback.

## Current Interface

```sh
terminal-mac trace begin --goal 'Inspect documentation' --session opaque-session
terminal-mac chain begin --context TASK_HANDLE --goal 'Open browser' --reason 'Read the official API guide'
terminal-mac action default status --context CHAIN_HANDLE --reason 'Check guest readiness' --trace-envelope
terminal-mac chain end --context CHAIN_HANDLE --outcome failed --summary 'Guest unavailable'
terminal-mac trace end --context TASK_HANDLE --outcome failed --summary 'Setup is needed'
terminal-mac trace status
```

MCP equivalents take `goal`, `session`, `context`, `reason`, `outcome`, and `summary`
as appropriate. Copy opaque handles rather than inventing IDs. Status reports
protocol version 1, enabled state, pending/failed/dropped counts, and open contexts.
Disabled management calls return `{"enabled":false}`. Management does not require
a running VM; desktop actions still do. These examples were not executed against
the real desktop during implementation.

## Current Limits

| Item | Current behavior |
| --- | --- |
| Goal/summary | At most 4096 UTF-8 bytes; goal nonempty |
| Reason | Management input at most 1024 bytes; action metadata bounded |
| Content JSON | 16 KiB; string values limited to 4096 bytes |
| Content collections | Eight levels; first 64 object keys/array entries |
| Contexts | 256 records per scope; oldest closed records evicted at capacity, open records preserved |
| Lifetime | 24 hours; children inherit expiry |
| Active actions | 180-second leases renewed every 60 seconds for live calls; 64 per context |
| Outbox | 512 records, 64 KiB per record, 8 MiB aggregate |
| Overflow | Drop new records and increment dropped count |
| Retry | Exponential backoff up to one hour; 30-second batch lease |
| Retention | Seven days for outbox; contexts seven days after expiry |
| Delivery | Every two seconds while process runs; one batch at shutdown |
| Export | Two-second timeout per batch; no unconditional guarantee |

State lives under the host data root at `tracing/<scope-hash>/state.json`. Scope
incorporates OTLP endpoint, public-key hash input, and environment. Keys/payloads
are never stored in guest shares. Private permissions, safe mailbox IO, atomic
replacement, and nonblocking cross-process locking protect storage. Corruption
or unsupported schema disables initialization. Lock contention can fail tracing
without failing desktop control. The export worker retries persistence five times
over at most 100 ms of backoff; context acquisition on the UI actor never waits
for a lock. Contention beyond this window can lose a telemetry batch.

Task roots/chains export only on end/recovery, not as live unfinished observations.
Child-before-parent UI visibility needs deployment verification. CLI retries require
another invocation; there is no separate delivery daemon. Buffered action spans
can still be lost on hard termination before persistence.

## Verification

The current debug build and all 71 XCTest tests pass, including hierarchy,
manual privacy/order, command validation, and media protocol tests. Audit scripts
pass `node --check`.
Four Node tests additionally cover explicit v3/v4 read selection, bounded query
parameters, JSON/object I/O compatibility, and rejection of malformed evidence.
The optimized `0.2.1` build and signing verification passed. The packaged skill
matches the plugin skill byte-for-byte. Packaged MCP discovery reports 13 tools,
including the five tracing tools and optional context/reason/actor on actions.
The install script passed with an isolated prefix at `.build/tracing-install`;
no global installation, live MCP restart, or actual AI-client test was performed.

Tests cover persisted identity reconstruction, nested parents, idempotent end,
active children/calls, invalid context fallback, zero sampling, secret fixtures,
content limits, oversized record drops, and safe store boundaries. A real subprocess
test mixes multiple CLI processes with MCP stdio in an isolated missing-VM setup.

An SDK adapter invariant was found and fixed: reconstructed `SpanData` must update
`totalAttributeCount` when attributes change, otherwise protobuf conversion traps
on a negative dropped-attribute count. Tests exercise actual SDK protobuf conversion
and subprocess exit status, not only an in-memory exporter.

### Live Probe

Two isolated probes used non-sensitive missing-VM requests in `tracing-acceptance`.
No real VM was started, stopped, typed into, or clicked.

- Trace IDs: `82a8c10ee8a9faf22f13027f78efcec0` and
  `bbb29a969d5d38619a8feb2c98bf7874`.
- Both local test stores report zero pending/failed/dropped observations and zero
  open contexts. This proves transport acknowledgement, not backend rendering.
- Earlier default-v4 `@langfuse/cli` observation queries returned HTTP 404:
  "The observations v2 API is only available in a Langfuse v4 write mode."
- The user subsequently identified the deployment as v3.188.0 EE. Official
  compatibility documentation specifies v1 reads for self-hosted v3. The deployment's
  `/generated/api/openapi.yml` confirms `/api/public/observations` and the OTLP path.
- Selecting CLI API snapshot `3.150.0` makes `observations list` use the v1 path.
  There is no exact bundled `3.188.0` snapshot; this earlier contract was verified
  against the deployment's own specification and successful responses. The CLI
  executable remains `@langfuse/cli` version `1.3.1`, not a downgraded SDK/runtime.
- The earlier `bbb29a969d5d38619a8feb2c98bf7874` trace was successfully retrieved
  with all five expected observations, including `CHAIN` and `TOOL` types.
- A fresh probe `f9c82a43172419ee2a6db52645ed7c7c` passed ingestion and read-back,
  with exact root/chain/MCP IDs, all five parent links, types, actual error I/O,
  chain/action reasons, MCP request correlation, timestamps, session, release,
  environment, and credential absence checked. The outbox reported zero pending,
  failed, or dropped observations and zero open contexts.
- Probe IDs are retained here, but internal deployment URLs and project identifiers
  are intentionally omitted from this publishable report. The browser UI was not
  inspected. The task root's success means the expected failure-path probe passed,
  not that a VM action succeeded.
- At that stage successful guest response capture, screenshots, and manual Viewer
  operations were still unverified. Deployment settings, `.env`, and installed
  applications/plugins were not changed. No additional server-admin rights were needed.

Repeat the isolated v3 probe:

```sh
env npm_config_cache=/private/tmp/terminal-mac-npm npx --yes @langfuse/cli --host https://self-hosted.invalid --api-version 3.150.0 api observations list --help
node scripts/tracing-audit.mjs .build/debug/terminal-mac .env --server-version 3.188.0
node --test scripts/tracing-audit.test.mjs
```

The script requires Node with `util.parseEnv` and the official CLI in that cache.
It does not print keys and retains test state when acceptance fails. An optional
positional trace-ID argument queries an existing trace without sending another
probe, for example:

```sh
node scripts/tracing-audit.mjs .build/debug/terminal-mac .env f9c82a43172419ee2a6db52645ed7c7c --server-version 3.188.0
```

`--server-version` selects v1 reads explicitly for v3; the default remains v4/v2.
No silent fallback or server mode change occurs. Queries are trace-scoped, limited
to 100 observations and a seven-day window. New v3 probes allow up to two minutes
of read-only polling for asynchronous ingestion. More than one page is rejected
rather than reported as complete. OTLP ingestion and the existing header remain
unchanged; both old and fresh traces demonstrate that this deployment accepts them.

### Current Success and Error Acceptance

- Current-code isolated error probe
  `c464c45253185117c1f4a0e4be0a47e4`
  passes all twelve read-back checks. Its MCP output includes actual returned
  error content, and CLI output includes exit code. Both carry sequence/source
  and monotonic duration metadata.
- Real `default` guest status probe
  `27e8df18e59d6c60227f511775086980`
  passes with six observations: task, chain, MCP tool/guest, CLI tool/guest.
  The actual returned permission values and tool response content are present.
  All observations are successful and share the expected parent tree, environment,
  and correlation IDs. Pending/failed/dropped/open counts are zero.
- The success probe was strictly read-only `status`: no screenshot, desktop input,
  guest update, or VM lifecycle operation. The running guest helper remains `0.2.0`.
- `scripts/tracing-guest-audit.mjs` repeats that read-only success probe using the
  existing VM; media is forcibly disabled. Its default binary is `dist/terminal-mac`.

## Public CLI Coverage

| Paths | Trace behavior |
| --- | --- |
| `help`, `version`, `doctor`, `ls` and aliases | Command boundary, validated input where applicable, returned text/JSON |
| `up`, `setup`, `create`, `image`, `start` | Command boundary; `up` adds restore preparation/install steps; long-running parent ends on return |
| `status`, `show`, `hide`, `pause`, `resume`, `stop`, `display` | Command boundary and result/failure, without duplicating host internals |
| `skills get/path/install` | Command boundary and returned content/location |
| `view` | Command boundary; opt-in manual actions are independent unless explicitly attached |
| `action` | Tool boundary starts before parsing, structured input updated after validation, guest child, response/exit intent |
| Unknown commands | Stable `execute-unknown-command` failure; no user input in observation names |
| `trace`, `chain`, `mcp` plumbing | Manage context or trace individual MCP tools; no noisy process-lifetime trace |
| `guest`, `__run` | No Langfuse initialization/export on internal runtime paths |

Expected process exit is recorded as 0/1 before `Entry` exits. Abrupt signals and
hard kills do not have a reliable exit acknowledgement. Output is captured through
application output helpers, not by intercepting stdout or storing terminal graphics.
`--context`, `--reason`, and `--actor` are optional on public commands; literal
arguments after `--` are not treated as tracing controls.

## Manual and Media Controls

```sh
./dist/terminal-mac view default --trace-manual --context TASK_HANDLE
```

Manual recording starts only with `--trace-manual` (also supported by `up`). The
header displays trace on/attached/paused/off. Ctrl+P toggles content capture pause;
Ctrl+T detaches/reattaches the supplied task context when pending input is drained.
Without an explicit context, actions stay independent and share a Viewer session.
Attached manual work has a dedicated child chain so it is not confused with AI work.

Pause suppresses sensitive text/key content and response text; timing and coarse
action summaries continue. Queued/in-flight calls that cross a pause boundary
cannot regain content capture when resumed. Already exported content cannot be
retracted by pausing. Queued input is recorded as merged calls with first/last
sequence and merge count; dropped input is a warning with `executed: false`.
Native VM-window input and host-global input remain outside collection.

Media settings, separate from content mode:

```dotenv
LANGFUSE_MEDIA_ENABLED=true
LANGFUSE_MEDIA_UPLOAD_HOSTS=exact-storage-host.example.com
```

Images are limited to 2 MiB and PNG/JPEG, not persisted locally for media retries.
Upload API/PUT/PATCH each has a two-second timeout; failures never change the
desktop screenshot response. Uploads are opt-in, cannot mask private screen content,
and need a configured storage bucket. Exact storage hosts must be explicitly
allowed (the configured Langfuse host is allowed). Redirects are disabled and no
project keys/cookies go to storage. A failed media upload records `unavailable`.

HTTP 408/429/5xx and transport errors retry with bounded backoff. Other HTTP
failures, including authentication and redirects, defer retries for one hour and
emit sanitized endpoint/authentication diagnostics. End-to-end fault injection
now exercises the official OTLP exporter and diagnostic HTTP client through local
URL protocol substitutes. Tests verify that failed records remain queued, retry
with the same observation IDs, and never replay a desktop operation. Actual proxy
and deployment outage behavior remains an operational acceptance item.

### Reliability Handoff

The final signed `0.2.1` package passed the five-node v3.188.0 EE read-back audit:
`96c5591b34f6dbd58f342d387edc0928`.
All twelve checks pass; returned release is `0.2.1` and queue pending/failed/dropped
and open-context counts are zero. No desktop actions or media were sent in this probe.

An earlier final-package attempt, `a10d5e278d19bd6469d9740649be2809`, failed
export and timed out read-back. Its five records remain in the isolated temporary
test store `terminal-mac-tracing-audit-Or0BLm`, with one attempt each and delayed
retry; the exact HTTP cause was not captured by the audit script. Subsequent
isolated debug/package probes exported successfully, and the fresh final read-back
above passes. This is not proof of uninterrupted delivery; the failed records were
not discarded or forced through retry backoff.

Automated fault tests cover offline transport, HTTP 401/403/404/302/408/429/500/503,
retry scheduling, record count overflow, lease separation between batches,
pending-record deduplication, retention expiry, corrupted/future/symlinked stores,
file-lock contention, simulated write denial, and idempotent shutdown. A synthetic
permission-denied write leaves the previous atomic state intact; it is not a real
disk-exhaustion or power-loss test.

Closed context eviction prevents the 256-context bound from exhausting after
many completed chains. It preserves open tasks, but idempotent end can only find
closed handles that remain retained; evicted handles return a context error.
Constructor failures close their file descriptors. Shutdown marks tracing inactive
and makes later normal operations uninstrumented. Media HTTP sessions are released
after upload attempts, and client-facing error explanations are not overwritten
by raw transport errors in the recorded result.

## Remaining Work

- Continue using the explicit v3 observation read adapter for the current deployment.
  Revalidate v4 reads when the server is upgraded; no upgrade is required for the
  verified task/chain/tool/error tracing behavior. Keep OTLP runtime ingestion.
- Measure interactive performance and stronger crash durability separately.
  The local fault matrix is automated; real disk exhaustion, power loss, and
  prolonged proxy outages have not been tested. Timing metadata is not a latency benchmark.
- Validate real screenshot media with the deployment's actual storage settings,
  and verify media rendering. No private screen has been uploaded.
- Test an actual person using terminal Viewer: ordering, attachment, pause,
  header layout, responsiveness, and real backend read-back of manual actions.
  Unit tests exercise manual tracing primitives, not the complete interactive UI.
- Complete an actual AI-client plugin test and global rollout. The installed
  `/Applications/TerminalMac.app` and global plugin/skill were not replaced.
- Review child-before-parent visibility while a task remains open, duplicate
  delivery behavior, and long-lived parent visibility on this v3 deployment.

Content mode and manual/media recording are opt-in. Summary mode and the kill
switch remain conservative defaults. The overall plan is not marked complete.

## Next Acceptance Session

The next steps need a person at the interactive terminal and a non-sensitive guest
screen. Launch the new `dist/terminal-mac`, enable the desired content policy
explicitly, create a task, then use `view --trace-manual --context HANDLE` to test
attach/detach and pause while performing harmless actions. Confirm the header,
queue ordering, and resulting Langfuse observations. Media remains off unless its
storage host and screenshot privacy have been confirmed separately.

The PATH-selected installed program is still
`/Applications/TerminalMac.app/Contents/MacOS/terminal-mac` from the previous
installation. Use the repository's `dist/terminal-mac` for acceptance or explicitly
approve replacing that installed app, then update/reinstall the matching plugin
and restart the client's MCP server. Global application and plugin replacement
were intentionally not performed during automated acceptance.
