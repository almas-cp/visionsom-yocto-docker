#!/bin/sh
# eth_ap.sh
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
# Starts Ethernet configuration mode on end0.


# Dynamic interface detection — portable across eth0, end0, enp2s0, eno1, etc.
IFACE=$(ip -o link show | awk '{print $2}' | tr -d ':' | grep -E '^(eth|end|enp|eno)[0-9]' | head -1)
IFACE="${IFACE:-end0}"
echo "Ethernet AP: using interface ${IFACE}"
AP_IP="192.168.100.1"
DHCP_RANGE_START="192.168.100.10"
DHCP_RANGE_END="192.168.100.50"
DHCP_LEASE_TIME="12h"
PORTAL_HOST="gateway.local"

LOG_TAG="eth-ap"
LOG_DIR="/tmp/logs"
LOG_FILE="$LOG_DIR/debug.log"
PORTAL_DIR="/usr/share/gateway_conf/portal"
PORTAL_PORT="80"

DNSMASQ_CONF="/tmp/dnsmasq_eth.conf"
DNSMASQ_PID="/tmp/dnsmasq_eth.pid"
PYTHON_PID="/tmp/portal_eth.pid"

CONFIG_DIR="/etc/gateway"
APPLY_SCRIPT="/usr/bin/apply_gateway_config.sh"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 664 "$LOG_FILE" 2>/dev/null || true
exec >> "$LOG_FILE" 2>&1

echo ""
echo "=================================================="
echo "$(date '+%Y-%m-%d %H:%M:%S') eth_ap.sh starting"
echo "=================================================="

log_info() { logger -t "$LOG_TAG" -p user.info "$1"; echo "[INFO]  $1"; }
log_warn() { logger -t "$LOG_TAG" -p user.warning "$1"; echo "[WARN]  $1"; }
log_err()  { logger -t "$LOG_TAG" -p user.err "$1"; echo "[ERROR] $1"; }

run_cmd() {
    log_info "CMD: $*"
    "$@"
    rc=$?
    [ $rc -ne 0 ] && log_err "Command failed ($rc): $*"
    return $rc
}

CLEANED=0

cleanup() {
    [ "$CLEANED" -eq 1 ] && return
    CLEANED=1
    trap '' EXIT INT TERM

    log_info "Shutting down Ethernet config mode..."

    [ -f "$PYTHON_PID" ] && kill "$(cat "$PYTHON_PID")" 2>/dev/null && rm -f "$PYTHON_PID" && log_info "Stopped portal process"
    [ -f "$DNSMASQ_PID" ] && kill "$(cat "$DNSMASQ_PID")" 2>/dev/null && rm -f "$DNSMASQ_PID" && log_info "Stopped dnsmasq process"

    sleep 1

    # Remove only the AP secondary alias — do NOT flush the main DHCP IP
    ip addr del 192.168.100.1/24 dev "$IFACE" 2>/dev/null || true

    # Restart both socket and service so DHCP re-acquires if needed
    systemctl restart systemd-networkd.socket 2>/dev/null || true
    systemctl restart systemd-networkd.service 2>/dev/null || true

    log_info "Restarting system dnsmasq"
    systemctl start dnsmasq 2>/dev/null || true

    # --- BUG FIX (Patch 4): Remove zombie AP network configs so interfaces act as DHCP clients after reboot ---
    rm -f /etc/systemd/network/10-wlan0.network
    rm -f /etc/systemd/network/10-eth0.network
    rm -f /run/systemd/network/10-wlan0.network 2>/dev/null || true
    rm -f /run/systemd/network/10-eth0.network 2>/dev/null || true
    log_info "Removed stale AP network config files."

    # --- LED STATUS: Off = AP torn down ---
    rm -f /tmp/ap_starting 2>/dev/null
    rm -f /tmp/ap_mode_active 2>/dev/null
    echo 0 > /sys/class/leds/ble-led/brightness 2>/dev/null
    echo 0 > /sys/class/leds/wifi-led/brightness 2>/dev/null

    rm -f "$DNSMASQ_CONF"
    log_info "Ethernet config mode stopped"
}

trap cleanup EXIT

write_dnsmasq_conf() {
    cat > "$DNSMASQ_CONF" << CONF
# NEW — DHCP only, DNS disabled (port=0), gateway DNS/OpenVPN unaffected:
port=0
interface=${IFACE}
listen-address=${AP_IP}
bind-interfaces
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE_TIME}
dhcp-option=option:router,${AP_IP}
log-dhcp
CONF
    log_info "Wrote dnsmasq config to $DNSMASQ_CONF"
}

ensure_portal() {
    mkdir -p "$PORTAL_DIR"
    [ -f "$PORTAL_DIR/index.html" ] || log_warn "Portal index.html not found at $PORTAL_DIR/index.html"
    [ -f "$PORTAL_DIR/login.html" ] || log_warn "Portal login.html not found at $PORTAL_DIR/login.html"
    [ -f "$PORTAL_DIR/change_password.html" ] || log_warn "Portal change_password.html not found at $PORTAL_DIR/change_password.html"
}

start_portal() {
    mkdir -p "$CONFIG_DIR"

    python3 - "$PORTAL_DIR" "$PORTAL_PORT" "$CONFIG_DIR" "$APPLY_SCRIPT" << 'PYEOF' &
import sys, os, json, subprocess, secrets, hashlib, base64, hmac, time
from http.server import HTTPServer, BaseHTTPRequestHandler
from http.cookies import SimpleCookie

portal_dir = sys.argv[1]
port = int(sys.argv[2])
config_dir = sys.argv[3]
apply_script = sys.argv[4]

AUTH_FILE = os.path.join(config_dir, "portal_auth.json")
SESSION_FILE = os.path.join(config_dir, "portal_sessions.json")

FIELDS = [
    "wifi_ssid",
    "wifi_password",
    "network_server",
    "network_priority",
    "zip_password",
    "log_level",
    "azure_connection_string",
    "ttn_api_key",
    "region_profile",
]

FILE_MAP = {
    "wifi_ssid": "wifi_ssid",
    "wifi_password": "wifi_password",
    "network_server": "network_server",
    "network_priority": "network_priority",
    "zip_password": "zip_password",
    "log_level": "log_level",
    "azure_connection_string": "azure_connection_string",
    "ttn_api_key": "ttn_api_key",
    "region_profile": "region_profile",
}

SESSION_COOKIE = "gateway_session"
SESSION_TTL = 8 * 60 * 60

def load_json(path, default):
    try:
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
    except Exception:
        pass
    return default

def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, path)

def hash_password(password, salt=None, iterations=260000):
    if salt is None:
        salt = secrets.token_hex(16)
    pw_hash = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        salt.encode("utf-8"),
        iterations
    )
    b64_hash = base64.b64encode(pw_hash).decode("ascii").strip()
    return f"pbkdf2_sha256${iterations}${salt}${b64_hash}"

def verify_password(password, password_hash):
    try:
        algorithm, iterations, salt, expected = password_hash.split("$", 3)
        if algorithm != "pbkdf2_sha256":
            return False
        actual = hash_password(password, salt=salt, iterations=int(iterations))
        return hmac.compare_digest(actual, password_hash)
    except Exception:
        return False

def auth_state():
    data = load_json(AUTH_FILE, {})
    if not data:
        return {
            "initialized": False,
            "must_change_password": True,
            "username": "admin",
            "password_hash": None,
        }
    return {
        "initialized": True,
        "must_change_password": bool(data.get("must_change_password", False)),
        "username": data.get("username", "admin"),
        "password_hash": data.get("password_hash"),
    }

def save_auth(username, password_hash, must_change_password):
    save_json(AUTH_FILE, {
        "username": username,
        "password_hash": password_hash,
        "must_change_password": must_change_password,
    })

def load_sessions():
    data = load_json(SESSION_FILE, {})
    now = int(time.time())
    clean = {}
    for sid, info in data.items():
        if int(info.get("expires_at", 0)) > now:
            clean[sid] = info
    if clean != data:
        save_json(SESSION_FILE, clean)
    return clean

def save_sessions(data):
    save_json(SESSION_FILE, data)

def create_session(username):
    sessions = load_sessions()
    sid = secrets.token_urlsafe(32)
    sessions[sid] = {
        "username": username,
        "expires_at": int(time.time()) + SESSION_TTL
    }
    save_sessions(sessions)
    return sid

def delete_session(sid):
    sessions = load_sessions()
    if sid in sessions:
        del sessions[sid]
        save_sessions(sessions)

def get_cookie_value(handler, name):
    raw = handler.headers.get("Cookie", "")
    if not raw:
        return None
    c = SimpleCookie()
    try:
        c.load(raw)
        if name in c:
            return c[name].value
    except Exception:
        return None
    return None

def get_session_user(handler):
    sid = get_cookie_value(handler, SESSION_COOKIE)
    if not sid:
        return None
    sessions = load_sessions()
    info = sessions.get(sid)
    if not info:
        return None
    return info.get("username")

def write_value(name, value):
    os.makedirs(config_dir, exist_ok=True)
    path = os.path.join(config_dir, FILE_MAP[name])
    with open(path, "w", encoding="utf-8") as f:
        f.write((value or "").strip() if isinstance(value, str) else str(value))

def read_value(name):
    path = os.path.join(config_dir, FILE_MAP[name])
    if not os.path.exists(path):
        return ""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return ""

def load_dropdown_options():
    def lines(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return [line.strip() for line in f if line.strip()]
        except Exception:
            return []

    return {
        "wifi_ssid": lines(os.path.join(config_dir, "wifi_ssid_options")),
        "wifi_password": lines(os.path.join(config_dir, "wifi_password_options")),
        "network_server": lines(os.path.join(config_dir, "network_server_options")),
        "azure_connection_string": lines(os.path.join(config_dir, "azure_connection_string_options")),
        "ttn_api_key": lines(os.path.join(config_dir, "ttn_api_key_options")),
    }

def validate(data):
    if not data.get("network_server", "").strip():
        return "Network server is required"
    if not data.get("network_priority", "").strip():
        return "Network priority is required"
    if not data.get("zip_password", "").strip():
        return "ZIP password is required"
    if not data.get("log_level", "").strip():
        return "Log level is required"
    if not data.get("azure_connection_string", "").strip():
        return "Azure connection string is required"
    if not data.get("ttn_api_key", "").strip():
        return "TTN API key is required"
    if not data.get("region_profile", "").strip():
        return "Region profile is required"
    return ""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send_json(self, code, payload, cookies=None):
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if cookies:
            for k, v in cookies:
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, location, cookies=None):
        self.send_response(302)
        self.send_header("Location", location)
        if cookies:
            for k, v in cookies:
                self.send_header(k, v)
        self.end_headers()

    def session_cookie_header(self, sid):
        c = SimpleCookie()
        c[SESSION_COOKIE] = sid
        c[SESSION_COOKIE]["path"] = "/"
        c[SESSION_COOKIE]["httponly"] = True
        c[SESSION_COOKIE]["samesite"] = "Strict"
        return ("Set-Cookie", c.output(header="").strip())

    def clear_session_cookie_header(self):
        c = SimpleCookie()
        c[SESSION_COOKIE] = ""
        c[SESSION_COOKIE]["path"] = "/"
        c[SESSION_COOKIE]["httponly"] = True
        c[SESSION_COOKIE]["samesite"] = "Strict"
        c[SESSION_COOKIE]["max-age"] = 0
        return ("Set-Cookie", c.output(header="").strip())

    def require_auth_page(self):
        state = auth_state()
        user = get_session_user(self)
        if not user:
            self.redirect("/login.html")
            return False
        if state.get("must_change_password") and self.path not in ("/change_password.html", "/change_password"):
            self.redirect("/change_password.html")
            return False
        return True

    def require_auth_api(self):
        state = auth_state()
        user = get_session_user(self)
        if not user:
            self.send_json(401, {"ok": False, "message": "Authentication required"})
            return False
        if state.get("must_change_password") and self.path != "/change_password":
            self.send_json(403, {"ok": False, "message": "Password change required"})
            return False
        return True

    def serve_file(self, filename, ctype):
        path = os.path.join(portal_dir, filename)
        try:
            with open(path, "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_error(500, str(e))

    def do_GET(self):
        req = self.path.split("?", 1)[0]

        if req == "/":
            if not self.require_auth_page():
                return
            self.serve_file("index.html", "text/html; charset=utf-8")
            return

        if req == "/index.html":
            if not self.require_auth_page():
                return
            self.serve_file("index.html", "text/html; charset=utf-8")
            return

        if req == "/login.html":
            state = auth_state()
            user = get_session_user(self)
            if user and not state.get("must_change_password"):
                self.redirect("/")
                return
            if user and state.get("must_change_password"):
                self.redirect("/change_password.html")
                return
            self.serve_file("login.html", "text/html; charset=utf-8")
            return

        if req == "/change_password.html":
            user = get_session_user(self)
            if not user:
                self.redirect("/login.html")
                return
            self.serve_file("change_password.html", "text/html; charset=utf-8")
            return

        if req == "/sidebarLogo.png":
            self.serve_file("sidebarLogo.png", "image/png")
            return

        if req == "/config":
            if not self.require_auth_api():
                return
            cfg = {k: read_value(k) for k in FIELDS}
            self.send_json(200, {"ok": True, "config": cfg})
            return

        if req == "/options":
            if not self.require_auth_api():
                return
            self.send_json(200, {"ok": True, "options": load_dropdown_options()})
            return

        self.send_error(404)

    def do_POST(self):
        req = self.path.split("?", 1)[0]

        if req == "/login":
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length)
                data = json.loads(body.decode("utf-8"))
                username = data.get("username", "").strip()
                password = data.get("password", "")

                if not username or not password:
                    raise ValueError("Username and password are required")

                state = auth_state()

                ok = False
                if not state["initialized"]:
                    ok = (username == "admin" and password == "admin")
                else:
                    ok = (
                        username == state["username"] and
                        state["password_hash"] and
                        verify_password(password, state["password_hash"])
                    )

                if not ok:
                    raise ValueError("Invalid username or password")

                sid = create_session(state["username"] if state["initialized"] else "admin")
                self.send_json(200, {
                    "ok": True,
                    "must_change_password": bool(state.get("must_change_password", True))
                }, cookies=[self.session_cookie_header(sid)])
                return
            except Exception as e:
                self.send_json(401, {"ok": False, "message": str(e)})
                return

        if req == "/logout":
            sid = get_cookie_value(self, SESSION_COOKIE)
            if sid:
                delete_session(sid)
            self.send_json(200, {"ok": True}, cookies=[self.clear_session_cookie_header()])
            return

        if req == "/change_password":
            try:
                user = get_session_user(self)
                if not user:
                    self.send_json(401, {"ok": False, "message": "Authentication required"})
                    return

                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length)
                data = json.loads(body.decode("utf-8"))

                username = data.get("username", "").strip()
                password = data.get("password", "")

                if len(username) < 4:
                    raise ValueError("Username must be at least 4 characters")
                if len(password) < 8:
                    raise ValueError("Password must be at least 8 characters")

                save_auth(username, hash_password(password), False)
                sid = create_session(username)
                self.send_json(200, {
                    "ok": True,
                    "message": "Credentials updated",
                    "redirect": "/"
                }, cookies=[self.session_cookie_header(sid)])
                return
            except Exception as e:
                self.send_json(400, {"ok": False, "message": str(e)})
                return

        if req == "/save":
            try:
                if not self.require_auth_api():
                    return

                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length)
                data = json.loads(body.decode("utf-8"))

                err = validate(data)
                if err:
                    raise ValueError(err)

                if data.get("log_level", "").upper() == "ERR":
                    data["log_level"] = "ERROR"

                # ✅ WRITE FILES
                for field in FIELDS:
                    write_value(field, data.get(field, ""))

                # ✅ STORE IN HSM (SAFE VERSION)
                try:
                    result = subprocess.run(
                        [
                            "/usr/bin/store_to_hsm",
                            "i2c-0",
                            data.get("wifi_password", ""),
                            data.get("azure_connection_string", ""),
                            data.get("ttn_api_key", ""),
                            data.get("halow_password", "")
                        ],
                        capture_output=True,
                        text=True,
                        timeout=15
                    )

                    if result.returncode != 0:
                        print("HSM WARNING:", result.stderr or result.stdout)

                except Exception as e:
                    print("HSM EXCEPTION:", str(e))

                # ✅ APPLY CONFIG
                result = subprocess.run(
                    [apply_script],
                    capture_output=True,
                    text=True,
                    timeout=120
                )

                if result.returncode != 0:
                    msg = (result.stderr or result.stdout or "apply_gateway_config failed").strip()
                    raise RuntimeError(msg)

                self.send_json(200, {
                    "ok": True,
                    "message": "Saved! Gateway is rebooting. This page may stop responding — that is normal."
                })

                os.system("(sleep 3; reboot) >/dev/null 2>&1 &")

                return

            except Exception as e:
                self.send_json(200, {"ok": False, "message": str(e)})
                return
     

        self.send_error(404)

HTTPServer(("0.0.0.0", port), Handler).serve_forever()
PYEOF

    echo $! > "$PYTHON_PID"
    log_info "Portal running at http://${PORTAL_HOST} or http://${AP_IP}"
}

main() {
    # --- LED STATUS (Patch 8): Blinking = AP starting ---
    LED1="ble-led"
    LED2="wifi-led"

    touch /tmp/ap_starting
    (
      while [ -f /tmp/ap_starting ]; do
        echo 1 > /sys/class/leds/${LED1}/brightness 2>/dev/null
        echo 1 > /sys/class/leds/${LED2}/brightness 2>/dev/null
        sleep 0.5
        echo 0 > /sys/class/leds/${LED1}/brightness 2>/dev/null
        echo 0 > /sys/class/leds/${LED2}/brightness 2>/dev/null
        sleep 0.5
      done
    ) &
    BLINK_PID=$!

    log_info "Starting Ethernet AP configuration mode"
    touch /tmp/ap_mode_active
    log_info "IP: ${AP_IP} | Portal: http://${PORTAL_HOST} or http://${AP_IP}"

    log_info "Stopping system dnsmasq"
    systemctl stop dnsmasq 2>/dev/null || true
    killall dnsmasq 2>/dev/null || true
    pkill -x dnsmasq 2>/dev/null || true
    sleep 2

    # Add AP IP as secondary alias — preserves the original DHCP IP so SSH stays connected.
    # Remove any stale AP IP first (idempotent), then add fresh.
    ip addr del 192.168.100.1/24 dev ${IFACE} 2>/dev/null || true
    ip link set ${IFACE} up
    ip addr add 192.168.100.1/24 dev ${IFACE}
    log_info "Secondary config IP 192.168.100.1 added to ${IFACE}. Original DHCP IP preserved."

    log_info "Current interface state:"
    ip addr show dev "$IFACE"

    write_dnsmasq_conf
    log_info "Starting dnsmasq"
    dnsmasq --conf-file="$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID" --bind-interfaces >> "$LOG_FILE" 2>&1 || {
        log_err "dnsmasq failed to start"
        exit 1
    }

    sleep 2
    log_info "Checking dnsmasq process"
    ps | grep dnsmasq | grep -v grep || log_warn "dnsmasq process not found"

    ensure_portal
    start_portal

    # Poll for port 80 to confirm web server is ready (max 30 seconds)
    PORT80_READY=0
    for i in $(seq 1 30); do
        if grep -qE '00000000:0050' /proc/net/tcp 2>/dev/null; then
            PORT80_READY=1
            break
        fi
        sleep 1
    done

    # Stop initial startup blinking
    rm -f /tmp/ap_starting
    wait $BLINK_PID 2>/dev/null

    log_info "Ethernet config mode active"
    log_info "Connect a PC to $IFACE and open http://${PORTAL_HOST} or http://${AP_IP}"

    # Active link monitor loop: Both LEDs Solid ON when carrier=1 (cable plugged in), Both Blink when waiting
    while true; do
        CARRIER=$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null || echo "0")
        if [ "$CARRIER" = "1" ]; then
            # Ethernet cable connected & link UP: Both LEDs Solid ON
            echo 1 > /sys/class/leds/wifi-led/brightness 2>/dev/null
            echo 1 > /sys/class/leds/ble-led/brightness 2>/dev/null
            sleep 1
        else
            # Waiting for cable / link: Both Blink together (0.5s ON, 0.5s OFF)
            echo 1 > /sys/class/leds/wifi-led/brightness 2>/dev/null
            echo 1 > /sys/class/leds/ble-led/brightness 2>/dev/null
            sleep 0.5
            echo 0 > /sys/class/leds/wifi-led/brightness 2>/dev/null
            echo 0 > /sys/class/leds/ble-led/brightness 2>/dev/null
            sleep 0.5
        fi
    done
}

main "$@"
