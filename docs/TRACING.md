# Langfuse tracing

`terminal-mac` is a computer-use MCP server, not an LLM client. Calls without
context create separate traces; optional task/chain context links MCP tools and
CLI actions across processes. Guest-mailbox spans remain children of tools.
Model/token/cost telemetry belongs in the caller's integration; this server does
not fabricate generations. It is ready for client-driven acceptance; see
[TRACING_PROGRESS.md](TRACING_PROGRESS.md) for interfaces, limits, and successful
isolated failure and real-guest read-only success verification against v3.188.0 EE.
Client upgrade/configuration and interactive checks are in
[TRACING_CLIENT_TEST.md](TRACING_CLIENT_TEST.md).

## Setup

Create a Langfuse project and a project API key pair under Settings > API Keys.
Set the following in a local `.env` file, using your actual keys locally, never
in source control or chat:

```dotenv
LANGFUSE_BASE_URL=https://cloud.langfuse.com
LANGFUSE_PUBLIC_KEY=pk-lf-REPLACE_LOCALLY
LANGFUSE_SECRET_KEY=sk-lf-REPLACE_LOCALLY
LANGFUSE_TRACING_ENVIRONMENT=development
```

Use `https://us.cloud.langfuse.com` for US Cloud, `https://jp.cloud.langfuse.com` for
Japan Cloud, or your own HTTPS deployment URL. Self-hosted path prefixes are supported.
HTTP is allowed for loopback development endpoints, such as
`http://127.0.0.1:3000`. Trusted internal HTTP deployments additionally require
`LANGFUSE_ALLOW_INSECURE_HTTP=true`. That opt-in emits a warning: HTTP sends project
keys and telemetry without encryption. Prefer HTTPS whenever it is available.
`LANGFUSE_HOST` is a fallback alias for `LANGFUSE_BASE_URL`.
The URL must be the deployment base, not the OTLP endpoint.

The Swift application reads `.env` from the process working directory when tracing
initializes. Set `TERMINAL_MAC_ENV_FILE=/absolute/path/.env` in the MCP server's
environment when its working directory differs (for example, when launched from
the Dock). No parent-directory or home-directory search is performed.
Process environment settings override the file, including an explicit
`LANGFUSE_TRACING_ENABLED=false` kill switch and an overridden host alias.
Only the supported Langfuse keys are loaded; unrelated dotenv settings are ignored
and the process environment is not mutated or forwarded to the guest.

The file supports `KEY=value`, optional `export`, single/double quotes, comments,
and common double-quoted escapes. It does not execute shell expressions, expand
variables, or accept multiline values. Files must be regular UTF-8 files of at
most 64 KiB; symlinks and hardlinks are rejected. Malformed configuration produces
a sanitized warning without echoing values. Keep local credential files at mode
`600`; `.env` is ignored by Git. `.env.example` lists all supported settings.
`terminal-mac mcp --config` deliberately does not print credentials.

Rebuild with `bash scripts/build.sh` to update the packaged launcher. Then start
the MCP server with your normal client or run a CLI action:

```sh
./dist/terminal-mac action default status
```

Public CLI command boundaries now include lifecycle/setup/diagnostic commands and
validation failures. Guest helper/internal VM runtime, viewer frames, polling,
MCP initialization, and tool listing are excluded. Viewer manual input is captured
only with `view --trace-manual`; see the progress report for pause/attachment controls.

## Context And Privacy

- Stable observation names such as `execute-click-tool` and `send-guest-click`
  keep dashboard and evaluation filters reusable. Unknown tool names are normalized.
- Input includes the tool, numeric coordinates, click counts, and screenshot flags.
  In default summary mode, typed text and key chords are redacted. Explicit
  `LANGFUSE_CONTENT_MODE=content` captures sanitized text/JSON under bounded limits.
- Summary output contains success indicators, content-block counts, permission booleans,
  and available image dimensions. MCP screenshots also include dimensions and byte
  counts as metadata. Image bytes/base64 are not exported in ordinary content mode.
  Independent `LANGFUSE_MEDIA_ENABLED=true` enables bounded media upload; use the
  storage host allowlist and review screen privacy before enabling. Content mode includes
  sanitized response text, guest values, and errors; do not assume it has the same
  privacy boundary as summary mode. See the progress report for remaining limits.
- Errors and cancellation are recorded using fixed categories, without changing
  the original error or MCP response. A category can be investigated locally using
  the original CLI/MCP error. Summary mode excludes private guest error strings;
  content mode includes a sanitized, bounded error message.
- Each MCP server process uses a random session ID to group related calls. For a
  conversation spanning processes or CLI actions, set an opaque `LANGFUSE_SESSION_ID`.
  An optional `LANGFUSE_USER_ID` supports cost/usage attribution in combined analyses.
  Neither is inferred from the host login, VM name, or authenticated guest accounts.
  Explicit IDs are sent to Langfuse; never put personal information or secrets in them.
- Release, environment, feature, channel tags, and session/user IDs are copied to
  every child span so Langfuse v4 observation-level filters work.

This privacy-first summary intentionally cannot replay the desktop or evaluate
screen content. Instrument the calling agent separately when full model context
is needed, with an appropriate privacy policy and masking.

## Export Behavior

Tracing is disabled without credentials. Partial or invalid configuration emits
a sanitized stderr warning and leaves computer-use functionality available.
`LANGFUSE_TRACING_ENABLED=false` is an explicit kill switch. `LANGFUSE_SAMPLE_RATE`
is a root trace sampling ratio from `0` to `1` (default `1`); children inherit their
parent's decision. Set `LANGFUSE_TRACING_ENVIRONMENT` to separate production and
development traffic (default `development`).

The integration pins OpenTelemetry Swift and Swift Core to `2.6.0` for current
toolchain compatibility. It uses the official OTLP/HTTP protobuf
exporter at `/api/public/otel/v1/traces`, project-key Basic authentication, and the
`x-langfuse-ingestion-version: 4` header. It does not use the deprecated custom
ingestion API. Generic `OTEL_EXPORTER_OTLP_HEADERS` cannot replace the configured
Langfuse project's authentication.

The transitive `swift-log` dependency is pinned to the SDK's required `1.15.1`:
newer logging releases use compiler attributes unavailable in the local Swift 6.2
toolchain. `Package.resolved` records all resolved dependency versions.

Spans are batched every two seconds with a 256-span in-memory queue, then persisted
in a bounded host-private outbox. Failed network batches retry with stable IDs;
overflow/age limits can still drop records. See the progress report for precise
limits. A network outage never fails a computer-use operation. Stdout stays
reserved for CLI results and MCP JSON-RPC. Normal MCP EOF and CLI success/error
exits shut down the provider and flush queued spans off the main actor. Abrupt
termination, including signals and hard kills, can lose in-flight spans. No keys
are copied into the guest exchange directory or forwarded to the guest helper.

## Verification

`swift test` includes configuration, privacy allowlisting, nested multi-click
spans, session grouping, redacted error propagation, disabled/sampled tracing,
an MCP missing-VM path, and a decoded official OTLP export payload. These local
tests do not prove a live Langfuse deployment accepted the traces or that a real
guest desktop was controlled.

Dotenv tests cover quoting/comments, literal shell expressions, environment
precedence, explicit file paths, the kill switch, malformed input, file-boundary
checks, and explicit internal HTTP opt-in.

Historical baseline verification on November 6, 2026, before the hierarchical
iteration (current progress is recorded separately):

- All 33 XCTest tests passed, including 13 tracing tests.
- The optimized release build passed. The existing packaged `dist` app was not
  replaced; rebuild it with `bash scripts/build.sh` before enabling tracing there.
- The compiled MCP executable passed a loopback HTTP smoke test: disabled tracing
  sent nothing; enabled tracing flushed real OTLP requests on EOF; typed text and
  credentials were absent from the payload; HTTP 503 produced a stderr warning
  without changing MCP responses or the exit code.
- No Langfuse project credentials were configured, so Cloud/self-hosted ingestion
  and a live trace read-back audit remain unverified. No real guest actions were run.

To complete a live audit after credentials are configured, run a `status` call
(even the missing/stopped VM error path creates a trace) and a permitted action
on a configured guest. In Langfuse's Observations view, check the root input/output,
nesting, timestamps, types, release/environment, session grouping, and redaction.
Check the current guidance at:

- https://langfuse.com/docs/observability/best-practices
- https://langfuse.com/integrations/native/opentelemetry

Use the current Langfuse CLI schema and a deployment-compatible observation API.
For this self-hosted v3.188.0 EE instance, explicit audit option
`--server-version 3.188.0` selects the verified v1 observation endpoint. v4/v2
remains the default for v4 deployments. Runtime ingestion stays OTLP in both cases;
do not switch to deprecated custom ingestion or trace-read endpoints.
