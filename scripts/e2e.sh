#!/bin/sh
# End-to-end tests against throwaway servers on this Mac: OpenSSH (accepts only the RSA test fixture),
# etserver, mosh-server, and an isolated tmux (your own tmux and Herdr sessions are not visible to the tests). Runs LiveServerTests and the SteerUITests that drive the real app.
#   scripts/e2e.sh             a dedicated "Steer E2E" iOS 18.5 Simulator (created on first run)
#   scripts/e2e.sh --device    the connected iPhone: unlocked, Auto-Lock off, Settings → Developer → Enable UI Automation,
#                              same Wi-Fi as this Mac, iPhone Mirroring closed (servers listen on the LAN address)
# STEER_E2E_ONLY narrows the run, e.g. STEER_E2E_ONLY=-only-testing:SteerUITests/E2ETests/testETSessionLeavesNothingBehind.
# Needs mosh and et (brew install mosh et); etserver takes port 2022. Nothing touches ~/.ssh or your own tmux.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
port=${STEER_LIVE_SSH_PORT:-2299}
control_port=2297
if [ "${1:-}" = "--device" ]; then
    shift
    device_id=${STEER_DEVICE_ID:-$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && !/simulated/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F-]+$/) { print $i; exit } }')}
    [ -n "$device_id" ] || { echo "No paired iPhone found." >&2; exit 1; }
    address=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
    destination="platform=iOS,id=$device_id"
    signing=""
    # iOS blocks the test runner (unlike Steer) from the local network, so on a phone the host is checked here instead.
    on_device=1
else
    # A Simulator of its own, so hosts saved for manual testing (whose live previews keep the app busy) stay out.
    simulator_id=${STEER_SIMULATOR_ID:-$(xcrun simctl list devices available | sed -nE 's/^ *Steer E2E \(([0-9A-F-]{36})\).*/\1/p' | head -n 1)}
    if [ -z "$simulator_id" ]; then
        device_type=$(xcrun simctl list devicetypes | sed -nE 's/^iPhone 16 Pro \((com[^)]+)\)$/\1/p' | head -n 1)
        # Pinned to the iOS the UI tests are written against (iOS 26 sheets expose the host form differently).
        runtime=${STEER_E2E_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-18-5}
        simulator_id=$(xcrun simctl create "Steer E2E" "$device_type" "$runtime")
    fi
    address=127.0.0.1
    destination="platform=iOS Simulator,id=$simulator_id"
    signing="CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-"
    on_device=0
fi
dir=$(mktemp -d)
token=$(openssl rand -hex 16)

# Every process started through the test sshd carries $dir in its environment, which is how they are found and cleaned up.
spawned() { ps -E -o pid=,command= -U "$(id -u)" | grep -F "$dir" | grep -v grep | grep -E "$1" | awk '{ print $1 }'; }
cleanup() {
    kill "$(cat "$dir/sshd.pid" 2>/dev/null)" "$(cat "$dir/etserver.pid" 2>/dev/null)" "$(cat "$dir/control.pid" 2>/dev/null)" 2>/dev/null || true
    TMUX_TMPDIR="$dir/tmux" tmux kill-server 2>/dev/null || true
    for pid in $(spawned .); do kill "$pid" 2>/dev/null || true; done
    rm -rf "$dir"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N "" -f "$dir/host_key"
sed -n 's/^    static let publicKey = "\(.*\)"$/\1/p' "$root/ios/SteerTests/RSAFixture.swift" > "$dir/authorized_keys"
mkdir -m 700 "$dir/xdg" "$dir/config" "$dir/tmux"
cat > "$dir/sshd_config" <<CONFIG
Port $port
ListenAddress $address
HostKey $dir/host_key
AuthorizedKeysFile $dir/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile $dir/sshd.pid
SetEnv XDG_RUNTIME_DIR=$dir/xdg XDG_CONFIG_HOME=$dir/config TMUX_TMPDIR=$dir/tmux STEER_E2E=$dir
CONFIG
/usr/sbin/sshd -f "$dir/sshd_config" -E "$dir/sshd.log"

# etserver and etterminal meet through a fifo under XDG_RUNTIME_DIR, kept inside the temp directory.
printf '[Networking]\nport = 2022\nbind_ip = %s\n[Debug]\ntelemetry = false\n' "$address" > "$dir/et.cfg"
XDG_RUNTIME_DIR="$dir/xdg" etserver --cfgfile "$dir/et.cfg" --logdir "$dir" > "$dir/etserver.out" 2>&1 &
echo $! > "$dir/etserver.pid"

# Tests set this as a host's mosh-server path. Once blocked, it hands out a port nothing listens on.
mkdir "$dir/bin"
cat > "$dir/bin/mosh-server" <<WRAPPER
#!/bin/sh
if [ -e "$dir/block-mosh" ]; then echo "MOSH CONNECT 9 AAAAAAAAAAAAAAAAAAAAAA"; exit 0; fi
exec "$(command -v mosh-server)" "\$@"
WRAPPER
chmod +x "$dir/bin/mosh-server"

TMUX_TMPDIR="$dir/tmux" tmux new-session -d -s e2e-a
TMUX_TMPDIR="$dir/tmux" tmux new-session -d -s e2e-b

# Lets the tests observe the host: GET /<token>/state reports what Steer left running;
# GET /<token>/kill-mosh ends the mosh-servers Steer started, as a host reboot would;
# GET /<token>/block-new-mosh makes the next Mosh sessions unreachable, as a network blocking UDP would.
cat > "$dir/control.py" <<'PY'
import json, os, subprocess, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
directory, token, address, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

def spawned(name):
    out = subprocess.run(["ps", "-E", "-o", "pid=,command=", "-U", str(os.getuid())], capture_output=True, text=True).stdout
    return [line.split()[0] for line in out.splitlines() if directory in line and name in line.split(None, 2)[1]]

def tmux_clients():
    out = subprocess.run(["tmux", "list-clients", "-F", "#{session_name}"], capture_output=True, text=True,
                         env={**os.environ, "TMUX_TMPDIR": directory + "/tmux"}).stdout.split()
    return {name: out.count(name) for name in set(out)}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/" + token + "/kill-mosh":
            for pid in spawned("mosh-server"): os.kill(int(pid), 9)
        elif self.path == "/" + token + "/block-new-mosh":
            open(directory + "/block-mosh", "w").close()
        elif self.path != "/" + token + "/state":
            self.send_error(404)
            return
        body = json.dumps({"moshServers": len(spawned("mosh-server")), "etterminals": len(spawned("etterminal")),
                           "tmuxClients": tmux_clients()}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass

HTTPServer((address, port), Handler).serve_forever()
PY
/usr/bin/python3 "$dir/control.py" "$dir" "$token" "$address" "$control_port" &
echo $! > "$dir/control.pid"

cd "$root/ios"
xcodegen generate >/dev/null
# The app is not reset: tests add and remove their own uniquely named host, so saved hosts stay.
status=0
# shellcheck disable=SC2086
TEST_RUNNER_STEER_LIVE_SSH_PORT=$port \
TEST_RUNNER_STEER_LIVE_SSH_USER=$(whoami) \
TEST_RUNNER_STEER_LIVE_SSH_HOSTKEY="$(cut -d' ' -f1,2 "$dir/host_key.pub")" \
TEST_RUNNER_STEER_E2E_ADDRESS=$address \
TEST_RUNNER_STEER_E2E_CONTROL="http://$address:$control_port/$token" \
TEST_RUNNER_STEER_E2E_ON_DEVICE=$on_device \
TEST_RUNNER_STEER_E2E_MOSH_WRAPPER="$dir/bin/mosh-server" \
xcodebuild -project Steer.xcodeproj -scheme Steer -destination "$destination" \
    ${STEER_E2E_ONLY:--only-testing:SteerTests/LiveServerTests -only-testing:SteerUITests} \
    -skipPackageUpdates $signing test || status=$?
# Every test closes what it opens, so nothing may be left on the host.
sleep 3
leftovers=$(spawned 'mosh-server|etterminal' | wc -l | tr -d ' ')
clients=$(TMUX_TMPDIR="$dir/tmux" tmux list-clients 2>/dev/null | wc -l | tr -d ' ')
if [ "$leftovers" != 0 ] || [ "$clients" != 0 ]; then
    echo "error: after the tests, $leftovers mosh-server/etterminal processes and $clients tmux clients were still on the host" >&2
    status=1
fi
exit $status
