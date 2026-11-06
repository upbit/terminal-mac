export function readContract(serverVersion) {
  if (!/^(3|4)(?:\.\d+\.\d+)?$/.test(serverVersion ?? "")) {
    throw new Error("--server-version must be 3, 4, or a semantic version in those majors.");
  }
  if (serverVersion.startsWith("3")) {
    // Keep the bundled contract older than the deployed server. This v1 path was
    // also verified against the v3.188.0 deployment's generated OpenAPI spec.
    if (serverVersion !== "3" && Number(serverVersion.split(".")[1]) < 150) {
      throw new Error("This audit adapter supports v3.150.0 and newer v3 servers.");
    }
    return { snapshot: "3.150.0", path: "/api/public/observations", version: "v1" };
  }
  return { snapshot: "latest", path: "/api/public/v2/observations", version: "v2" };
}

export function observationArgs(contract, traceID, now = Date.now()) {
  if (!/^[0-9a-f]{32}$/.test(traceID)) throw new Error("Invalid audit trace ID.");
  const options = contract.version === "v1" ? ["--page", "1"] : ["--fields", "core,basic,io,metadata,trace_context"];
  return ["--api-version", contract.snapshot, "api", "observations", "list", "--trace-id", traceID,
    "--from-start-time", new Date(now - 7 * 24 * 3600 * 1000).toISOString(),
    "--to-start-time", new Date(now + 60000).toISOString(), ...options, "--limit", "100", "--json"];
}

function object(value) {
  if (typeof value === "string") {
    try { return JSON.parse(value); } catch { return null; }
  }
  return value;
}

export function validateProbe(observations, expected, secrets = []) {
  const assert = (condition, message) => {
    if (!condition) throw new Error(`Read-back audit failed: ${message}`);
  };
  assert(Array.isArray(observations) && observations.length === 5, "expected exactly five observations");
  assert(new Set(observations.map((item) => item.id)).size === 5, "duplicate observation IDs");
  assert(observations.every((item) => item.traceId === expected.traceID), "trace identity mismatch");
  const root = observations.find((item) => item.name === "run-desktop-task");
  const chain = observations.find((item) => item.name === "execute-desktop-chain");
  const tools = observations.filter((item) => item.name === "execute-status-tool");
  const guest = observations.find((item) => item.name === "send-guest-status");
  assert(root && chain && tools.length === 2 && guest, "missing expected operations");
  assert(!root.parentObservationId && chain.parentObservationId === root.id, "root/chain parent mismatch");
  assert(tools.every((item) => item.parentObservationId === chain.id), "tool parent mismatch");
  const mcp = tools.find((item) => object(item.metadata)?.source === "mcp");
  const cli = tools.find((item) => object(item.metadata)?.source === "cli");
  assert(mcp && cli && guest.parentObservationId === mcp.id, "MCP/CLI/guest linkage mismatch");
  assert(root.type === "SPAN" && chain.type === "CHAIN" && guest.type === "SPAN" &&
    tools.every((item) => item.type === "TOOL"), "observation type mismatch");
  if (expected.taskID) assert(root.id === expected.taskID, "task ID changed on ingestion");
  if (expected.chainID) assert(chain.id === expected.chainID, "chain ID changed on ingestion");
  if (expected.mcpID) assert(mcp.id === expected.mcpID, "response correlation ID mismatch");
  assert(object(root.input)?.goal === "Verify MCP and CLI tracing hierarchy", "root goal missing");
  assert(object(root.output)?.outcome === "success" && object(root.output)?.summary === "Failure-path tracing probe completed",
    "caller-reported root result missing");
  assert(object(chain.input)?.goal === "Check isolated VM readiness" && object(chain.output)?.outcome === "failed",
    "chain goal/result missing");
  assert(object(chain.metadata)?.reason === "Verify failure reporting without changing the real desktop", "chain reason missing");
  assert(object(mcp.metadata)?.call_id === "audit-status" && object(mcp.metadata)?.reason === "Check the isolated VM state",
    "MCP correlation/reason missing");
  assert(object(cli.metadata)?.reason === "Verify CLI linkage", "CLI reason missing");
  for (const item of observations) {
    const start = Date.parse(item.startTime), end = Date.parse(item.endTime);
    assert(Number.isFinite(start) && Number.isFinite(end) && end >= start, "invalid observation timing");
    const metadata = object(item.metadata);
    assert(item.environment === "tracing-acceptance", "environment not propagated");
    const session = item.sessionId ?? metadata?.attributes?.["langfuse.session.id"];
    assert(session && (expected.session ? session === expected.session : true), "session not propagated");
    const release = item.release ?? metadata?.attributes?.["langfuse.release"];
    assert(release && (expected.release ? release === expected.release : true), "release not propagated");
    if (item.parentObservationId) {
      const parent = observations.find((candidate) => candidate.id === item.parentObservationId);
      assert(parent && start >= Date.parse(parent.startTime) && end <= Date.parse(parent.endTime), "child outside parent time range");
    }
    if (item !== root) assert(item.level === "ERROR", "expected failure status missing");
    if (tools.includes(item) || item === guest) {
      assert(object(item.input)?.tool === "status" && object(item.output)?.ok === false &&
        object(item.output)?.error === "tool-failed" && typeof object(item.output)?.message === "string",
        "actual failure input/output missing");
    }
  }
  const payload = JSON.stringify(observations);
  assert(secrets.filter(Boolean).every((secret) => !payload.includes(secret)), "credential present in returned observations");
  const projectID = root.projectId;
  assert(projectID, "project ID missing");
  return { root, chain, projectID, checks: ["identity", "hierarchy", "types", "input-output", "reason",
    "request-correlation", "timestamps", "session", "release", "environment", "error-status", "credentials-absent"] };
}
