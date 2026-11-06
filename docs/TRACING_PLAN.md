# Hierarchical Tracing: Development and Acceptance Plan

Status: P1/P2 foundations and P3 plugin/skill implementation are present; P4 manual
Viewer recording is implemented but awaits interactive acceptance. Isolated error
and real guest read-only success traces pass on v3.188.0 EE. P5 full acceptance
and global rollout remain pending, owned by the user's client test session.
Field presentation tuning is deferred; see [TRACING_CLIENT_TEST.md](TRACING_CLIENT_TEST.md)
and [TRACING_PROGRESS.md](TRACING_PROGRESS.md).

This document plans the next tracing iteration. [TRACING.md](TRACING.md) describes
the existing implementation; its recorded test results do not validate this plan.
Current interfaces and limits are recorded in [TRACING_PROGRESS.md](TRACING_PROGRESS.md).
Other interfaces below remain proposed.

## 1. Objective

Make it possible to answer: what was the task, why was an action requested, what
input was executed, what result was returned, and did a person intervene?

- Group observations into a meaningful task/chain/tool tree.
- Capture requests and actual responses automatically in MCP and CLI execution.
- Let AI callers optionally provide task context and brief action reasons.
- Record manual terminal Viewer actions in their observed execution order.
- Preserve existing command behavior when tracing is disabled or unavailable.
- Verify actual Langfuse ingestion by reading back traces, not just by compiling.

## 2. Existing Foundations

| Component | Current behavior | Planned extension |
| --- | --- | --- |
| `Sources/TerminalMacTracing/` | OTLP export, dotenv, redacted per-tool traces | Context lifecycle, content policy, durable delivery |
| `Sources/TerminalMac/AgentServer.swift` | MCP desktop tools and guest spans | Task/chain tools, optional context/reason, response capture |
| `Sources/TerminalMac/CLI.swift` | Tracing around CLI `action` execution | Equivalent tracing commands and wider command coverage |
| `Sources/TerminalMac/Entry.swift` | Shutdown for MCP and action paths | Consistent lifecycle handling for traced entry points |
| `Sources/TerminalMac/Viewer.swift` | Manual input queue and local activity | Human observations, queue outcomes, explicit task attachment |
| `skills/terminal-mac/SKILL.md` | Observe/act/verify guidance | Optional tracing workflow and compatibility examples |
| `.claude-plugin/plugin.json` | Launches `terminal-mac mcp` from PATH | Updated distribution and capability verification |

The installed Langfuse development skill helps implement and audit tracing. It
is not a runtime collector. Extend the existing terminal-mac MCP server rather
than requiring a second Langfuse MCP server.

Use the existing exact dependency baseline initially: OpenTelemetry Swift and
Swift Core `2.6.0`, and `swift-log` `1.15.1`. This preserves the current toolchain
compatibility constraint. Before implementation, check current official docs and
releases; record any necessary upgrade with exact versions and compatibility
tests. These baseline versions are not a claim about the latest available release.

## 3. Scope and Boundaries

### Required for this iteration

- Task and nested chain creation/completion, usable from MCP and CLI.
- All existing MCP desktop tools and public CLI command dispatch paths, including
  invalid arguments, execution failures, timeouts, and cancellation.
- Structured input and actual textual/JSON results under a configurable content
  policy; screenshots remain a separate opt-in media feature.
- Manual actions routed through terminal Viewer, including queued/dropped actions.
- Cross-process context, bounded local persistence, retry diagnostics, and recovery.
- Updated plugin/skill documentation and a real-deployment acceptance report.

Enumerate CLI commands during implementation. Public lifecycle, setup, diagnostic,
and skill commands belong in the coverage inventory. Internal `guest`/`__run`, MCP
handshake/ping/tool listing, viewer frame refreshes, and polling are not independent
business traces. Long-running commands need useful sub-operation boundaries rather
than a single span that remains invisible until the application exits.

### Explicitly deferred

- Capturing native `VZVirtualMachineView` keyboard/mouse input. This bypasses the
  terminal Viewer queue and requires a separate feasibility and privacy review.
- Host-wide input monitoring or collecting activity outside terminal-mac.
- Shell execution instrumentation inside the guest. Typing a shell command does
  not provide reliable process stdout/stderr or exit status.
- Automatic capture of an external AI client's model requests, responses, tokens,
  or costs. Those require integration at the actual model-call boundary.
- Continuous desktop video, guaranteed lossless recording, or business success
  inferred solely from a successful input event.

## 4. Observation Model

```text
session: conversation or explicitly grouped work
  trace: one task / agent run
    root: run-desktop-task
      chain: open-browser
        reason: Open the browser to inspect the official documentation.
        tool: execute-key-tool
          span: send-guest-key
        tool: execute-type-tool
          span: send-guest-type
        tool: execute-screenshot-tool
      span: manual-intervention (only when explicitly attached)
        tool: execute-click-tool [actor=human, source=viewer]
```

- Use `chain` for a real multi-step workflow, `tool` for actions, and `span` for
  execution/transport details. Reasons do not change an action's type to `chain`.
- A locally managed task root is a `span` unless it represents an explicitly
  reported agent run; record the provenance of caller-reported task information.
- A future real `generation` is a sibling of its requested tools under the
  orchestrating observation. Never synthesize model telemetry from a reason.
- Use stable operation names; place task descriptions, reasons, IDs, and sequence
  numbers in input/output or metadata, not dynamically generated names.
- Put task goal and final result on the root observation. Mark final results
  reported by the caller as such; execution acknowledgements are not verification.
- Propagate session, release, environment, source, and relevant filter attributes
  to child observations. Use observation input/output, not deprecated trace I/O.

## 5. Proposed Caller Contract

| MCP tool | CLI equivalent | Responsibility |
| --- | --- | --- |
| `trace_begin` | `terminal-mac trace begin` | Accept goal and optional session; return generated context |
| `chain_begin` | `terminal-mac chain begin` | Accept parent context, goal, optional reason; return child context |
| Existing desktop tool | Existing `action` command | Accept optional context/reason and capture execution automatically |
| `chain_end` | `terminal-mac chain end` | Record outcome and summary; close chain |
| `trace_end` | `terminal-mac trace end` | Record outcome and summary; close task |

Exact option spelling and response envelopes are frozen in stage P1. The common
contract must define these semantics:

- Context is an opaque program-generated handle. AI callers copy it unchanged;
  they do not invent trace/span IDs or send credentials.
- Reasons are brief audit explanations, not private chain-of-thought. They are
  optional, length-bounded, sanitized, and labeled with their source.
- Missing context creates an independent trace; missing reasons remain missing.
  Neither condition prevents normal tool execution.
- Invalid, expired, closed, or foreign context on a desktop action produces a
  diagnostic and an independent trace, without silently attaching elsewhere.
  Context-management commands return explicit errors for invalid handles.
- Never infer the parent from the most recently active chain or the VM name.
- Repeating an end request is idempotent and cannot overwrite a completed outcome.
- Define closure behavior for active children and in-flight tools. Do not end a
  parent successfully while silently abandoning its children.
- Return correlation data through a compatible MCP response field and an opt-in
  CLI envelope; preserve existing default CLI output, exit codes, and tool content.
- Capability discovery distinguishes upgraded binaries from older installations.
  The skill falls back to existing tools if tracing interfaces are absent.
- Disabling tracing must also disable content spooling and network delivery.
  Trace-management calls report disabled status without fabricating trace links.

For external instrumented callers, reserve an adapter for validated W3C trace
context. Choose one owner for each root/chain/tool observation so client and server
instrumentation do not create duplicate representations of the same action.

## 6. Execution, Persistence, and Privacy

### Correlation and ordering

Record receipt, validation, dispatch, guest completion, and response construction
with timestamps and stable request IDs. Record CLI exit outcomes at the boundary
that actually knows them. A written response is not proof the client consumed it.

Use MCP request IDs, generated invocation IDs, and guest request IDs in their
respective scopes. Associate every retry with the same logical observation ID.
Use monotonic time for local durations and wall-clock time for display; source-local
sequence numbers disambiguate ordering without claiming a total order across
concurrent processes. Capture `actor=human|ai|unknown` separately from transport;
CLI use alone does not establish that an action was human or AI initiated.

### Shared context and delivery

Choose one host-local context store shared by MCP, CLI, and Viewer, isolated by
data root and telemetry destination/project. Use structured serialization,
restricted permissions, atomic updates, and cross-process coordination. Do not
place credentials or trace payloads in guest-shared folders.

Persist logical observation identity and lifecycle, not live SDK objects. Prototype
reconstruction/export with the pinned SDK before expanding instrumentation; an
in-memory SDK span cannot survive a CLI process exiting. Keep finalized records
separate from open task state. Recover abandoned observations as interrupted,
without changing IDs, replaying actions, or manufacturing completion times.

Use a bounded outbox with retry/backoff and stable IDs. Specify queue capacity,
record size, age limit, overflow policy, and bounded shutdown time in P1. Distinguish
retryable failures from configuration/authentication failures. Expose pending,
failed, and dropped counts without leaking payloads. Never re-execute guest actions
when retrying telemetry. Test backend deduplication rather than promising exactly-once
delivery. Disk and network failures must not break desktop control.

### Content policy

- Preserve summary mode for existing installations. Enable content mode explicitly
  for this workflow; do not silently expand collection for existing users.
- In content mode, record actual parameters and returned text/JSON, applying
  sensitive-field filtering before export or persistence. Include brief sanitized
  errors as well as stable error categories.
- Apply the same policy to goals, reasons, metadata, diagnostic output, and outbox
  records. Do not dump the environment, `.env`, authentication headers, or raw argv.
- Define truncation limits and record original size, truncation, and redaction
  indicators. Text masking cannot guarantee discovery of every embedded secret.
- Screenshot upload has a separate switch, size/retention limits, and failure
  handling. Use documented Langfuse media handling after a compatibility spike;
  do not treat local file paths as remotely viewable images.
- Manual content collection requires explicit enablement and a visible pause or
  suppression mechanism for passwords, login, and other sensitive interactions.
  Do not rely on automatic password-field detection for safety.

## 7. Development Sequence

### P1: Context and lifecycle foundation

- [ ] Freeze schemas, limits, scope validation, disabled behavior, and status model.
- [x] Implement shared context storage and nested task/chain lifecycle.
- [x] Prove cross-process SDK span reconstruction and OTLP parent linkage.
- [x] Add begin/end interfaces with compatible capability discovery.
- [ ] Add recovery, outbox, and privacy primitives needed by subsequent stages.

Exit gate: two CLI processes and one MCP process can contribute to the same task
without duplicate roots, incorrect parents, or dependence on a process-global span.

### P2: Automatic MCP and CLI request/response capture

- [x] Implement optional context/reason on existing tools and CLI actions.
- [ ] Cover command validation, execution, guest responses, output, and failures.
- [x] Inventory every public CLI path; document deliberate exclusions.
- [x] Implement content/summary modes and correlation response compatibility.
- [ ] Validate screenshot media handling and its independent opt-in setting.

Exit gate: one chain containing several MCP/CLI actions shows real sanitized
inputs/results; callers omitting every new optional field still work unchanged.

### P3: Plugin and skill workflow

- [x] Document optional begin/act/verify/end usage and concise reason examples.
- [x] Add old-binary fallback, interruption, and explicit task-result guidance.
- [x] Update MCP descriptions, `docs/AGENT.md`, and plugin version as needed.
- [x] Verify the packaged skill and plugin skill describe the same protocol.

Exit gate: an AI client using the updated plugin can create a task and nested chain,
perform actions, and report a result without direct Langfuse credentials or SDK use.

### P4: Manual Viewer timeline

- [x] Instrument Viewer enqueue, merge, dispatch, completion, and drop paths.
- [x] Add explicit task attachment/detachment and independent manual sessions.
- [x] Record human provenance, ordering, pause state, and merge counts.
- [x] Keep continuous frame refresh and idle polling out of the action tree.
- [ ] Verify GUI responsiveness with tracing disabled, enabled, and offline.

Exit gate: manual intervention is visible in order and cannot be mistaken for an
AI action or silently attributed to an unrelated task. Native VM-window input
remains explicitly outside the coverage claim.

### P5: End-to-end acceptance and rollout

- [ ] Run automated tests and the fault-injection matrix below.
- [x] Build the packaged executable and verify its actual launcher path/version.
- [ ] Run a permitted live guest workflow, including Viewer intervention.
- [ ] Fetch exported observations from the configured Langfuse project and audit.
- [ ] Publish evidence and remaining limitations; update `TRACING.md` to match.
- [ ] Update installed binary and plugin/skill, restart MCP, and verify discovery.

## 8. Acceptance Matrix

| ID | Scenario | Required evidence |
| --- | --- | --- |
| A01 | One task, nested chains, multiple tools | Correct IDs, types, parents, root I/O, start/end timestamps |
| A02 | MCP and separate CLI processes share context | One logical tree; shared session; unique invocation IDs |
| A03 | Old caller omits context and reason | Same execution/output behavior; independent trace; missing reason marked |
| A04 | Invalid/expired/foreign context | Action still executes; diagnostic; no cross-task/project attachment |
| A05 | Invalid arguments, unknown tool, stopped VM | Failed observation where a command is identifiable; no secret-bearing raw input |
| A06 | Timeout, cancellation, guest error | Correct status/category; preserved original client-facing failure |
| A07 | Actual I/O and screenshots | Content mode matches sanitized results; summary mode and media-off remain private |
| A08 | Human intervention and independent manual work | Correct provenance, explicit parentage, sequence, queue/drop outcomes |
| A09 | Interleaved tasks and concurrent processes | No global-active-chain leakage, store corruption, or double finalization |
| A10 | Duplicate end, open children, crash/restart | Idempotent closure; defined child policy; interrupted recovery |
| A11 | Offline, HTTP 429/5xx, auth failure, disk full | Bounded queue/retry; diagnostics; no action re-execution or control failure |
| A12 | Secret fixtures and capture pause | Secrets absent from decoded OTLP, outbox, metadata, reasons, and diagnostics |
| A13 | Tracing disabled and sampling | No export/spool when disabled; consistent parent sampling; full-coverage run uses rate 1 |
| A14 | CLI/MCP output compatibility | No telemetry on stdout; old response consumers and exit codes unchanged |
| A15 | Real deployment read-back | Observations retrieved and inspected; final trace links and evidence recorded |
| A16 | Plugin/binary upgrade | PATH target, capability discovery, packaged skill, and restarted MCP agree |

Use focused unit tests for schema, lifecycle, privacy, and ordering; integration
tests for MCP stdio, CLI process boundaries, persistent storage, decoded OTLP,
and exporter faults. Validate completed child visibility while its parent is open,
then verify the tree after parent finalization. A successful HTTP response alone
does not establish that Langfuse rendered the expected hierarchy or media.

For Viewer performance, record comparable baseline and tracing-enabled input
latency/frame behavior; set a measurable regression threshold in P1. Do not claim
responsiveness from unit tests alone.

## 9. Live Acceptance Procedure

1. Verify the configured endpoint, credentials availability, binary path, and
   plugin capabilities without printing secrets. Use a dedicated test environment
   and non-sensitive content; enable sampling rate 1 for the coverage run.
2. Start a task and chain, perform MCP status/screenshot/action calls, and execute
   a CLI action under the same context. Verify a visible result before reporting
   task success; include a controlled failure in a separate chain.
3. Explicitly attach Viewer to the task, perform a manual action, detach it, then
   perform a separate manual action. Confirm only the attached action joins it.
4. Close chains/task and allow bounded flushing. Run interruption/retry tests
   separately using controlled fixtures, not destructive real guest actions.
5. Discover the current Langfuse CLI schema and query the exported observations.
   Confirm endpoint/API compatibility with the actual deployment rather than
   copying an outdated CLI command or assuming server deduplication behavior.
   For the configured v3.188.0 EE deployment, use the verified CLI snapshot
   `3.150.0` and v1 `/api/public/observations` read path via explicit audit option
   `--server-version 3.188.0`; keep the runtime OTLP exporter unchanged.
6. Fetch the latest official best-practices page, audit A01-A16, fix gaps, rerun,
   and read back again. Inspect screenshots visually when media capture is enabled.
7. Record build/dependency versions, deployment version when available, settings
   without secrets, test results, observation IDs/links, and remaining limitations.

Missing credentials, an unavailable guest, or an inaccessible backend must be
reported as unverified acceptance items, not replaced by a claim that unit tests
prove live ingestion. Isolated failure and read-only guest success acceptance have
been performed; manual Viewer/media and full workflow acceptance remain pending.

## 10. Packaging, Upgrade, and Rollback

The plugin invokes the executable found on PATH; reinstalling the plugin does not
rebuild or replace that executable. The repository build script also packages a
copy of the skill into the application bundle.

Upgrade in this order: build and test, install/select the new executable, update
the plugin/skill from the matching revision, configure the explicit environment
file if needed, restart MCP, then verify capabilities and a live trace. Reinstalling
an unchanged remote plugin cannot deliver unpublished local modifications.

Use the existing tracing kill switch for immediate telemetry rollback. Stop
exporting queued data while disabled. Document how to inspect/delete local tracing
state and how retention applies; do not delete VM data. Downgrades must detect an
unsupported store schema and disable tracing safely rather than corrupt state.

## References

- [Current implementation and configuration](TRACING.md)
- [Agent integration](AGENT.md)
- [Packaged agent skill](../skills/terminal-mac/SKILL.md)
- [Langfuse observation types](https://langfuse.com/docs/observability/features/observation-types)
- [Langfuse tracing best practices](https://langfuse.com/docs/observability/best-practices)
- [Langfuse OpenTelemetry integration](https://langfuse.com/integrations/native/opentelemetry)
- [Langfuse multi-modal observations](https://langfuse.com/docs/observability/features/multi-modality)
