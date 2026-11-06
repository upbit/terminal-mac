import { strict as assert } from "node:assert";
import { test } from "node:test";
import { readContract, observationArgs, validateProbe } from "./tracing-audit-lib.mjs";

const traceID = "a".repeat(32);
function fixture() {
  const base = { traceId: traceID, projectId: "test-project", environment: "tracing-acceptance", level: "ERROR",
    startTime: "2026-11-06T06:00:01.000Z", endTime: "2026-11-06T06:00:02.000Z" };
  const metadata = { attributes: { "langfuse.session.id": "test-session", "langfuse.release": "dev" } };
  const failure = { ok: false, error: "tool-failed", message: "VM is unavailable" };
  return [
    { ...base, id: "root", name: "run-desktop-task", type: "SPAN", level: "DEFAULT", parentObservationId: null,
      startTime: "2026-11-06T06:00:00.000Z", endTime: "2026-11-06T06:00:04.000Z", metadata,
      input: { goal: "Verify MCP and CLI tracing hierarchy" },
      output: { outcome: "success", summary: "Failure-path tracing probe completed" } },
    { ...base, id: "chain", name: "execute-desktop-chain", type: "CHAIN", parentObservationId: "root",
      endTime: "2026-11-06T06:00:03.000Z",
      metadata: { ...metadata, reason: "Verify failure reporting without changing the real desktop" },
      input: { goal: "Check isolated VM readiness" }, output: { outcome: "failed" } },
    { ...base, id: "mcp", name: "execute-status-tool", type: "TOOL", parentObservationId: "chain",
      metadata: { ...metadata, source: "mcp", call_id: "audit-status", reason: "Check the isolated VM state" },
      input: { tool: "status" }, output: failure },
    { ...base, id: "cli", name: "execute-status-tool", type: "TOOL", parentObservationId: "chain",
      metadata: { ...metadata, source: "cli", reason: "Verify CLI linkage" }, input: { tool: "status" }, output: failure },
    { ...base, id: "guest", name: "send-guest-status", type: "SPAN", parentObservationId: "mcp",
      metadata, input: { tool: "status" }, output: failure }
  ];
}
const expected = { traceID, taskID: "root", chainID: "chain", mcpID: "mcp", session: "test-session", release: "dev" };

test("v3.188.0 selects the verified v1 read contract without v2 field parameters", () => {
  const contract = readContract("3.188.0");
  assert.equal(contract.snapshot, "3.150.0");
  assert.equal(contract.path, "/api/public/observations");
  const args = observationArgs(contract, traceID, Date.parse("2026-11-06T06:00:00Z"));
  assert(!args.includes("--fields"));
  assert(args.includes("--page"));
  assert(args.includes("2026-10-30T06:00:00.000Z"));
  assert(args.includes("2026-11-06T06:01:00.000Z"));
});

test("v4 stays on v2 and invalid version/trace input fails before a request", () => {
  const contract = readContract("4");
  assert.equal(contract.path, "/api/public/v2/observations");
  assert(observationArgs(contract, traceID).includes("--fields"));
  for (const version of ["3.20.0", "2", "auto", "3.188", undefined]) assert.throws(() => readContract(version));
  assert.throws(() => observationArgs(contract, "not-a-trace"));
});

test("complete v3 objects and v4 serialized I/O pass the same audit", () => {
  const observations = fixture();
  assert.equal(validateProbe(observations, expected).checks.length, 12);
  const serialized = observations.map((item) => ({ ...item, input: JSON.stringify(item.input), output: JSON.stringify(item.output) }));
  assert.equal(validateProbe(serialized, expected).projectID, "test-project");
});

test("audit detects wrong parent, type, omitted reason, session, timing, I/O, and credentials", () => {
  const changes = [
    (items) => { items[2].parentObservationId = "root"; },
    (items) => { items[1].type = "SPAN"; },
    (items) => { items[1].metadata.reason = undefined; },
    (items) => { items[2].metadata.attributes["langfuse.session.id"] = "wrong"; },
    (items) => { items[4].endTime = "2026-11-06T06:10:00Z"; },
    (items) => { items[0].output = null; },
    (items) => { items[3].output.message = "credential-fixture"; },
    (items) => { items.push({ ...items[0] }); }
  ];
  for (const change of changes) {
    const items = structuredClone(fixture());
    change(items);
    assert.throws(() => validateProbe(items, expected, ["credential-fixture"]), /Read-back audit failed/);
  }
});
