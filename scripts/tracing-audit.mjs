import { readFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parseEnv } from "node:util";
import { spawnSync } from "node:child_process";
import { readContract, observationArgs, validateProbe } from "./tracing-audit-lib.mjs";

// Opt-in live audit using an isolated missing-VM path, never real desktop actions.
const executable = resolve(process.argv[2] ?? ".build/debug/terminal-mac");
const envFile = resolve(process.argv[3] ?? ".env");
const extraArgs = process.argv.slice(4);
const versionIndex = extraArgs.indexOf("--server-version");
const serverVersion = versionIndex === -1 ? "4" : extraArgs[versionIndex + 1];
const contract = readContract(serverVersion);
if (versionIndex !== -1) extraArgs.splice(versionIndex, 2);
if (extraArgs.length > 1 || (extraArgs[0] && !/^[0-9a-f]{32}$/.test(extraArgs[0]))) {
  throw new Error("Expected an optional existing trace ID and --server-version VERSION.");
}
const existingTraceID = extraArgs[0];
const apiVersion = contract.snapshot;
const readPath = contract.path;
const config = parseEnv(readFileSync(envFile, "utf8"));
const environment = { ...process.env };
for (const [key, value] of Object.entries(config)) {
  if (key.startsWith("LANGFUSE_") && !(key in environment)) environment[key] = value;
}
if (!environment.LANGFUSE_PUBLIC_KEY || !environment.LANGFUSE_SECRET_KEY) {
  throw new Error("Live audit requires locally configured project keys.");
}
environment.LANGFUSE_BASE_URL ??= environment.LANGFUSE_HOST;
if (!environment.LANGFUSE_BASE_URL) throw new Error("Explicit Langfuse base URL is required.");
const secrets = [environment.LANGFUSE_PUBLIC_KEY, environment.LANGFUSE_SECRET_KEY];
const sanitize = (value) => secrets.reduce((text, key) => text.replaceAll(key, "[REDACTED]"), value);
const root = mkdtempSync(join(tmpdir(), "terminal-mac-tracing-audit-"));
environment.TERMINAL_MAC_HOME = root;
environment.TERMINAL_MAC_ENV_FILE = envFile;
environment.LANGFUSE_TRACING_ENVIRONMENT = "tracing-acceptance";
environment.LANGFUSE_CONTENT_MODE = "content";
environment.LANGFUSE_MEDIA_ENABLED = "false";
environment.LANGFUSE_SAMPLE_RATE = "1";
environment.npm_config_cache = "/private/tmp/terminal-mac-npm";

function command(args, input) {
  const result = spawnSync(executable, args, { env: environment, encoding: "utf8", input, timeout: 15000 });
  if (result.error || result.signal) throw new Error("Audit process failed or exceeded its bounded runtime.");
  return { code: result.status, text: result.stdout, diagnostics: sanitize(result.stderr) };
}
function management(args) {
  const result = command(args);
  if (result.code !== 0) throw new Error(`Trace management failed: ${result.diagnostics}`);
  const object = JSON.parse(result.text);
  if (object.enabled === false) throw new Error("Tracing is disabled; check local configuration and storage.");
  return object;
}

let task;
let chain;
let completed = false;
function readBack(traceID) {
  const query = spawnSync("npx", ["--offline", "--yes", "@langfuse/cli", ...observationArgs(contract, traceID)],
    { env: environment, encoding: "utf8", timeout: 15000 });
  let envelope;
  try { envelope = JSON.parse(query.stdout); } catch { /* Local CLI failures do not return an API envelope. */ }
  if (query.status !== 0) {
    const message = envelope?.body?.message ?? query.stderr ?? "CLI failed";
    throw new Error(`Langfuse read-back failed (exit ${query.status}, HTTP ${envelope?.status ?? "unknown"}): ${sanitize(message).slice(0, 2000)}`);
  }
  const observations = envelope?.body?.data ?? envelope?.data?.data ?? envelope?.data;
  if (!Array.isArray(observations)) throw new Error("Unexpected CLI response envelope; inspect the current schema.");
  if (envelope?.body?.meta?.totalPages > 1 || envelope?.body?.meta?.cursor) {
    throw new Error("Audit trace exceeds one bounded page; refusing partial acceptance.");
  }
  return observations;
}
try {
  if (existingTraceID) {
    const observations = readBack(existingTraceID);
    console.log(sanitize(JSON.stringify({ trace_id: existingTraceID, server_version: serverVersion,
      cli_api_snapshot: apiVersion, read_path: readPath, observations }, null, 2)));
    rmSync(root, { recursive: true });
    process.exit(0);
  }
  const session = `audit-${Date.now()}`;
  task = management(["trace", "begin", "--goal", "Verify MCP and CLI tracing hierarchy", "--session", session]);
  chain = management(["chain", "begin", "--context", task.context, "--goal", "Check isolated VM readiness",
    "--reason", "Verify failure reporting without changing the real desktop"]);
  const request = JSON.stringify({ jsonrpc: "2.0", id: "audit-status", method: "tools/call",
    params: { name: "status", arguments: { context: chain.context, reason: "Check the isolated VM state" } } });
  const mcp = command(["mcp"], request + "\n");
  const response = JSON.parse(mcp.text);
  if (mcp.code !== 0 || !response.result.isError ||
      response.result._meta["terminal-mac/tracing"].trace_id !== task.trace_id) {
    throw new Error("MCP failure response or correlation did not match the task.");
  }
  const cli = command(["action", "default", "status", "--context", chain.context, "--reason", "Verify CLI linkage"]);
  if (cli.code !== 1 || cli.text !== "") throw new Error("CLI failure contract changed.");
  management(["chain", "end", "--context", chain.context, "--outcome", "failed", "--summary", "Expected missing-VM failure verified"]);
  management(["trace", "end", "--context", task.context, "--outcome", "success", "--summary", "Failure-path tracing probe completed"]);
  completed = true;

  // v3 uses asynchronous ingestion. Poll read-only for at most two minutes.
  const attempts = serverVersion.startsWith("3") ? 13 : 5;
  for (let attempt = 0; attempt < attempts; attempt++) {
    const observations = readBack(task.trace_id);
    if (observations.length >= 5) {
      const audit = validateProbe(observations, { traceID: task.trace_id, taskID: task.observation_id,
        chainID: chain.observation_id, mcpID: response.result._meta["terminal-mac/tracing"].observation_id,
        session }, secrets);
      const pending = management(["trace", "status"]);
      if (pending.pending !== 0) throw new Error("Read-back succeeded but the outbox has pending records; retaining test store.");
      const traceURL = new URL(`project/${audit.projectID}/traces/${task.trace_id}`,
        environment.LANGFUSE_BASE_URL.replace(/\/?$/, "/")).href;
      console.log(sanitize(JSON.stringify({ status: "passed", trace_id: task.trace_id, observation_count: observations.length,
        server_version: serverVersion, cli_api_snapshot: apiVersion, read_path: readPath,
        trace_url: traceURL, checks: audit.checks,
        observations: observations.map(({ id, name, type, parentObservationId, level, statusMessage, input, output, metadata }) =>
          ({ id, name, type, parentObservationId, level, statusMessage, input, output, metadata })),
        delivery: pending }, null, 2)));
      rmSync(root, { recursive: true });
      process.exit(0);
    }
    if (attempt + 1 < attempts) {
      await new Promise((resolve) => setTimeout(resolve, serverVersion.startsWith("3") ? 10000 : 2000));
      management(["trace", "status"]);
    }
  }
  throw new Error("Read-back did not return the five expected observations within the audit window.");
} catch (error) {
  let delivery;
  if (task) {
    try { delivery = management(["trace", "status"]); } catch { /* Preserve the original audit failure. */ }
  }
  console.error(sanitize(JSON.stringify({ status: "unverified", message: error.message, trace_id: task?.trace_id,
    task_finalized: completed, delivery, retained_test_store: root })));
  process.exitCode = 1;
}
