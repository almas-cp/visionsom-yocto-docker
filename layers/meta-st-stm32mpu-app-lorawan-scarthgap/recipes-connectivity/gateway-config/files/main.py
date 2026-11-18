import subprocess
import re
import os
import time
import sys
import shutil

for p in ["/usr/local/sbin", "/usr/sbin", "/sbin"]:
    if p not in os.environ.get("PATH", ""):
        os.environ["PATH"] = f"{p}:{os.environ.get('PATH', '')}"

IN_CONTAINER = os.path.exists("/.dockerenv") or os.path.exists("/app/portal")
NSENTER = "nsenter -t 1 -m -u -n -i" if IN_CONTAINER else ""

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_DIR = "/app/config" if IN_CONTAINER else "/etc/gateway"

os.makedirs(CONFIG_DIR, exist_ok=True)
if not IN_CONTAINER:
    try:
        os.makedirs("/app", exist_ok=True)
        if not os.path.exists("/app/config"):
            os.symlink("/etc/gateway", "/app/config")
    except Exception:
        pass

NET_PRIO_FILE = os.path.join(CONFIG_DIR, "network_priority")
LOG_CREDENTIAL = os.path.join(CONFIG_DIR, "zip_password")
LOG_LEVEL = os.path.join(CONFIG_DIR, "log_level")

def get_eui():
    try:
        for path in [os.path.join(CONFIG_DIR, 'gateway_eui'), '/app/config/gateway_eui', '/etc/gateway/gateway_eui']:
            if os.path.exists(path):
                with open(path, 'r') as f:
                    eui = f.read().strip()
                    if eui: return eui
    except Exception: pass
    return "unknown"

def func_config_gatewayid(server_address, api_key, region=None, antenna_gain=None, max_eirp=None, keepalive_interval=None, stat_interval=None, push_timeout_ms=None, autoquit_threshold=None):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    
    if not region:
        try:
            with open(os.path.join(CONFIG_DIR, "region_profile"), "r") as f:
                region = f.read().strip()
        except Exception:
            region = "AU915"

    # Sanitize server_address: strip protocol (https://, http://, wss://, etc.) and trailing slashes
    clean_server = re.sub(r'^[a-zA-Z0-9+.-]+://', '', server_address.strip()).rstrip('/')

    # Write flat files for Yocto architecture
    with open(os.path.join(CONFIG_DIR, "network_server"), "w") as f:
        f.write(clean_server)
        
    with open(os.path.join(CONFIG_DIR, "gateway_id"), "w") as f:
        f.write(clean_server)
        
    with open(os.path.join(CONFIG_DIR, "region_profile"), "w") as f:
        f.write(region.strip())


    # Read existing parameters from gateway.conf if present
    existing_conf = {}
    ttn_dir = "/app/usr/local/TTN" if IN_CONTAINER else "/usr/local/TTN"
    os.makedirs(ttn_dir, exist_ok=True)
    gw_conf_path = os.path.join(ttn_dir, "gateway.conf")
    
    if os.path.exists(gw_conf_path):
        try:
            with open(gw_conf_path, "r") as f:
                for line in f:
                    if "=" in line:
                        k, v = line.strip().split("=", 1)
                        existing_conf[k] = v
        except Exception as e:
            print(f"Error reading existing gateway.conf: {e}")

    # Priority: Explicitly provided arg > Existing gateway.conf value > Default fallback
    final_keepalive = keepalive_interval if keepalive_interval else existing_conf.get("keepalive_interval", "10s")
    final_stat = stat_interval if stat_interval else existing_conf.get("stat_interval", "300s")
    final_push = push_timeout_ms if push_timeout_ms else existing_conf.get("push_timeout_ms", "2000")
    final_autoquit = autoquit_threshold if autoquit_threshold else existing_conf.get("autoquit_threshold", "60")
    final_gain = antenna_gain if antenna_gain else existing_conf.get("antenna_gain", "2.0")
    final_eirp = max_eirp if max_eirp else existing_conf.get("max_eirp", "30.0")


    # Write gateway.conf for Basics Station preserving custom settings
    try:
        with open(gw_conf_path, "w") as f:
            f.write("network_server=ttn\n")
            f.write(f"server_ip={clean_server}\n")

            f.write(f"frequency={region.strip()}\n")
            f.write(f"keepalive_interval={final_keepalive}\n")
            f.write(f"stat_interval={final_stat}\n")
            f.write(f"push_timeout_ms={final_push}\n")
            f.write(f"autoquit_threshold={final_autoquit}\n")
            f.write(f"antenna_gain={final_gain}\n")
            f.write(f"max_eirp={final_eirp}\n")
    except Exception as e:
        print(f"Error writing gateway.conf: {e}")
    
    # API Key is now stored via store_secrets_to_hsm
    print("Gateway configuration file updated (API key stored separately in HSM)")

def func_config_azure(connection_string):
    os.makedirs(CONFIG_DIR, exist_ok=True)

    # Parse non-sensitive HostName and DeviceId
    hostname_match = re.search(r'HostName=([^;]+)', connection_string)
    deviceid_match = re.search(r'DeviceId=([^;]+)', connection_string)

    if hostname_match:
        with open(os.path.join(CONFIG_DIR, "azure_hostname"), "w") as f:
            f.write(hostname_match.group(1).strip())
        print(f"Saved non-sensitive Azure HostName: {hostname_match.group(1).strip()}")

    if deviceid_match:
        dev_id = deviceid_match.group(1).strip()
        with open(os.path.join(CONFIG_DIR, "azure_device_id"), "w") as f:
            f.write(dev_id)
        print(f"Saved non-sensitive Azure DeviceId: {dev_id}")

        try:
            cmd = f"{NSENTER} hostnamectl set-hostname {dev_id}" if NSENTER else f"hostnamectl set-hostname {dev_id}"
            subprocess.run(cmd, shell=True, check=False)
            cmd_alt = f"{NSENTER} hostname {dev_id}" if NSENTER else f"hostname {dev_id}"
            subprocess.run(cmd_alt, shell=True, check=False)
            with open("/etc/hostname", "w") as f:
                f.write(dev_id + "\n")
            print(f"Updated system hostname to Azure DeviceId: {dev_id}")
            hosts_cmd = f"{NSENTER} sh -c 'grep -qw \"{dev_id}\" /etc/hosts 2>/dev/null || echo \"127.0.0.1 {dev_id}\" >> /etc/hosts'" if NSENTER else f"grep -qw \"{dev_id}\" /etc/hosts 2>/dev/null || echo \"127.0.0.1 {dev_id}\" >> /etc/hosts"
            subprocess.run(hosts_cmd, shell=True, check=False)
        except Exception as e:
            print(f"Failed to update hostname: {e}")

    # Ensure any legacy plaintext connection string file is purged
    for d in [CONFIG_DIR, "/app/config", "/etc/gateway"]:
        legacy_file = os.path.join(d, "connection_string")
        if os.path.exists(legacy_file):
            try:
                os.remove(legacy_file)
                print(f"Purged legacy plaintext connection_string from {legacy_file}")
            except Exception: pass

    print("Configured Azure IoT Edge identity (SharedAccessKey handled exclusively in HSM)")

def set_network_priority(net_prio):
    with open(NET_PRIO_FILE, 'w') as file:
        file.write(net_prio)
    print(f"Stored net_prio ({net_prio}) in {NET_PRIO_FILE}")

def set_log_password(zip_pw, log_level):
    os_ver = os.path.join(CONFIG_DIR, "os_version")
    if os.path.exists(os_ver) or os.path.exists("/etc/gateway/os_version"):
        # v2.0 hardware - store zip_password in HSM securely
        try:
            cmd = f"{NSENTER} /usr/bin/store_to_hsm --stdin" if NSENTER else "/usr/bin/store_to_hsm --stdin"
            subprocess.run(cmd, shell=True, input=f"zip_password={zip_pw}\n", text=True, check=True)
            print(f"Stored log access password securely in HSM.")
            # Delete any legacy plaintext file if it exists
            if os.path.exists(LOG_CREDENTIAL):
                try: os.remove(LOG_CREDENTIAL)
                except Exception: pass
        except subprocess.CalledProcessError as e:
            print(f"Failed to store log password in HSM: {e}")
    else:
        # Legacy hardware without os_version - fallback to plaintext file
        with open(LOG_CREDENTIAL, 'w') as file:
            file.write(zip_pw)
        print(f"Stored log access password ({zip_pw}) in {LOG_CREDENTIAL}")


    with open(LOG_LEVEL, 'w') as file:
        file.write(log_level)
    print(f"Stored log level ({log_level}) in {LOG_LEVEL}")

def configure_wifi(ssid, password):
    # Security is intentionally stored as AUTO. The NetworkModule scans the AP
    # and determines OPEN/WEP/WPA2/WPA3/transition mode at connection time.
    is_open_hint = not password or password.strip() in ("", "NONE", "OPEN", "null")
    sec_mode = "OPEN" if is_open_hint else "AUTO"
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(os.path.join(CONFIG_DIR, "wifi_credentials"), "w") as f:
            f.write(f"WIFI_SSID='{ssid}'\nWIFI_SECURITY='{sec_mode}'\n")
        print(f"Configured Wi-Fi SSID: {ssid}, Security mode: {sec_mode}")
    except Exception as e:
        print(f"Error saving SSID to wifi_credentials: {e}")

    if is_open_hint:
        print(f"Wi-Fi network {ssid} configured with OPEN hint (NetworkModule will verify by scan)")
    else:
        print(f"Wi-Fi security set to AUTO; password remains stored separately in HSM")

def disable_halow():
    print("Disabling HaLow: Purging old credentials and clearing /root/wpa.conf...")
    wpa_conf = 'ctrl_interface=DIR=/var/run/wpa_supplicant\nupdate_config=1\ncountry=AU\n'
    try:
        temp_wpa = '/etc/temp_wpa.conf'
        with open(temp_wpa, 'w') as f:
            f.write(wpa_conf)
        for cfg_file in [os.path.join(CONFIG_DIR, 'halow_ssid'), os.path.join(CONFIG_DIR, 'halow_bandwidth'), os.path.join(CONFIG_DIR, 'halow_security')]:
            if os.path.exists(cfg_file):
                try: os.remove(cfg_file)
                except Exception: pass
                
        command = f'{NSENTER} sh -c "cp /etc/temp_wpa.conf /root/wpa.conf && rm -f /etc/temp_wpa.conf"'
        subprocess.run(command, shell=True, check=False)
        print("Cleared /root/wpa.conf and removed old HaLow configuration files")
        
        subprocess.run(f"{NSENTER} wpa_cli reconfigure || {NSENTER} systemctl stop wpa_supplicant@wlan1 || {NSENTER} systemctl restart wpa_supplicant", shell=True, check=False)
    except Exception as e:
        print(f"Error purging HaLow credentials: {e}")

def configure_halow(halow_ssid, halow_password, halow_bandwidth="4", halow_security="WPA-PSK"):
    if not halow_ssid or not halow_ssid.strip():
        disable_halow()
        return
    print(f"Configuring HaLow for SSID: {halow_ssid}, Security: {halow_security}, Bandwidth: {halow_bandwidth}")
    
    try:
        with open(os.path.join(CONFIG_DIR, 'halow_bandwidth'), 'w') as f:
            f.write(str(halow_bandwidth))
        with open(os.path.join(CONFIG_DIR, 'halow_ssid'), 'w') as f:
            f.write(halow_ssid)
        with open(os.path.join(CONFIG_DIR, 'halow_security'), 'w') as f:
            f.write(halow_security)
            
        print("Saved halow settings to /etc/gateway/. Password stored separately in HSM.")
        
        subprocess.run(f"{NSENTER} /usr/bin/apply_halow.sh", shell=True, check=False)
        print("HaLow configuration applied via apply_halow.sh.")
    except Exception as e:
        print(f"Error configuring HaLow: {e}")

def store_secrets_to_hsm(wifi_password, connection_string, api_key, halow_password="", zip_password=""):
    print("Storing secrets to HSM via Yocto store_to_hsm wrapper (secure stdin pipe)...")
    payload = f"wifi_password={wifi_password}\nazure_connection_string={connection_string}\nttn_api_key={api_key}\nhalow_password={halow_password}\n"
    os_ver = os.path.join(CONFIG_DIR, "os_version")
    if (os.path.exists(os_ver) or os.path.exists("/etc/gateway/os_version")) and zip_password:
        payload += f"zip_password={zip_password}\n"
    command = f"{NSENTER} /usr/bin/store_to_hsm --stdin"
    try:
        result = subprocess.run(command, shell=True, input=payload, check=True, capture_output=True, text=True)
        if result.stdout:
            print(f"store_to_hsm output: {result.stdout}")
        print("Successfully stored all secrets to HSM.")
        # Clean up legacy plaintext file if stored in HSM
        if zip_password and os.path.exists(LOG_CREDENTIAL):
            try: os.remove(LOG_CREDENTIAL)
            except Exception: pass

        
        # (Removed fallback connection string file write to ensure 100% HSM isolation)

        # Trigger Yocto apply_wifi.sh script to generate wpa_supplicant.conf
        print("Applying Wi-Fi configuration...")
        subprocess.run(f"{NSENTER} /usr/bin/apply_wifi.sh", shell=True, check=False)
        print("Wi-Fi configuration applied successfully.")

        # ── CRITICAL: Schedule a host-side reboot BEFORE calling apply_gateway_config.sh ──
        #
        # Problem: apply_gateway_config.sh runs 'iotedge config apply' internally.
        # 'iotedge config apply' restarts aziot-edged, which stops ALL Docker modules
        # including THIS container. Any code after apply_gateway_config.sh in this
        # Python process is NEVER reached because the container is already dead.
        #
        # Solution: Use 'systemd-run' to create a transient timer unit on the HOST
        # (not inside Docker). HOST-level systemd units survive container death.
        # The 35s delay gives apply_gateway_config.sh time to finish before the
        # reboot fires.
        print("Scheduling host-side reboot in 120s (survives container shutdown)...")
        reboot_result = subprocess.run(
            "nsenter -t 1 -m -u -n -i -p -- "
            "systemd-run --on-active=120 --unit=gateway-config-reboot "
            "systemctl reboot",
            shell=True, check=False, capture_output=True, text=True
        )
        if reboot_result.returncode == 0:
            print("Host reboot scheduled via systemd-run. Gateway will reboot in ~120s.")
        else:
            # Fallback: background shell process in host PID namespace
            print(f"systemd-run failed ({reboot_result.stderr.strip()}), using fallback reboot schedule...")
            subprocess.Popen(
                "nsenter -t 1 -m -u -n -i -p -- sh -c 'sleep 120 && systemctl reboot'",
                shell=True
            )
            print("Fallback reboot scheduled via nsenter background process.")

        # Trigger Yocto apply_gateway_config.sh — this will internally run
        # 'iotedge config apply' which will kill THIS container. That is expected.
        # The reboot above is already scheduled on the host and will fire regardless.
        print("Applying Azure IoT Edge & LoRaWAN configuration from HSM...")
        subprocess.run(f"{NSENTER} /usr/bin/apply_gateway_config.sh --no-restart", shell=True, check=False)
        print("Azure IoT Edge & LoRaWAN configuration applied successfully.")
    except subprocess.CalledProcessError as e:
        print(f"Error executing HSM/Wi-Fi/Gateway scripts: {e.stderr or e.stdout or str(e)}")

# Function to update Wi-Fi credentials
def update_wifi_config(ssid, passphrase):
    print("Connection mode: WLAN selected for communication")
    wireless_net = "[Match]\nName=wlan*\n\n[Network]\nDHCP=yes\nIPv6AcceptRA=yes\n"
    for dest in ["/etc/systemd/network", "/lib/systemd/network", "/app/usr/lib/systemd/network"]:
        try:
            os.makedirs(dest, exist_ok=True)
            target = os.path.join(dest, "51-wireless.network")
            if not os.path.exists(target):
                with open(target, "w") as f:
                    f.write(wireless_net)
        except Exception:
            pass
    configure_wifi(ssid, passphrase)

def kill_process(pattern):
    try:
        cmd = f"{NSENTER} pkill -9 -f '{pattern}'" if NSENTER else f"pkill -9 -f '{pattern}'"
        subprocess.run(cmd, shell=True, check=False)
    except Exception:
        pass
    try:
        cmd = f"{NSENTER} ps ax" if NSENTER else "ps ax"
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        for line in result.stdout.split('\n'):
            if re.search(pattern, line) and 'grep' not in line:
                parts = line.strip().split()
                if parts and parts[0].isdigit():
                    pid = parts[0]
                    kcmd = f"{NSENTER} kill -9 {pid}" if NSENTER else f"kill -9 {pid}"
                    subprocess.run(kcmd, shell=True, check=False)
    except Exception:
        pass

# ─── AP LED Indication Helpers ───────────────────────────────────────────────
import threading

_ap_led_stop_event = threading.Event()
_ap_led_thread = None

def _set_led(led_name, value):
    """Write a brightness value (0=off, 1=on) to a sysfs LED node."""
    try:
        path = f"/sys/class/leds/{led_name}/brightness"
        if os.path.exists(path):
            with open(path, 'w') as f:
                f.write(str(value))
    except Exception as e:
        print(f"LED {led_name}: {e}")

def _ap_blink_worker(led_a, led_b, stop_event):
    """Background thread: blink led_a + led_b together until stop_event is set."""
    state = False
    while not stop_event.is_set():
        state = not state
        v = 1 if state else 0
        _set_led(led_a, v)
        _set_led(led_b, v)
        stop_event.wait(0.5)  # 500 ms blink rate

def ap_leds_blinking(led_a, led_b):
    """Start blinking led_a + led_b together (AP starting up)."""
    global _ap_led_stop_event, _ap_led_thread
    ap_leds_off(led_a, led_b)       # clear previous state
    _ap_led_stop_event = threading.Event()
    _ap_led_thread = threading.Thread(
        target=_ap_blink_worker,
        args=(led_a, led_b, _ap_led_stop_event),
        daemon=True
    )
    _ap_led_thread.start()
    print(f"AP LED indication: blinking {led_a} + {led_b}")

def ap_leds_solid(led_a, led_b):
    """Stop blinking and turn both LEDs solid ON (AP ready)."""
    global _ap_led_stop_event, _ap_led_thread
    if _ap_led_stop_event:
        _ap_led_stop_event.set()
    if _ap_led_thread:
        _ap_led_thread.join(timeout=2)
    _set_led(led_a, 1)
    _set_led(led_b, 1)
    print(f"AP LED indication: solid {led_a} + {led_b} (AP ready)")

def ap_leds_off(led_a=None, led_b=None):
    """Stop blinking and turn LEDs off (AP teardown / failure)."""
    global _ap_led_stop_event, _ap_led_thread
    if _ap_led_stop_event:
        _ap_led_stop_event.set()
    if _ap_led_thread:
        _ap_led_thread.join(timeout=2)
    _ap_led_thread = None
    if led_a:
        _set_led(led_a, 0)
    if led_b:
        _set_led(led_b, 0)
    print("AP LED indication: off")

def _wifi_led_worker(stop_event):
    _set_led("ble-led", 0)
    while not stop_event.is_set():
        res = subprocess.run(f"{NSENTER} iw dev wlan0 station dump 2>/dev/null | grep -q 'Station '", shell=True)
        if res.returncode == 0:
            # Client connected to Wi-Fi AP: Solid ON
            _set_led("wifi-led", 1)
            stop_event.wait(1.0)
        else:
            # Waiting for client: Blink (0.5s ON, 0.5s OFF)
            _set_led("wifi-led", 1)
            stop_event.wait(0.5)
            _set_led("wifi-led", 0)
            stop_event.wait(0.5)

def start_wifi_led_monitor():
    global _ap_led_stop_event, _ap_led_thread
    ap_leds_off("ble-led", "wifi-led")
    _set_led("ble-led", 0)
    _ap_led_stop_event = threading.Event()
    _ap_led_thread = threading.Thread(target=_wifi_led_worker, args=(_ap_led_stop_event,), daemon=True)
    _ap_led_thread.start()
    print("Wi-Fi AP LED monitor started: wifi-led only (ble-led OFF)")

def _eth_led_worker(stop_event):
    while not stop_event.is_set():
        res = subprocess.run(
            f"{NSENTER} sh -c 'cat /sys/class/net/end0/carrier 2>/dev/null || cat /sys/class/net/eth0/carrier 2>/dev/null || echo 0'",
            shell=True, capture_output=True, text=True
        )
        carrier = res.stdout.strip()
        if carrier == "1":
            # Cable plugged in & carrier active: Both Solid ON
            _set_led("wifi-led", 1)
            _set_led("ble-led", 1)
            stop_event.wait(1.0)
        else:
            # Waiting for cable / link: Both Blink together (0.5s ON, 0.5s OFF)
            _set_led("wifi-led", 1)
            _set_led("ble-led", 1)
            stop_event.wait(0.5)
            _set_led("wifi-led", 0)
            _set_led("ble-led", 0)
            stop_event.wait(0.5)

def start_eth_led_monitor():
    global _ap_led_stop_event, _ap_led_thread
    ap_leds_off("ble-led", "wifi-led")
    _ap_led_stop_event = threading.Event()
    _ap_led_thread = threading.Thread(target=_eth_led_worker, args=(_ap_led_stop_event,), daemon=True)
    _ap_led_thread.start()
    print("Ethernet AP LED monitor started: both ble-led and wifi-led")
# ─────────────────────────────────────────────────────────────────────────────

def setup_access_point():
    """
    Mirror the working native wifi_ap.sh sequence exactly:
    1. Set lock file so wan-failover backs off
    2. Stop wifi-wlan0.service (prevents wpa_supplicant auto-restart)
    3. Stop systemd-networkd (stop it — do NOT restart it; restarting resets the IP)
    4. Kill all wpa_supplicant and dnsmasq instances
    5. Flush IP, bring interface down, bring it up clean
    6. Assign IP manually with ip addr add
    7. Launch hostapd directly (not via systemctl) with a temp config
    8. Launch dnsmasq directly (not via systemctl) with a temp config
    """
    AP_IP      = "192.168.72.1"
    AP_SSID    = f"Gateway-{get_eui()}"  # Match native wifi_ap.sh — use EUI as SSID
    AP_CHANNEL = "6"
    IFACE      = "wlan0"
    HOSTAPD_CONF = "/tmp/hostapd_ap.conf"
    DNSMASQ_CONF = "/tmp/dnsmasq_ap.conf"
    DNSMASQ_PID  = "/tmp/dnsmasq_ap.pid"

    try:
        # --- Step 1: Lock out wan-failover and ensure ble-led stays OFF ---
        subprocess.run(f"{NSENTER} touch /tmp/ap_mode_active", shell=True, check=False)
        _set_led("ble-led", 0)

        # --- Step 2: Stop AND MASK the Yocto wifi client service ---
        # 'stop' alone is not enough — systemd will restart an 'enabled' service.
        # 'mask' creates a symlink to /dev/null, preventing any restart until we unmask it.
        subprocess.run(f"{NSENTER} systemctl stop wifi-wlan0.service", shell=True, check=False)
        subprocess.run(f"{NSENTER} systemctl mask wifi-wlan0.service", shell=True, check=False)

        # --- Step 3: Stop wpa_supplicant in every possible way ---
        subprocess.run(f"{NSENTER} systemctl stop wpa_supplicant@{IFACE}.service", shell=True, check=False)
        subprocess.run(f"{NSENTER} systemctl mask wpa_supplicant@{IFACE}.service", shell=True, check=False)
        subprocess.run(f"{NSENTER} systemctl stop wpa_supplicant", shell=True, check=False)
        subprocess.run(f"{NSENTER} killall wpa_supplicant", shell=True, check=False)
        kill_process('wpa_supplicant')
        time.sleep(2)  # Give wpa_supplicant time to fully die before touching the interface

        # --- Step 4: Do NOT stop systemd-networkd, or Ethernet will drop! ---
        # subprocess.run(f"{NSENTER} systemctl stop systemd-networkd.socket", shell=True, check=False)
        # subprocess.run(f"{NSENTER} systemctl stop systemd-networkd.service", shell=True, check=False)
        time.sleep(1)

        # --- Step 5: Stop any existing dnsmasq and hostapd so ports and interfaces are free ---
        subprocess.run(f"{NSENTER} systemctl stop dnsmasq", shell=True, check=False)
        subprocess.run(f"{NSENTER} killall dnsmasq", shell=True, check=False)
        subprocess.run(f"{NSENTER} pkill -x dnsmasq", shell=True, check=False)
        subprocess.run(f"{NSENTER} systemctl stop hostapd", shell=True, check=False)
        subprocess.run(f"{NSENTER} killall hostapd", shell=True, check=False)
        time.sleep(4)

        # --- Step 5.5: Ensure radio is not blocked ---
        subprocess.run(f"{NSENTER} rfkill unblock wifi", shell=True, check=False)

        # --- Step 6: Bring interface down, flush, bring up clean ---
        subprocess.run(f"{NSENTER} ip addr flush dev {IFACE}", shell=True, check=False)
        subprocess.run(f"{NSENTER} ip link set {IFACE} down", shell=True, check=False)
        time.sleep(1)
        subprocess.run(f"{NSENTER} ip link set {IFACE} up", shell=True, check=False)

        # --- Step 7: Assign the AP IP manually (do NOT rely on systemd-networkd) ---
        subprocess.run(f"{NSENTER} ip addr add {AP_IP}/24 dev {IFACE}", shell=True, check=False)
        subprocess.run(f"{NSENTER} touch /tmp/ap_mode_active", shell=True, check=False)
        print(f"Interface {IFACE} brought up with IP {AP_IP}.")

        # --- Step 8: Write hostapd config and launch it directly ---
        hostapd_conf_content = (
            f"interface={IFACE}\n"
            f"driver=nl80211\n"
            f"ssid={AP_SSID}\n"
            f"hw_mode=g\n"
            f"channel={AP_CHANNEL}\n"
            f"wmm_enabled=0\n"
            f"macaddr_acl=0\n"
            f"auth_algs=1\n"
            f"ignore_broadcast_ssid=0\n"
        )
        hostapd_conf_cmd = f"cat > {HOSTAPD_CONF} << 'EOF'\n{hostapd_conf_content}EOF"
        subprocess.run(f"{NSENTER} bash -c '{hostapd_conf_cmd}'", shell=True, check=False)
        result = subprocess.run(
            f"{NSENTER} hostapd -B -P /tmp/hostapd_ap.pid {HOSTAPD_CONF}",
            shell=True, capture_output=True, text=True
        )
        time.sleep(2)
        # Verify if it actually started regardless of the exit code (hostapd often exits with warnings)
        check_ap = subprocess.run(f"{NSENTER} iw dev {IFACE} info", shell=True, capture_output=True, text=True)
        if "type AP" not in check_ap.stdout and result.returncode != 0:
            raise RuntimeError(f"hostapd failed to put interface in AP mode: {result.stderr or result.stdout}")

        # --- Final guard: kill any wpa_supplicant that sneaked back during hostapd startup ---
        subprocess.run(f"{NSENTER} killall wpa_supplicant", shell=True, check=False)
        kill_process('wpa_supplicant')

        print("hostapd started successfully and interface is in AP mode.")

        # --- Step 9: Write dnsmasq config and launch it directly ---
        dnsmasq_conf_content = (
            f"interface={IFACE}\n"
            f"bind-interfaces\n"
            f"dhcp-range=192.168.72.10,192.168.72.50,12h\n"
            f"dhcp-option=option:router,{AP_IP}\n"
            f"dhcp-option=option:dns-server,{AP_IP}\n"
            f"address=/#/{AP_IP}\n"
            f"no-resolv\n"
            f"log-dhcp\n"
        )
        dnsmasq_conf_cmd = f"cat > {DNSMASQ_CONF} << 'EOF'\n{dnsmasq_conf_content}EOF"
        subprocess.run(f"{NSENTER} bash -c '{dnsmasq_conf_cmd}'", shell=True, check=False)
        subprocess.run(
            f"{NSENTER} dnsmasq --conf-file={DNSMASQ_CONF} --pid-file={DNSMASQ_PID} --bind-interfaces",
            shell=True, check=False
        )
        # --- Final step: Free port 80 so Flask can bind cleanly ---
        subprocess.run(f"{NSENTER} fuser -k 80/tcp", shell=True, check=False)
        time.sleep(1)  # brief pause to let the port actually free
        print(f"Access point '{AP_SSID}' is active. Connect and open http://{AP_IP}")
        # NOTE: ap_leds_solid() is intentionally NOT called here.
        # LEDs go solid only after Flask successfully binds port 80 (verified in handle_button_press).

    except Exception as e:
        print(f"Failed to create Access point: {e}")
        # ❌ Something failed — turn LEDs off so user knows AP did not start
        ap_leds_off("ble-led", "wifi-led")

def setup_access_point_eth():
    """
    Mirror the working native eth_ap.sh sequence exactly:
    1. Stop dnsmasq (free ports 53/67)
    2. Stop systemd-networkd (STOP not restart — restart would wipe the IP)
    3. Flush/down/up the interface
    4. Assign IP manually with ip addr add
    5. Launch dnsmasq directly (not via systemctl)
    """
    AP_IP        = "192.168.100.1"
    # Dynamically detect the Ethernet interface — newer kernels use "end0", not "eth0"
    try:
        iface_result = subprocess.run(
            f"{NSENTER} ip -o link show | awk '{{print $2}}' | tr -d ':' | grep -E '^(eth|end|enp|eno)[0-9]' | head -1",
            shell=True, capture_output=True, text=True
        )
        IFACE = iface_result.stdout.strip() or "end0"
    except Exception:
        IFACE = "end0"
    print(f"Ethernet AP: using interface {IFACE}")
    DNSMASQ_CONF = "/tmp/dnsmasq_eth.conf"
    DNSMASQ_PID  = "/tmp/dnsmasq_eth.pid"

    try:
        # --- Step 1: Stop dnsmasq so ports are free ---
        subprocess.run(f"{NSENTER} systemctl stop dnsmasq", shell=True, check=False)
        subprocess.run(f"{NSENTER} killall dnsmasq", shell=True, check=False)
        subprocess.run(f"{NSENTER} pkill -x dnsmasq", shell=True, check=False)
        time.sleep(1)

        # --- Step 2: ADD 192.168.100.1 as a secondary alias — do NOT flush the existing IP ---
        # This keeps the original DHCP IP (e.g. 192.168.1.59) alive so SSH stays connected
        # and the user can reconnect after unplugging the config cable without a reboot.
        # Remove any stale AP IP first (idempotent), then add fresh.
        subprocess.run(f"{NSENTER} ip addr del {AP_IP}/24 dev {IFACE}", shell=True, check=False)
        subprocess.run(f"{NSENTER} ip link set {IFACE} up", shell=True, check=False)
        subprocess.run(f"{NSENTER} ip addr add {AP_IP}/24 dev {IFACE}", shell=True, check=False)
        subprocess.run(f"{NSENTER} touch /tmp/ap_mode_active", shell=True, check=False)
        print(f"Interface {IFACE} gained secondary config IP {AP_IP} (original DHCP IP preserved).")

        # --- Step 3: Write dnsmasq config bound to AP IP only --- leave other interfaces untouched ---
        # NOTE: We use --port=0 to DISABLE dnsmasq's DNS server entirely.
        # This prevents the captive-portal wildcard DNS (address=/#/) from overriding the
        # gateway's OWN DNS lookups, which would kill OpenVPN and any hostname-based connections.
        # The connected laptop gets DHCP (an IP + gateway) and can navigate to 192.168.100.1 directly.
        dnsmasq_conf_content = (
            f"port=0\n"                      # DHCP only — DNS disabled so gateway DNS is not affected
            f"interface={IFACE}\n"
            f"listen-address={AP_IP}\n"
            f"bind-interfaces\n"
            f"dhcp-range=192.168.100.10,192.168.100.50,12h\n"
            f"dhcp-option=option:router,{AP_IP}\n"
            f"log-dhcp\n"
        )
        dnsmasq_conf_cmd = f"cat > {DNSMASQ_CONF} << 'EOF'\n{dnsmasq_conf_content}EOF"
        subprocess.run(f"{NSENTER} bash -c '{dnsmasq_conf_cmd}'", shell=True, check=False)
        subprocess.run(
            f"{NSENTER} dnsmasq --conf-file={DNSMASQ_CONF} --pid-file={DNSMASQ_PID}",
            shell=True, check=False
        )
        # --- Final step: Free port 80 so Flask can bind cleanly ---
        subprocess.run(f"{NSENTER} fuser -k 80/tcp", shell=True, check=False)
        time.sleep(1)  # brief pause to let the port actually free
        print(f"Ethernet config mode active. Connect to {IFACE} and open http://{AP_IP}")
        # NOTE: ap_leds_solid() is intentionally NOT called here.
        # LEDs go solid only after Flask successfully binds port 80 (verified in handle_button_press).
    except Exception as e:
        print(f"Failed to configure Ethernet AP: {e}")
        # ❌ Something failed — turn LEDs off
        ap_leds_off("ble-led", "halow-led")

def teardown_access_point():
    """
    Teardown mirrors native wifi_ap.sh cleanup() trap:
    - Kill directly-launched hostapd and dnsmasq via PID files
    - Flush the interface
    - Restore systemd-networkd and wpa_supplicant
    """
    print("Tearing down Access Point mode (inactivity timeout) and rebooting host...")
    try:
        # Turn off AP LEDs before teardown so normal LED state is restored after reboot
        ap_leds_off("ble-led", "wifi-led")
        ap_leds_off("ble-led", "halow-led")

        # Remove AP lock so wan-failover resumes
        subprocess.run(f"{NSENTER} rm -f /tmp/ap_mode_active", shell=True, check=False)

        # Kill directly-launched processes via their PID files
        for pid_file in ["/tmp/hostapd_ap.pid", "/tmp/dnsmasq_ap.pid", "/tmp/dnsmasq_eth.pid"]:
            subprocess.run(
                f"{NSENTER} sh -c '[ -f {pid_file} ] && kill $(cat {pid_file}) 2>/dev/null; rm -f {pid_file}'",
                shell=True, check=False
            )

        # Also stop the systemd hostapd unit in case it was running from a previous session
        subprocess.run(f"{NSENTER} systemctl stop hostapd", shell=True, check=False)

        # Unmask services we masked during AP setup so normal Wi-Fi is fully restored after reboot
        subprocess.run(f"{NSENTER} systemctl unmask wifi-wlan0.service", shell=True, check=False)
        subprocess.run(f"{NSENTER} systemctl unmask wpa_supplicant@wlan0.service", shell=True, check=False)

        # --- BUG FIX: Remove zombie AP network config files that were left behind ---
        # These files (created by native AP scripts) tell systemd-networkd to make wlan0
        # a DHCP server instead of a DHCP client, which breaks the Wi-Fi default route
        # causing wan-failover to skip Wi-Fi even when it's priority.
        for zombie_file in [
            "/etc/systemd/network/10-wlan0.network",
            "/etc/systemd/network/10-eth0.network",
        ]:
            subprocess.run(f"{NSENTER} rm -f {zombie_file}", shell=True, check=False)
        print("Removed stale AP network config files (10-wlan0.network, 10-eth0.network).")

        # Remove the Ethernet AP secondary IP alias (does NOT flush the original DHCP IP)
        # This means SSH reconnects immediately after unplugging the config cable — no reboot needed.
        try:
            iface_result = subprocess.run(
                f"{NSENTER} ip -o link show | awk '{{print $2}}' | tr -d ':' | grep -E '^(eth|end|enp|eno)[0-9]' | head -1",
                shell=True, capture_output=True, text=True
            )
            eth_iface = iface_result.stdout.strip() or "end0"
        except Exception:
            eth_iface = "end0"
        subprocess.run(f"{NSENTER} ip addr del 192.168.100.1/24 dev {eth_iface}", shell=True, check=False)

        # Restore wlan0 to clean state
        subprocess.run(f"{NSENTER} ip addr flush dev wlan0", shell=True, check=False)

        # Restart systemd-networkd (both socket and service) so all interfaces get proper DHCP/routes again
        subprocess.run(f"{NSENTER} systemctl restart systemd-networkd.socket", shell=True, check=False)
        subprocess.run(f"{NSENTER} systemctl restart systemd-networkd.service", shell=True, check=False)
        subprocess.run(f"{NSENTER} systemctl start dnsmasq", shell=True, check=False)
        print("Networking fully restored. SSH will be available again without reboot.")
    except Exception as e:
        print(f"Error tearing down AP: {e}")
    time.sleep(2)
    reboot_host()
    sys.exit(0)

def reboot_host():
    reboot_sh = os.path.join(SCRIPT_DIR, "reboot_host.sh")
    if os.path.exists(reboot_sh):
        subprocess.run(['sh', reboot_sh])
    else:
        subprocess.run(f"{NSENTER} systemctl reboot", shell=True)

def reset_config():
    try:
        # Create unconfigured flag so on next boot it immediately enters BLE setup mode
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(os.path.join(CONFIG_DIR, "unconfigured"), "w") as f:
            f.write("1\n")
        subprocess.run(['sh', '-c', 'echo "" > /sbin/credential_conf'], check=False)
        cmd = f"{NSENTER} /usr/bin/store-gateway-secrets /dev/i2c-0 --clear" if NSENTER else "/usr/bin/store-gateway-secrets /dev/i2c-0 --clear"
        subprocess.run(cmd, shell=True, check=False)
        for w in [os.path.join(CONFIG_DIR, "wifi_credentials"), "/etc/gateway/wifi_credentials"]:
            if os.path.exists(w):
                try: os.remove(w)
                except Exception: pass
        print("Configuration Reset success.")
        print("LORA Gateway will reset in 5 seconds.")
        time.sleep(5)
        reboot_host()
    except Exception as e:
        print("Failed to Reset Configuration:", e)

def start_gateway():
    print("LORA Gateway will start in 5 seconds.")
    # Turn off AP LEDs so normal LED state is cleanly restored after reboot
    ap_leds_off("ble-led", "wifi-led")
    _set_led("ble-led", 0)
    _set_led("wifi-led", 0)
    try:
        if os.path.exists("/tmp/gateway_setup_mode"):
            os.remove("/tmp/gateway_setup_mode")
        for unconf in ["/etc/gateway/unconfigured", "/app/config/unconfigured"]:
            if os.path.exists(unconf):
                os.remove(unconf)
    except Exception:
        pass
    # Unmask the Wi-Fi services we masked during AP mode so normal Wi-Fi works after reboot
    subprocess.run(f"{NSENTER} systemctl unmask wifi-wlan0.service", shell=True, check=False)
    subprocess.run(f"{NSENTER} systemctl unmask wpa_supplicant@wlan0.service", shell=True, check=False)
    subprocess.run(f"{NSENTER} rm -f /tmp/ap_mode_active", shell=True, check=False)
    # Remove zombie AP network config files so systemd-networkd treats wlan0 as a DHCP client
    for zombie_file in [
        "/etc/systemd/network/10-wlan0.network",
        "/etc/systemd/network/10-eth0.network",
    ]:
        subprocess.run(f"{NSENTER} rm -f {zombie_file}", shell=True, check=False)
    print("Removed stale AP network config files. Wi-Fi route will be correct after reboot.")
    time.sleep(5)
    reboot_host()
    exit(0)

# ─── SETUP MODE STATE MACHINE & FIRST-BOOT MANAGEMENT ────────────────────────
SETUP_MODE_FILE = "/tmp/gateway_setup_mode"

def get_current_setup_mode():
    if os.path.exists(SETUP_MODE_FILE):
        try:
            with open(SETUP_MODE_FILE, "r") as f:
                mode = f.read().strip().lower()
                if mode in ("ble", "wifi_ap", "eth_ap"):
                    return mode
        except Exception:
            pass
    return "idle"

def set_current_setup_mode(mode):
    try:
        if mode == "idle":
            if os.path.exists(SETUP_MODE_FILE):
                os.remove(SETUP_MODE_FILE)
        else:
            with open(SETUP_MODE_FILE, "w") as f:
                f.write(mode)
    except Exception:
        pass

def is_gateway_configured():
    """Returns True if gateway has valid credentials, False if fresh out-of-the-box."""
    # 1. Explicit unconfigured flag check
    for p in [os.path.join(CONFIG_DIR, "unconfigured"), "/etc/gateway/unconfigured", "/app/config/unconfigured"]:
        if os.path.exists(p):
            return False

    # 2. Check if Wi-Fi credentials exist and have a non-empty SSID
    for p in [os.path.join(CONFIG_DIR, "wifi_credentials"), "/etc/gateway/wifi_credentials", "/app/config/wifi_credentials"]:
        if os.path.exists(p):
            try:
                with open(p, "r") as f:
                    content = f.read()
                    if "WIFI_SSID=" in content:
                        ssid = content.split("WIFI_SSID='")[1].split("'")[0].strip()
                        if ssid:
                            return True
            except Exception:
                pass

    # 3. Check if Azure identity is configured
    for p in [os.path.join(CONFIG_DIR, "azure_device_id"), "/etc/gateway/azure_device_id", "/app/config/azure_device_id"]:
        if os.path.exists(p):
            try:
                with open(p, "r") as f:
                    if f.read().strip():
                        return True
            except Exception:
                pass

    # 4. Check if LoRa network server is configured
    for p in [os.path.join(CONFIG_DIR, "network_server"), "/etc/gateway/network_server", "/app/config/network_server"]:
        if os.path.exists(p):
            try:
                with open(p, "r") as f:
                    if f.read().strip():
                        return True
            except Exception:
                pass

    # 5. Check SE050 HSM for stored secrets
    try:
        cmd = f"{NSENTER} /usr/bin/read-gateway-secrets /dev/i2c-0" if NSENTER else "/usr/bin/read-gateway-secrets /dev/i2c-0"
        res = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
        for line in res.stdout.splitlines():
            if line.startswith("azure_connection_string:") or line.startswith("wifi_password:") or line.startswith("ttn_api_key:"):
                val = line.split(":", 1)[1].strip()
                if val and not any(val.startswith(x) for x in ("NOT FOUND", "ERROR", "NONE")):
                    return True
    except Exception:
        pass

    return False

def stop_all_setup_modes():
    """Tear down any active setup mode (BLE, Wi-Fi AP, or Ethernet AP) cleanly so only one mode runs at a time."""
    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
    app_script = os.path.join(SCRIPT_DIR, "app.py")
    app_eth_script = os.path.join(SCRIPT_DIR, "app_eth.py")
    ble_script = os.path.join(SCRIPT_DIR, "ble.py")
    ble_provision_sh = os.path.join(SCRIPT_DIR, "ble_provision.sh")

    # 1. Stop BLE processes and force Bluetooth radio completely off
    kill_process("ble_provision.sh")
    kill_process(ble_provision_sh)
    kill_process("ble.py")
    kill_process(ble_script)
    subprocess.run(f"{NSENTER} pkill -9 -f ble_provision.sh", shell=True, check=False)
    subprocess.run(f"{NSENTER} pkill -9 -f ble.py", shell=True, check=False)
    subprocess.run(f"{NSENTER} bluetoothctl discoverable off", shell=True, check=False)
    subprocess.run(f"{NSENTER} hciconfig hci0 noscan", shell=True, check=False)
    subprocess.run(f"{NSENTER} hciconfig hci0 down", shell=True, check=False)

    # 2. Stop Flask web apps
    kill_process(app_script)
    kill_process("app.py")
    kill_process(app_eth_script)
    kill_process("app_eth.py")
    subprocess.run(f"{NSENTER} pkill -9 -f app.py", shell=True, check=False)
    subprocess.run(f"{NSENTER} pkill -9 -f app_eth.py", shell=True, check=False)

    # 3. Stop hostapd / dnsmasq and free port 80
    for pid_file in ["/tmp/hostapd_ap.pid", "/tmp/dnsmasq_ap.pid", "/tmp/dnsmasq_eth.pid"]:
        subprocess.run(
            f"{NSENTER} sh -c '[ -f {pid_file} ] && kill -9 $(cat {pid_file}) 2>/dev/null; rm -f {pid_file}'",
            shell=True, check=False
        )
    subprocess.run(f"{NSENTER} systemctl stop hostapd", shell=True, check=False)
    subprocess.run(f"{NSENTER} pkill -9 hostapd", shell=True, check=False)
    subprocess.run(f"{NSENTER} fuser -k 80/tcp", shell=True, check=False)
    subprocess.run(f"{NSENTER} systemctl unmask wifi-wlan0.service", shell=True, check=False)
    subprocess.run(f"{NSENTER} systemctl unmask wpa_supplicant@wlan0.service", shell=True, check=False)
    subprocess.run(f"{NSENTER} rm -f /tmp/ap_mode_active", shell=True, check=False)

    # 4. Remove Ethernet AP secondary alias if assigned
    try:
        iface_res = subprocess.run(
            f"{NSENTER} ip -o link show | awk '{{print $2}}' | tr -d ':' | grep -E '^(eth|end|enp|eno)[0-9]' | head -1",
            shell=True, capture_output=True, text=True
        )
        eth_iface = iface_res.stdout.strip() or "end0"
        subprocess.run(f"{NSENTER} ip addr del 192.168.100.1/24 dev {eth_iface}", shell=True, check=False)
    except Exception:
        pass

    # 5. Stop LED threads and turn off both LEDs
    ap_leds_off("ble-led", "wifi-led")
    _set_led("ble-led", 0)
    _set_led("wifi-led", 0)

def start_ble_mode():
    print(">>> Entering SETUP MODE: Bluetooth (BLE)...")
    set_current_setup_mode("ble")
    stop_all_setup_modes()

    # Turn on BLE LED (WiFi LED off)
    _set_led("ble-led", 1)
    _set_led("wifi-led", 0)

    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
    ble_script = os.path.join(SCRIPT_DIR, "ble.py")
    ble_provision_sh = os.path.join(SCRIPT_DIR, "ble_provision.sh")

    try:
        if os.path.exists(ble_provision_sh):
            subprocess.Popen(["sh", ble_provision_sh])
        else:
            subprocess.run(["hciconfig", "hci0", "up"], check=False)
            print("Bluetooth interface hci0 brought up.")
            subprocess.Popen(["python3", "-u", ble_script])
        print("BLE Setup Mode active. Connect via Mobile App (GATT service 0x4567).")
    except Exception as e:
        print(f"Failed to start BLE setup: {e}")

def start_wifi_ap_mode():
    print(">>> Entering SETUP MODE: Wi-Fi Access Point...")
    set_current_setup_mode("wifi_ap")
    stop_all_setup_modes()

    # Start Wi-Fi LED monitor immediately so ONLY wifi-led blinks right away and ble-led is OFF
    start_wifi_led_monitor()

    setup_access_point()
    time.sleep(3)

    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
    app_script = os.path.join(SCRIPT_DIR, "app.py")
    subprocess.Popen(["python3", "-u", app_script])

    flask_ok = False
    for _ in range(20):
        time.sleep(0.5)
        result = subprocess.run("grep -q ':0050 ' /proc/net/tcp 2>/dev/null || grep -q ':0050 ' /proc/net/tcp6 2>/dev/null", shell=True)
        if result.returncode == 0:
            flask_ok = True
            break

    if flask_ok:
        eui = get_eui()
        print(f"Wi-Fi AP active. Connect to SSID 'Gateway-{eui}' and open http://192.168.72.1")
    else:
        print("ERROR: Flask failed to bind port 80 on Wi-Fi AP.")
        ap_leds_off("ble-led", "wifi-led")

def start_eth_ap_mode():
    print(">>> Entering SETUP MODE: Ethernet Access Point...")
    set_current_setup_mode("eth_ap")
    stop_all_setup_modes()

    # Start Ethernet LED monitor immediately so BOTH ble-led and wifi-led blink right away
    start_eth_led_monitor()

    setup_access_point_eth()
    time.sleep(3)

    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
    app_eth_script = os.path.join(SCRIPT_DIR, "app_eth.py")
    subprocess.Popen(["python3", "-u", app_eth_script])

    flask_ok = False
    for _ in range(20):
        time.sleep(0.5)
        result = subprocess.run("grep -q ':0050 ' /proc/net/tcp 2>/dev/null || grep -q ':0050 ' /proc/net/tcp6 2>/dev/null", shell=True)
        if result.returncode == 0:
            flask_ok = True
            break

    if flask_ok:
        print("Ethernet AP active. Connect via Ethernet cable and open http://192.168.100.1")
    else:
        print("ERROR: Flask failed to bind port 80 on Ethernet AP.")
        ap_leds_off("ble-led", "wifi-led")

def handle_button_press(elapsed_time):
    print(f"Processing button press duration: {elapsed_time}s")

    # 1. Factory reset if held for >= 20s
    if elapsed_time >= 20:
        print("Button held for >= 20s: Initiating Factory Reset...")
        reset_config()
        return

    current_mode = get_current_setup_mode()
    print(f"Current setup mode: {current_mode}")

    # 2. If currently in normal operation (MODE_IDLE)
    if current_mode == "idle":
        if 5 <= elapsed_time < 20:
            print("Button held for 5-10s in IDLE: Entering Setup Mode (BLE)...")
            start_ble_mode()
        else:
            print(f"Short press ({elapsed_time}s) in IDLE ignored to protect running operations. Hold 5-10s to enter setup mode.")
        return

    # 3. If ALREADY in a setup mode: Single press cycles to next mode!
    # BLE -> Wi-Fi AP -> Ethernet AP -> BLE
    if current_mode == "ble":
        print("Setup Mode: Switching from BLE to Wi-Fi AP...")
        start_wifi_ap_mode()
    elif current_mode == "wifi_ap":
        print("Setup Mode: Switching from Wi-Fi AP to Ethernet AP...")
        start_eth_ap_mode()
    elif current_mode == "eth_ap":
        print("Setup Mode: Switching from Ethernet AP to BLE...")
        start_ble_mode()

def check_first_boot():
    print("Checking if gateway is configured...")
    if not is_gateway_configured():
        print("Gateway is UNCONFIGURED (fresh out-of-the-box). Automatically starting BLE Setup Mode...")
        start_ble_mode()
    else:
        print("Gateway is ALREADY CONFIGURED. Remaining in normal IDLE mode.")
        set_current_setup_mode("idle")
        _set_led("ble-led", 0)
        _set_led("wifi-led", 0)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 main.py <check-first-boot | cycle | button <duration> | <duration>>")
        sys.exit(1)

    cmd = sys.argv[1].lower()

    if cmd == "check-first-boot":
        check_first_boot()
    elif cmd == "cycle":
        current_mode = get_current_setup_mode()
        if current_mode == "idle" or current_mode == "eth_ap":
            start_ble_mode()
        elif current_mode == "ble":
            start_wifi_ap_mode()
        elif current_mode == "wifi_ap":
            start_eth_ap_mode()
    elif cmd == "button" and len(sys.argv) >= 3:
        try:
            dur = int(sys.argv[2])
            handle_button_press(dur)
        except ValueError:
            print(f"Invalid duration: {sys.argv[2]}")
    elif cmd.isdigit():
        handle_button_press(int(cmd))
    else:
        print(f"Unknown command: {cmd}")