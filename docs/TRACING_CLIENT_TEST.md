# Client Upgrade and Interactive Acceptance

The tracing implementation is ready for client-driven testing, not a claim that
every acceptance item in [TRACING_PLAN.md](TRACING_PLAN.md) has passed. Field
presentation tuning is deferred until real client feedback is available.

## 1. Use the Matching Binary and Plugin

The repository plugin and packaged executable are `0.2.1`, build 7. The plugin
starts `terminal-mac mcp` through the client's PATH; updating a cached plugin does
not replace an old executable. The repository's unpublished changes will not be
present in a reinstall of an unchanged remote plugin.

For the first test, register the absolute launcher path from this checkout:

```sh
./dist/terminal-mac version
./dist/terminal-mac mcp --config
```

Expected version: `terminal-mac 0.2.1`. Use the matching local plugin revision or
the updated release when it is published. Do not change VM data or restart the
VM merely to update the host-side MCP integration. The old guest helper supports
the existing computer-use actions exercised by these tests.

In the client's MCP server environment, explicitly set the absolute path to the
local credential file. The example configuration contains paths, not keys:

```json
{
  "mcpServers": {
    "terminal-mac": {
      "command": "/absolute/path/to/terminal-mac/dist/terminal-mac",
      "args": ["mcp", "default"],
      "env": {
        "TERMINAL_MAC_ENV_FILE": "/absolute/path/to/terminal-mac/.env"
      }
    }
  }
}
```

Adjust the client's configuration format as necessary. Restart its MCP process
and open a fresh conversation if it caches tool schemas or skills. Do not paste
project keys into the chat, plugin files, or guest environment.

## 2. Verify Discovery and Configuration

The restarted MCP server should expose 13 tools: the eight existing desktop tools
plus `trace_begin`, `chain_begin`, `chain_end`, `trace_end`, and `trace_status`.
Desktop tools should have optional `context`, `reason`, and `actor` arguments.

Call `trace_status`. `enabled: true` confirms local configuration/storage is usable,
not that the backend has accepted the next trace. Check pending/failed/dropped
counters before and after the run. Unrelated previous work may affect these counts.

For CLI calls from another working directory, use the same explicit environment
file and data root as the MCP process. Otherwise the context may not be found.
Session IDs must be opaque and free of private information.

Summary mode remains the default. To inspect non-sensitive input/output during
testing, explicitly select `LANGFUSE_CONTENT_MODE=content` in the local configuration
or MCP environment, then restart MCP. Leave `LANGFUSE_MEDIA_ENABLED` off for the
initial test. Text masking cannot guarantee detection of every embedded secret.

## 3. AI Task Test

Use a non-sensitive guest page or disposable document. Ask the agent to:

1. Create a trace with a clear task goal.
2. Create a chain with a short action purpose in `reason`.
3. Use `status`, `screenshot`, and harmless desktop actions under the returned
   chain context, with `actor: "ai"` and brief reasons where useful.
4. Verify the visible result, then end the chain and task with an honest outcome
   and summary. Do not treat "Done" as evidence of business success.
5. Report the returned trace ID, any failed tool call, and the final outcome.

Do not invent IDs. AI cooperation is optional; a missing reason or context must
not stop otherwise permitted desktop work. Tools without context should still
create independent traces. Do not reuse a context for an unrelated task.

In Langfuse v3.188.0 EE, inspect task -> chain -> tool -> guest parentage. Check
both a success and a safe failure path. Field formatting can be tuned after
collecting this feedback; missing or incorrect parents are correctness failures.

## 4. Manual Viewer Test

Leave an explicitly created task open and provide its context to the terminal:

```sh
env TERMINAL_MAC_ENV_FILE=/absolute/path/to/.env \
  ./dist/terminal-mac view default --trace-manual --context TASK_HANDLE
```

- Verify the header's trace state. Perform harmless clicks, text input, and
  scrolling; confirm the separate human branch and action order in Langfuse.
- Wait for pending input to drain. Ctrl+T detaches; the next actions should be
  independent, not accidentally nested under the AI task. Ctrl+T reattaches
  only to the explicitly supplied context if it is still open.
- Ctrl+P pauses content capture. Test with a synthetic private string, not a real
  password. Resume with Ctrl+P and confirm paused text/results are not exported.
  Already exported records cannot be retracted by pausing.
- Exit with Ctrl+]. Confirm the human branch closes, then end the original task.
  Compare input/frame responsiveness with tracing off, on, and temporarily offline.

Tracing flags reserve Ctrl+P/Ctrl+T only in the opt-in Viewer. Continuous frames,
native VM-window input, and host-global input are not collected. The Viewer queue
may merge adjacent input; compare first/last sequence, merge count, and drop outcome
instead of expecting one observation per physical keypress.

## 5. Optional Screenshot Media Test

Perform this separately on a confirmed non-sensitive screen. Enable
`LANGFUSE_MEDIA_ENABLED=true` and allow the exact presigned storage hostname with
`LANGFUSE_MEDIA_UPLOAD_HOSTS`. The self-hosted deployment must have media object
storage configured. Do not allow a wildcard host or alter server permissions as
part of an ordinary desktop test.

PNG/JPEG images are capped at 2 MiB. `media_status: uploaded` and an inline media
reference should render the screenshot. `unavailable` must not change the tool's
screenshot result. Media upload is best-effort; no local screenshot retry archive
is kept, and image content is not automatically masked.

## 6. Read-Back and Feedback

The known deployment is self-hosted v3.188.0 EE. The audit adapter explicitly uses
the v1 observation API; the CLI's older bundled `3.150.0` read contract is verified
against this deployment. Runtime writes remain OTLP. Query one recent trace:

```sh
node scripts/tracing-audit.mjs ./dist/terminal-mac .env TRACE_ID --server-version 3.188.0
```

The query is limited to 100 observations and a seven-day window. The stock isolated
audit checks its own fixed five-node fixture; querying a client trace only reads
its observations. Review the client trace's actual tree and results separately.

Record the client/plugin/binary versions, trace ID/link, expected and observed
tree, missing data, Viewer responsiveness, and any sanitized stderr diagnostics.
Do not include secrets or private screenshots in the feedback. Distinguish client
schema/configuration errors, guest availability errors, export failures, and field
presentation preferences.

Immediate rollback: set `LANGFUSE_TRACING_ENABLED=false` and restart MCP. Omit
`--trace-manual` for the next Viewer session. This does not delete VM data or prior
Langfuse records. An old global executable remains unchanged by this repository's
build; do not assume a plugin refresh changed it.
