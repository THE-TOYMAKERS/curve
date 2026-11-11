#!/bin/sh
# Actual execution checks for a fresh ad hoc, Hardened Runtime, sandboxed app.
# Run outside a restricted command sandbox so macOS can establish the container.
# Only synthetic data and a unique QA bundle/container are created.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
curve_probe_scratch=$(mktemp -d "$PWD/.build/sandbox-checks.XXXXXX")
trap 'rm -rf "$curve_probe_scratch"' EXIT HUP INT TERM
swiftc -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$curve_probe_scratch/module-cache" \
  Sources/BrowserCore/*.swift Checks/SandboxProbe.swift -o "$curve_probe_scratch/SandboxProbe"
python3 - "$curve_probe_scratch" "$PWD/Curve.entitlements" <<'PY'
import hashlib, http.server, json, os, pathlib, plistlib, re, shutil, signal, subprocess, sys, threading, uuid

scratch = pathlib.Path(sys.argv[1]).resolve()
entitlements_path = pathlib.Path(sys.argv[2]).resolve()
identity = 'com.toymakers.curve.qa.sandbox.' + uuid.uuid4().hex
assert re.fullmatch(r'com\.toymakers\.curve\.qa\.sandbox\.[a-f0-9]{32}', identity)
app = scratch / 'SandboxProbe.app'
macos = app / 'Contents/MacOS'
macos.mkdir(parents=True)
executable = macos / 'SandboxProbe'
shutil.copy2(scratch / 'SandboxProbe', executable)
info = {
    'CFBundleIdentifier': identity, 'CFBundleName': 'Curve Sandbox Probe',
    'CFBundleExecutable': 'SandboxProbe', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
    'LSMinimumSystemVersion': '14.0', 'LSBackgroundOnly': True,
    'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
}
with (app / 'Contents/Info.plist').open('wb') as handle:
    plistlib.dump(info, handle)
required = {
    'com.apple.security.app-sandbox', 'com.apple.security.network.client',
    'com.apple.security.files.user-selected.read-write',
    'com.apple.security.device.camera', 'com.apple.security.device.microphone',
    'com.apple.security.device.audio-input',
}
entitlements = plistlib.loads(entitlements_path.read_bytes())
if set(entitlements) != required or not all(entitlements[k] is True for k in required):
    sys.exit('FAIL: sandbox probe expects exactly Curve\'s reviewed resource entitlements; inspect any policy change.')
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--options', 'runtime', '--entitlements', str(entitlements_path), '--timestamp=none', str(app)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
details = subprocess.run(['/usr/bin/codesign', '-dvvv', str(app)], capture_output=True, text=True, check=True).stderr
if not re.search(r'flags=0x[0-9a-fA-F]+\([^\n)]*\bruntime\b', details):
    sys.exit('FAIL: probe signature lacks Hardened Runtime.')
signed = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)], capture_output=True, check=True).stdout
if plistlib.loads(signed) != entitlements:
    sys.exit('FAIL: probe signature entitlements differ from Curve.entitlements.')

outside = scratch / 'host-only'
outside.mkdir(mode=0o700)
secret = outside / 'synthetic-private-fixture.txt'
write_target = outside / 'must-not-exist.txt'
nonce = uuid.uuid4().hex
secret.write_text(nonce, encoding='utf-8')
secret.chmod(0o600)
# Host controls establish that the fixture is readable/writable for this user;
# only the probe's sandbox should deny it, rather than a missing file or mode.
assert secret.read_text(encoding='utf-8') == nonce
write_target.write_text('host control', encoding='utf-8')
write_target.unlink()

hits = []
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/' + nonce:
            self.send_error(404); return
        hits.append(self.path)
        body = nonce.encode('ascii')
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
container = pathlib.Path.home() / 'Library/Containers' / identity
assert container.name == identity and container.parent == pathlib.Path.home() / 'Library/Containers'
if container.exists():
    server.shutdown(); server.server_close()
    sys.exit('FAIL: refusing to reuse a preexisting sandbox probe container.')
try:
    endpoint = f'http://127.0.0.1:{server.server_port}/{nonce}'
    try:
        result = subprocess.run([str(executable), identity, str(secret), str(write_target), endpoint, nonce], capture_output=True, text=True, timeout=25)
    except subprocess.TimeoutExpired:
        sys.exit('FAIL: sandbox probe did not finish within 25 seconds; actual launch/network execution is unverified. No security policy was relaxed.')
    if result.returncode < 0:
        number = -result.returncode
        name = signal.Signals(number).name
        sys.exit(f'FAIL: sandbox probe was killed by {name} during actual execution. No security policy was relaxed.')
    try:
        report = json.loads(result.stdout.strip())
    except (ValueError, TypeError):
        sys.exit(f'FAIL: sandbox probe exited {result.returncode} without a valid report. No security policy was relaxed.')
    if report.get('identity') != identity or not report.get('passed') or result.returncode != 0:
        print(json.dumps(report, sort_keys=True))
        sys.exit('FAIL: actual sandbox probe checks did not all pass.')
    if secret.read_text(encoding='utf-8') != nonce or write_target.exists() or hits != ['/' + nonce]:
        sys.exit('FAIL: host fixture integrity, outside-write denial, or localhost request count differs from expectation.')
    print('PASS: actual ad hoc Hardened Runtime + App Sandbox execution, real secure-profile state/history/backup/permissions/erasure operations, outside synthetic-file read/write denial, and outbound localhost HTTP.')
    print('Passed ' + str(len(report['checks'])) + ' production-boundary checks in QA identity ' + identity + '.')
finally:
    server.shutdown(); server.server_close(); thread.join(timeout=2)
    # This identity was generated above, was absent before launch, and can never
    # name Curve's real profile/container or another application's data.
    if container.exists():
        try:
            if container.is_symlink():
                raise RuntimeError('unexpected container symlink')
            shutil.rmtree(container)
            print('Removed the exact synthetic sandbox-probe container.')
        except Exception as error:
            print(f'NOTE: macOS prevented removal of synthetic QA container {identity}: {type(error).__name__}. No production container was touched.', file=sys.stderr)
PY
