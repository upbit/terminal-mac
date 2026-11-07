#!/bin/bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo 'Usage: bash scripts/test-package.sh /absolute/path/to/release.zip' >&2; exit 1; }
archive="$1"
work="$(mktemp -d "${TMPDIR:-/tmp}/terminal-mac-package-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$archive" "$work/unpacked"
installer="$(find "$work/unpacked" -name install.sh -type f | head -1)"
[[ -n "$installer" ]] || { echo 'Release installer is missing.' >&2; exit 1; }
prefix="$work/prefix with spaces"
bash "$installer" --prefix "$prefix"
bash "$installer" --prefix "$prefix"
launcher="$prefix/bin/terminal-mac"
# The version must come from the installed bundle, not a fallback.
expected="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(dirname "$installer")/TerminalMac.app/Contents/Info.plist")"
[[ "$("$launcher" --version)" == "terminal-mac $expected" ]] || { echo "Version mismatch: $("$launcher" --version), expected $expected" >&2; exit 1; }
TERMINAL_MAC_HOME="$work/unused-data" "$launcher" up test --plan > "$work/plan.json"
[[ ! -e "$work/unused-data" ]] || { echo 'Plan unexpectedly created VM data.' >&2; exit 1; }
python3 - "$work/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
assert plan['name'] == 'test'
assert plan['steps'][0] == 'download-or-reuse-apple-restore-image'
PY
# The guard refuses physical Macs. CI runners are themselves virtual Macs, where it must allow.
if [[ "$(sysctl -n hw.model)" == VirtualMac* ]]; then
  "$launcher" guest --check | grep -q '^virtual-mac$' || { echo 'Guest guard rejected a virtual Mac.' >&2; exit 1; }
else
  if "$launcher" guest --check > "$work/guard.log" 2>&1; then echo 'Guest guard unexpectedly allowed the physical host.' >&2; exit 1; fi
  grep -q 'only runs inside a virtual Mac' "$work/guard.log"
fi
TERMINAL_MAC_HOME="$work/unused-data" "$launcher" skills get | grep -q '^name: terminal-mac$'
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | TERMINAL_MAC_HOME="$work/unused-data" "$launcher" mcp | grep -q '"screenshot"'
python3 - "$launcher" "$work/unused-data" <<'PYTEST'
import json, os, subprocess, sys

launcher, data_root = sys.argv[1:]
coordinates = (1e30, -1e30, 0.5, True, "12", 12, 12.0)
requests = [
    {"jsonrpc": "2.0", "id": index, "method": "tools/call",
     "params": {"name": "click", "arguments": {"x": x, "y": 0}}}
    for index, x in enumerate(coordinates)
]
requests.append({"jsonrpc": "2.0", "id": len(coordinates), "method": "ping"})
result = subprocess.run(
    [launcher, "mcp"], input="".join(json.dumps(request) + "\n" for request in requests),
    env={**os.environ, "TERMINAL_MAC_HOME": data_root}, capture_output=True,
    text=True, check=True, timeout=10,
)
responses = {reply["id"]: reply["result"] for reply in map(json.loads, result.stdout.splitlines())}
for index, x in enumerate(coordinates):
    response = responses[index]
    assert response["isError"], response
    message = response["content"][0]["text"]
    expected = "No virtual Mac named" if index >= 5 else "Expected an integer in range for 'x'"
    assert expected in message, (x, message)
assert responses[len(coordinates)] == {}, responses
PYTEST
if "$launcher" up ../escape --plan > "$work/name.log" 2>&1; then echo 'Invalid machine name was accepted.' >&2; exit 1; fi
conflict="$work/conflict"
mkdir -p "$conflict/bin"
echo 'preserve me' > "$conflict/bin/terminal-mac"
if bash "$installer" --prefix "$conflict" > "$work/conflict.log" 2>&1; then echo 'Unrelated executable was overwritten.' >&2; exit 1; fi
[[ "$(cat "$conflict/bin/terminal-mac")" = 'preserve me' ]]
codesign --verify --deep --strict "$(dirname "$installer")/TerminalMac.app"
echo 'Package checks passed: clean extraction, repeated installation, paths with spaces, plan without writes, host guard, invalid names, unrelated executable preservation, signatures, bundled skill, MCP tool list.'
