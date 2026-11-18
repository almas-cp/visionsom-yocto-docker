import os
import hashlib
from flask import Flask, request, jsonify, redirect, url_for, session, send_from_directory, make_response
from main import update_wifi_config, configure_halow, set_network_priority, func_config_gatewayid, func_config_azure, start_gateway, teardown_access_point, set_log_password, store_secrets_to_hsm, NET_PRIO_FILE, LOG_CREDENTIAL, LOG_LEVEL, CONFIG_DIR, IN_CONTAINER, NSENTER
import threading
import time

app = Flask(__name__, static_folder='portal')
app.secret_key = os.urandom(32).hex()

last_activity_time = time.time()

@app.before_request
def record_activity():
    global last_activity_time
    last_activity_time = time.time()

def ap_inactivity_watchdog():
    TIMEOUT_SECONDS = 600  # 10 minutes timeout
    print(f"Ethernet AP Inactivity Watchdog started ({TIMEOUT_SECONDS}s / 10 minutes timeout).")
    while True:
        time.sleep(15)
        idle_time = time.time() - last_activity_time
        if idle_time >= TIMEOUT_SECONDS:
            print(f"Ethernet AP Inactivity Timeout ({idle_time:.0f}s / 10 minutes) reached with no user activity. Tearing down AP...")
            teardown_access_point()
            break

CREDENTIALS_FILE = "/etc/gateway/credentials"

def hash_password(password):
    return hashlib.sha256(password.encode()).hexdigest()

def load_credentials():
    if not os.path.exists(CREDENTIALS_FILE):
        return {"username": "admin", "password": hash_password("admin")}
    with open(CREDENTIALS_FILE, "r") as f:
        return dict(line.strip().split("=", 1) for line in f if "=" in line)

def save_credentials(username, password):
    os.makedirs(os.path.dirname(CREDENTIALS_FILE), exist_ok=True)
    with open(CREDENTIALS_FILE, "w") as f:
        f.write(f"username={username}\npassword={hash_password(password)}\n")

if not os.path.exists(CREDENTIALS_FILE):
    save_credentials("admin", "admin")

def is_default_password():
    creds = load_credentials()
    return creds.get("username") == "admin" and creds.get("password") == hash_password("admin")

@app.route("/")
def index():
    if not session.get("logged_in"):
        return redirect("/login.html")
    if is_default_password():
        return redirect("/change_password.html")
    return send_from_directory(app.static_folder, "index.html")

@app.route("/<path:path>")
def static_files(path):
    return send_from_directory(app.static_folder, path)

@app.route("/login", methods=["POST"])
def login():
    data = request.json or {}
    username = data.get("username", "")
    password = data.get("password", "")
    creds = load_credentials()
    
    if username == creds.get("username") and hash_password(password) == creds.get("password"):
        session["logged_in"] = True
        return jsonify({"ok": True, "must_change_password": is_default_password()})
    return jsonify({"ok": False, "message": "Invalid credentials"}), 401

@app.route("/logout", methods=["POST"])
def logout():
    session.pop("logged_in", None)
    return jsonify({"ok": True})

@app.route("/change_password", methods=["POST"])
def change_password():
    if not session.get("logged_in"):
        return jsonify({"ok": False, "message": "Not logged in"}), 401
    
    data = request.json or {}
    new_username = data.get("username")
    new_password = data.get("password")
    
    if not new_password or len(new_password) < 4:
        return jsonify({"ok": False, "message": "Password must be at least 4 characters."})
        
    creds = load_credentials()
    save_credentials(new_username or creds.get("username"), new_password)
    return jsonify({"ok": True})

@app.route("/config", methods=["GET"])
def get_config():
    if not session.get("logged_in"):
        return jsonify({"ok": False, "message": "Not logged in"}), 401
        
    config = {
        "wifi_ssid": "",
        "wifi_password": "",
        "halow_ssid": "",
        "halow_password": "",
        "halow_bandwidth": "4",
        "halow_security": "SAE",
        "network_server": "",
        "network_priority": "",
        "log_level": "",
        "zip_password": "",
        "azure_connection_string": "",
        "ttn_api_key": "",
        "region_profile": ""
    }
    
    # Read wifi SSID
    try:
        if os.path.exists("/etc/gateway/wifi_credentials"):
            with open("/etc/gateway/wifi_credentials") as f:
                content = f.read()
                if "WIFI_SSID=" in content:
                    config["wifi_ssid"] = content.split("WIFI_SSID='")[1].split("'")[0]
    except Exception:
        pass

    # Read HaLow settings
    try:
        if os.path.exists("/etc/gateway/halow_ssid"):
            with open("/etc/gateway/halow_ssid") as f:
                config["halow_ssid"] = f.read().strip()
        if os.path.exists("/etc/gateway/halow_security"):
            with open("/etc/gateway/halow_security") as f:
                config["halow_security"] = f.read().strip()
        if os.path.exists("/etc/gateway/halow_bandwidth"):
            with open("/etc/gateway/halow_bandwidth") as f:
                config["halow_bandwidth"] = f.read().strip()
    except Exception:
        pass

    # Read gateway.conf (network server, region, RF and interval parameters)
    try:
        gateway_conf = "/app/usr/local/TTN/gateway.conf" if os.path.exists("/app/usr/local/TTN/gateway.conf") else "/usr/local/TTN/gateway.conf"
        if os.path.exists(gateway_conf):
            with open(gateway_conf) as f:
                for line in f:
                    if "=" in line:
                        k, v = line.strip().split("=", 1)
                        if k in ["server_ip", "server_address"]:
                            config["network_server"] = v
                        elif k == "frequency":
                            config["region_profile"] = v
                        elif k in ["antenna_gain", "max_eirp", "keepalive_interval", "stat_interval", "push_timeout_ms", "autoquit_threshold"]:
                            config[k] = v
    except Exception:
        pass

    # Read network priority
    try:
        if os.path.exists(NET_PRIO_FILE):
            with open(NET_PRIO_FILE) as f:
                config["network_priority"] = f.read().strip()
    except Exception:
        pass

    # Read log levels
    try:
        if os.path.exists(LOG_LEVEL):
            with open(LOG_LEVEL) as f:
                config["log_level"] = f.read().strip()
        os_ver = os.path.join(CONFIG_DIR, "os_version")
        if os.path.exists(os_ver) or os.path.exists("/etc/gateway/os_version"):
            import subprocess
            import base64
            try:
                cmd = f"{NSENTER} /usr/bin/read-gateway-secrets /dev/i2c-0" if NSENTER else "/usr/bin/read-gateway-secrets /dev/i2c-0"
                res = subprocess.run(cmd, shell=True, capture_output=True, text=True)
                for line in res.stdout.split('\n'):
                    if line.startswith("zip_password:"):
                        config["zip_password"] = base64.b64decode(line.split(":")[1].strip()).decode('utf-8')
                        break
            except Exception:
                pass
        elif os.path.exists(LOG_CREDENTIAL):
            with open(LOG_CREDENTIAL) as f:
                config["zip_password"] = f.read().strip()
    except Exception:
        pass

    return jsonify({"ok": True, "config": config})

@app.route("/save", methods=["POST"])
def save_config():
    if not session.get("logged_in"):
        return jsonify({"ok": False, "message": "Not logged in"}), 401
        
    data = request.json or {}
    
    wifi_ssid = data.get("wifi_ssid")
    wifi_password = data.get("wifi_password")
    halow_enabled = data.get("halow_enabled", True)
    halow_ssid = data.get("halow_ssid") if halow_enabled else ""
    halow_password = data.get("halow_password") if halow_enabled else ""
    halow_bandwidth = data.get("halow_bandwidth", "4")
    halow_security = data.get("halow_security", "SAE")
    server = data.get("network_server")
    net_prio = data.get("network_priority")
    zip_pw = data.get("zip_password")
    log_level = data.get("log_level")
    conn_string = data.get("azure_connection_string")
    api_key = data.get("ttn_api_key")
    region = data.get("region_profile")
    
    antenna_gain = data.get("antenna_gain")
    max_eirp = data.get("max_eirp")
    keepalive_interval = data.get("keepalive_interval")
    stat_interval = data.get("stat_interval")
    push_timeout_ms = data.get("push_timeout_ms")
    autoquit_threshold = data.get("autoquit_threshold")
    
    try:
        store_secrets_to_hsm(wifi_password, conn_string, api_key, halow_password, zip_pw)
        update_wifi_config(wifi_ssid, wifi_password)
        configure_halow(halow_ssid, halow_password, halow_bandwidth, halow_security)
        set_network_priority(net_prio)
        set_log_password(zip_pw, log_level)
        func_config_gatewayid(server, api_key, region, antenna_gain, max_eirp, keepalive_interval, stat_interval, push_timeout_ms, autoquit_threshold)
        func_config_azure(conn_string)
        
        def delayed_start():
            time.sleep(3)
            start_gateway()
            
        threading.Thread(target=delayed_start).start()
        
        return jsonify({"ok": True, "message": "Configuration saved. Rebooting..."})
    except Exception as e:
        return jsonify({"ok": False, "message": f"Error: {str(e)}"})

if __name__ == "__main__":
    threading.Thread(target=ap_inactivity_watchdog, daemon=True).start()
    app.run(host="0.0.0.0", port=80, threaded=True)