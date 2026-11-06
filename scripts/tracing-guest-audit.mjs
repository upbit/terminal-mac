import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parseEnv } from "node:util";
import { spawnSync } from "node:child_process";
import { readContract, observationArgs } from "./tracing-audit-lib.mjs";

// Explicit live acceptance: reads guest permissions only, never screenshots or input.
const executable = resolve(process.argv[2] ?? "dist/terminal-mac");
const envFile = resolve(process.argv[3] ?? ".env");
const environment = { ...parseEnv(readFileSync(envFile, "utf8")), ...process.env,
  TERMINAL_MAC_ENV_FILE: envFile, LANGFUSE_CONTENT_MODE: "content", LANGFUSE_MEDIA_ENABLED: "false",
  LANGFUSE_SAMPLE_RATE: "1", LANGFUSE_TRACING_ENVIRONMENT: "tracing-acceptance",
  npm_config_cache: "/private/tmp/terminal-mac-npm" };
environment.LANGFUSE_BASE_URL ??= environment.LANGFUSE_HOST;
const secrets = [environment.LANGFUSE_PUBLIC_KEY, environment.LANGFUSE_SECRET_KEY].filter(Boolean);
if (secrets.length !== 2 || !environment.LANGFUSE_BASE_URL) throw new Error("Locally configured project keys/base URL are required.");
const sanitize = (text) => secrets.reduce((result, key) => result.replaceAll(key, "[REDACTED]"), text);
const machine = process.argv[4] ?? "default";
if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$/.test(machine)) throw new Error("Invalid VM name.");
const session = `guest-audit-${Date.now()}`;
let task;
let chain;
let finalized = false;
function run(args, input) {
  const result = spawnSync(executable, args, { env: environment, encoding: "utf8", input, timeout: 15000 });
  if (result.status !== 0 || result.signal || result.error) throw new Error(`Guest audit command failed: ${sanitize(result.stderr ?? "")}`);
  return JSON.parse(result.stdout);
}
try {
  task = run(["trace", "begin", "--goal", "Verify read-only guest status", "--session", session]);
  if (!task.context) throw new Error("Tracing is unavailable.");
  chain = run(["chain", "begin", "--context", task.context, "--goal", "Read guest permissions",
    "--reason", "Verify successful guest responses without modifying desktop state"]);
  const rpc = JSON.stringify({ jsonrpc: "2.0", id: "guest-audit-status", method: "tools/call",
    params: { name: "status", arguments: { context: chain.context, actor: "ai", reason: "Read guest permissions" } } });
  const mcp = run(["mcp", machine], rpc + "\n");
  if (mcp.result?.isError || !mcp.result?.content) throw new Error("Guest MCP status did not succeed.");
  const cli = run(["action", machine, "status", "--context", chain.context, "--actor", "ai", "--trace-envelope"]);
  if (cli.result.accessibility !== "true" || cli.result.screenRecording !== "true") throw new Error("Guest permissions are incomplete.");
  run(["chain", "end", "--context", chain.context, "--outcome", "success", "--summary", "MCP and CLI returned guest permissions"]);
  run(["trace", "end", "--context", task.context, "--outcome", "success", "--summary", "Read-only guest tracing verified"]);
  finalized = true;
  const contract = readContract("3.188.0");
  for (let attempt = 0; attempt < 13; attempt++) {
    const query = spawnSync("npx", ["--offline", "--yes", "@langfuse/cli", ...observationArgs(contract, task.trace_id)],
      { env: environment, encoding: "utf8", timeout: 15000 });
    if (query.status !== 0) throw new Error(`Read-back failed: ${sanitize(query.stderr || query.stdout).slice(0, 1000)}`);
    const envelope = JSON.parse(query.stdout);
    const observations = envelope.body?.data;
    if (!Array.isArray(observations)) throw new Error("Unexpected observations response.");
    if (observations.length >= 6) {
      const assert = (condition, message) => { if (!condition) throw new Error(message); };
      assert(observations.length === 6, "Expected six observations.");
      const root = observations.find((item) => item.id === task.observation_id);
      const step = observations.find((item) => item.id === chain.observation_id);
      const tools = observations.filter((item) => item.type === "TOOL");
      const guests = observations.filter((item) => item.name === "send-guest-status");
      assert(root && step?.parentObservationId === root.id && tools.length === 2 && guests.length === 2, "Incorrect guest hierarchy.");
      assert(tools.every((item) => item.parentObservationId === step.id), "Tool parent mismatch.");
      assert(guests.every((item) => tools.some((tool) => tool.id === item.parentObservationId)), "Guest parent mismatch.");
      assert(tools.some((item) => item.id === cli.tracing.observation_id) &&
        tools.some((item) => item.id === mcp.result._meta["terminal-mac/tracing"].observation_id), "Correlation mismatch.");
      for (const item of observations) {
        assert(item.traceId === task.trace_id && item.level === "DEFAULT", "Expected success in one trace.");
        assert(Date.parse(item.endTime) >= Date.parse(item.startTime), "Invalid timing.");
        assert(item.environment === "tracing-acceptance", "Environment mismatch.");
      }
      for (const item of guests) {
        const output = typeof item.output === "string" ? JSON.parse(item.output) : item.output;
        assert(output.ok && output.values.accessibility === "true" && output.values.screenRecording === "true", "Guest response content missing.");
      }
      const payload = JSON.stringify(observations);
      assert(secrets.every((key) => !payload.includes(key)), "Credentials present in observations.");
      const delivery = run(["trace", "status"]);
      const traceURL = new URL(`project/${root.projectId}/traces/${task.trace_id}`, environment.LANGFUSE_BASE_URL.replace(/\/?$/, "/")).href;
      console.log(sanitize(JSON.stringify({ status: "passed", trace_id: task.trace_id, trace_url: traceURL,
        observation_count: 6, media_uploaded: false, desktop_input_sent: false, delivery,
        observations: observations.map(({ id, name, type, parentObservationId, output }) => ({ id, name, type, parentObservationId, output })) }, null, 2)));
      process.exit(0);
    }
    if (attempt < 12) await new Promise((resolve) => setTimeout(resolve, 10000));
  }
  throw new Error("Guest audit observations did not appear within the bounded window.");
} catch (error) {
  if (!finalized && chain?.context) {
    try { run(["chain", "end", "--context", chain.context, "--outcome", "failed", "--summary", "Guest status audit incomplete"]); } catch {}
  }
  if (!finalized && task?.context) {
    try { run(["trace", "end", "--context", task.context, "--outcome", "failed", "--summary", "Guest status audit incomplete"]); } catch {}
  }
  console.error(sanitize(JSON.stringify({ status: "unverified", message: error.message, trace_id: task?.trace_id })));
  process.exitCode = 1;
}
