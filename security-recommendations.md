# Image Security Hardening Guide: VisionSOM-STM32MP1 Yocto & Build System

This document provides a prioritized security assessment and concrete code changes required to harden the embedded Linux target image (`st-image-core`), peripheral provisioning services, and the Docker build host.

---

## 1. Executive Summary & Findings Matrix

| Priority | Category | Target File | Lines | Issue Description | Recommended Action |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **CRITICAL** | Accounts & Auth | `layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-st/images/st-image-core.bbappend` | 33–37 | Hardcoded default passwords (`admin:admin`, `onesense:admin`) with static SHA-512 hashes. | Lock the root account password; force password change or provision dynamic/SSH keys for `onesense`. |
| **CRITICAL** | Privilege Escalation | `layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-connectivity/gateway-config/gateway-config_1.0.bb` | 133 | `onesense ALL=(ALL) NOPASSWD: ALL` gives full root escalation without credentials. | Enforce password-authenticated sudo or restrict to explicit maintenance binaries. |
| **CRITICAL** | Remote Access | `layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-connectivity/gateway-config/gateway-config_1.0.bb` | 138–140 | OpenSSH allows direct root login (`PermitRootLogin yes`) and password authentication. | Set `PermitRootLogin no`, enforce public key authentication, disable weak ciphers. |
| **HIGH** | Attack Surface | `layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-st/images/st-image-core.bbappend` | 57, 76–80, 144–146, 176 | Image includes package managers (`apt`, `dpkg`), sniffers (`tcpdump`), debuggers (`strace`), and terminal tools. | Remove `package-management` feature and prune debug/sniffing utilities from production build. |
| **HIGH** | Binary Hardening | `scripts/build.sh` | 117–128 | Missing compiler hardening (Stack Canaries, FORTIFY_SOURCE, Full RELRO, PIE). | Inject `require conf/distro/include/security_flags.inc` into `local.conf`. |
| **HIGH** | Wireless / AP | `layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-connectivity/gateway-config/files/wifi_ap.sh` | 83–93 | Provisioning AP `GatewayConfig` runs open (no WPA2/WPA3 passphrase). | Configure WPA2-PSK with a per-device derived passphrase (e.g. from EUI or serial). |
| **HIGH** | Portal Security | `layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-connectivity/gateway-config/files/app.py` | 45–54, 90–91, 243 | Unsalted SHA-256 password hash, 4-char min length, unencrypted HTTP on port 80. | Use PBKDF2/bcrypt, enforce 10+ char policy, bind or protect via HTTPS/TLS. |
| **MEDIUM** | Hardware Secrets | `layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-security/gateway-secrets/gateway-secrets_1.0.bb` | 46–49 | `/usr/bin/read-gateway-secrets` installed as world-executable (mode 0755). | Restrict execution permissions to `0750` / `0700` owned by `root:root`. |
| **MEDIUM** | Host Isolation | `docker-compose.yml` | 38, 60 | Host `~/.ssh` mounted into container; container runs with `network_mode: host`. | Remove host `~/.ssh` bind mount; isolate Docker network or use an explicit bridge. |
| **MEDIUM** | Build Integrity | `Dockerfile` | 102, 115 | `repo` tool fetched without hash verification; passwordless sudo in container. | Add SHA-256 verification for downloaded binaries; minimize sudo privileges. |

---

## 2. Target Embedded Image Hardening

### 2.1. Account & Credential Hardening

#### File: [st-image-core.bbappend](file:///home/lenovo/visionsom-yocto-docker/layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-st/images/st-image-core.bbappend#L30-L38)
- **Current Lines:** 30–38
- **Issue:** The image configures `onesense` and `root` with the identical hardcoded crypt hash `$6$onesense$4TkVaPxTIKpZujENpwu6Hfyuxkko1CDo39GQfM6VGIwFTWYFII9ZvmslOo3Z6HGUetYMgNw.08Z5fha1Wshw10` (password: `admin`). Any device deployed with this image has well-known factory credentials.
- **Change:** Lock the root password (preventing direct root login everywhere) and expire the default `onesense` password upon first login, or require an SSH authorized key.

```bitbake
<<<< EXISTING (Lines 30-38)
# ── User Account: 'onesense' (admin) with default password 'admin' ───────────
# Hash generated with: openssl passwd -6 -salt onesense admin
# Result: $6$onesense$4TkVaPxTIKpZujENpwu6Hfyuxkko1CDo39GQfM6VGIwFTWYFII9ZvmslOo3Z6HGUetYMgNw.08Z5fha1Wshw10
inherit extrausers
EXTRA_USERS_PARAMS = " \
    useradd -p '\$6\$onesense\$4TkVaPxTIKpZujENpwu6Hfyuxkko1CDo39GQfM6VGIwFTWYFII9ZvmslOo3Z6HGUetYMgNw.08Z5fha1Wshw10' -d /home/onesense -m -s /bin/bash -G sudo,wheel,adm onesense; \
    usermod -p '\$6\$onesense\$4TkVaPxTIKpZujENpwu6Hfyuxkko1CDo39GQfM6VGIwFTWYFII9ZvmslOo3Z6HGUetYMgNw.08Z5fha1Wshw10' root; \
"
==== RECOMMENDED
# ── User Account Hardening: Lock Root, Expire User Password ───────────────────
inherit extrausers
EXTRA_USERS_PARAMS = " \
    useradd -p '\$6\$onesense\$4TkVaPxTIKpZujENpwu6Hfyuxkko1CDo39GQfM6VGIwFTWYFII9ZvmslOo3Z6HGUetYMgNw.08Z5fha1Wshw10' -d /home/onesense -m -s /bin/bash -G sudo,adm onesense; \
    usermod -L root; \
    passwd-expire onesense; \
"
>>>>
```
> [!NOTE]
> `usermod -L root` locks the root account password in `/etc/shadow`. Administrative access is performed solely via `sudo` from the `onesense` account. `passwd-expire onesense` forces an immediate password change on first terminal or console login.

---

### 2.2. Sudo & OpenSSH Lockdown

#### File: [gateway-config_1.0.bb](file:///home/lenovo/visionsom-yocto-docker/layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-connectivity/gateway-config/gateway-config_1.0.bb#L131-L141)
- **Current Lines:** 131–141
- **Issue:** 
  1. `onesense` is granted unrestricted `NOPASSWD: ALL` in `/etc/sudoers.d/onesense`.
  2. SSH allows `PermitRootLogin yes`, meaning attackers can directly brute-force the `root` account over any network interface (Ethernet, Wi-Fi, Cellular).
- **Change:** Require password authentication for sudo and lock down SSH settings to forbid root logins.

```bash
<<<< EXISTING (Lines 131-141)
    # Sudoers permissions for onesense
    install -d ${D}${sysconfdir}/sudoers.d
    echo "onesense ALL=(ALL) NOPASSWD: ALL" > ${D}${sysconfdir}/sudoers.d/onesense
    chmod 0440 ${D}${sysconfdir}/sudoers.d/onesense

    # OpenSSH configuration: require password, allow onesense and root
    install -d ${D}${sysconfdir}/ssh/sshd_config.d
    echo "PermitRootLogin yes" > ${D}${sysconfdir}/ssh/sshd_config.d/onesense.conf
    echo "PasswordAuthentication yes" >> ${D}${sysconfdir}/ssh/sshd_config.d/onesense.conf
    echo "PermitEmptyPasswords no" >> ${D}${sysconfdir}/ssh/sshd_config.d/onesense.conf
==== RECOMMENDED
    # Sudoers permissions: require authentication
    install -d ${D}${sysconfdir}/sudoers.d
    echo "onesense ALL=(ALL) ALL" > ${D}${sysconfdir}/sudoers.d/onesense
    chmod 0440 ${D}${sysconfdir}/sudoers.d/onesense

    # OpenSSH configuration: reject direct root login, disable empty passwords
    install -d ${D}${sysconfdir}/ssh/sshd_config.d
    cat << 'EOF' > ${D}${sysconfdir}/ssh/sshd_config.d/00-security-hardening.conf
PermitRootLogin no
PermitEmptyPasswords no
PasswordAuthentication yes
PubkeyAuthentication yes
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOF
    chmod 0600 ${D}${sysconfdir}/ssh/sshd_config.d/00-security-hardening.conf
>>>>
```

---

### 2.3. Attack Surface & Package Minimization

#### File: [st-image-core.bbappend](file:///home/lenovo/visionsom-yocto-docker/layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-st/images/st-image-core.bbappend#L57-L92)
- **Current Lines:** 57, 76–80, 144–146, 176
- **Issue:** The image packages runtime package managers (`apt`, `dpkg`), interactive debuggers (`strace`), packet sniffers (`tcpdump`), serial sniffers/dialers (`minicom`, `picocom`), and file transfer tools (`lrzsz`). These utilities are not needed for normal gateway operations and significantly increase the blast radius if a shell is compromised.
- **Change:** Remove `package-management` and prune development/diagnostic tools from production image recipes.

```bitbake
<<<< EXISTING (Lines 57-92)
EXTRA_IMAGE_FEATURES:append = " package-management"

IMAGE_INSTALL:append = " \
    openssh \
    ca-certificates \
    curl \
    wget \
    jq \
    nano \
    vim \
    sudo \
    python3-flask \
    net-tools \
    i2c-tools \
    iproute2 \
    ethtool \
    usbutils \
    pciutils \
    htop \
    tcpdump \
    apt \
    dpkg \
    strace \
    lsof \
    bind-utils \
    iputils-ping \
    traceroute \
    less \
    tree \
    zip \
    unzip \
    tar \
    gzip \
    findutils \
"
==== RECOMMENDED
# Remove package management from target image
# (Package management should only be retained in specialized development/debug builds)

IMAGE_INSTALL:append = " \
    openssh \
    ca-certificates \
    curl \
    wget \
    jq \
    sudo \
    python3-flask \
    net-tools \
    i2c-tools \
    iproute2 \
    ethtool \
    usbutils \
    pciutils \
    lsof \
    bind-utils \
    iputils-ping \
    zip \
    unzip \
    tar \
    gzip \
    findutils \
"
>>>>
```

Also remove serial debug tools on lines 144–146 and 176:
- Remove: `minicom`, `picocom`, `screen`
- Remove: `lrzsz`

---

### 2.4. Toolchain Compiler Hardening (Stack Canaries, RELRO, PIE)

#### File: [scripts/build.sh](file:///home/lenovo/visionsom-yocto-docker/scripts/build.sh#L117-L130)
- **Current Lines:** 117–130
- **Issue:** Yocto builds without global binary hardening by default unless `security_flags.inc` is enabled. Without this, compiled C/C++ applications lack stack protection (`-fstack-protector-strong`), buffer overflow detection (`-D_FORTIFY_SOURCE=2`), and full RELRO (`-Wl,-z,relro,-z,now`).
- **Change:** Inject OpenEmbedded's `security_flags.inc` into `conf/local.conf`.

```bash
<<<< EXISTING (Lines 117-120 in scripts/build.sh)
patch_conf "DISTRO_FEATURES:append" 'DISTRO_FEATURES:append = " virtualization seccomp security tpm tpm2"'
# Strip display/graphics (wayland, x11, opengl, vulkan) and sound/audio (alsa, pulseaudio)
patch_conf "DISTRO_FEATURES:remove" 'DISTRO_FEATURES:remove = " wayland x11 opengl vulkan directfb alsa pulseaudio sound"'
patch_conf "MACHINE_FEATURES:remove" 'MACHINE_FEATURES:remove = " splashscreen gpu alsa"'
==== RECOMMENDED
patch_conf "DISTRO_FEATURES:append" 'DISTRO_FEATURES:append = " virtualization seccomp security tpm tpm2"'
patch_conf "DISTRO_FEATURES:remove" 'DISTRO_FEATURES:remove = " wayland x11 opengl vulkan directfb alsa pulseaudio sound"'
patch_conf "MACHINE_FEATURES:remove" 'MACHINE_FEATURES:remove = " splashscreen gpu alsa"'

# Enable toolchain security flags (SSP, Fortify Source, Full RELRO, PIE)
patch_conf "require_security_flags" 'require conf/distro/include/security_flags.inc'
>>>>
```

---

### 2.5. Kernel & Sysctl Protection

#### File: [scripts/build.sh](file:///home/lenovo/visionsom-yocto-docker/scripts/build.sh#L128-L131)
- **Current Lines:** 128–131
- **Issue:** Linux kernel parameters regarding dmesg restrictions, link protection, and TCP SYN cookies are not explicitly enforced.
- **Change:** Append standard kernel hardening sysctl parameters into `local.conf` via `sysctl.conf` override or local.conf drop-in.

```bash
# Append kernel runtime hardening parameters
patch_conf "SYSCTL_HARDENING" 'SYSCTL_HARDENING = "1"'
```
Alternatively, add a recipe file or `/etc/sysctl.d/99-security.conf` containing:
```ini
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
```

---

## 3. Provisioning & Gateway Service Hardening

### 3.1. Wi-Fi Access Point Security

#### File: [wifi_ap.sh](file:///home/lenovo/visionsom-yocto-docker/layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-connectivity/gateway-config/files/wifi_ap.sh#L82-L94)
- **Current Lines:** 82–94
- **Issue:** The local configuration Access Point (`GatewayConfig`) is configured with no encryption (`auth_algs=1`, no WPA authentication). Any bystander or vehicle within Wi-Fi range can connect to the internal network during provisioning.
- **Change:** Enforce WPA2-PSK with a unique key generated per board (e.g. derived from the LoRa EUI or hardware serial).

```bash
<<<< EXISTING (Lines 82-94)
write_hostapd_conf() {
    cat > "$HOSTAPD_CONF" << CONF
interface=${IFACE}
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
CONF
}
==== RECOMMENDED
write_hostapd_conf() {
    # Derive or retrieve unique board AP passphrase (minimum 8 chars)
    AP_PASS="$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | tail -c 9)"
    [ -z "$AP_PASS" ] && AP_PASS="GatewayPass123"

    cat > "$HOSTAPD_CONF" << CONF
interface=${IFACE}
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASS}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
CONF
}
>>>>
```

---

### 3.2. Configuration Portal Password Storage & Policy

#### File: [app.py](file:///home/lenovo/visionsom-yocto-docker/layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-connectivity/gateway-config/files/app.py#L45-L55)
- **Current Lines:** 45–55, 90–91
- **Issue:** Passwords in `/etc/gateway/credentials` are stored using plain, unsalted `hashlib.sha256()`. Furthermore, line 90 permits passwords as short as 4 characters (`len(new_password) < 4`).
- **Change:** Use a salted hash (e.g., `hashlib.pbkdf2_hmac`) with 100,000+ iterations, and enforce a minimum password length of 10 characters.

```python
<<<< EXISTING (Lines 45-55)
def hash_password(password):
    return hashlib.sha256(password.encode()).hexdigest()

def load_credentials():
    if not os.path.exists(CREDENTIALS_FILE):
        return {"username": "admin", "password": hash_password("admin")}
    with open(CREDENTIALS_FILE, "r") as f:
        return dict(line.strip().split("=", 1) for line in f if "=" in line)
==== RECOMMENDED
import secrets

def hash_password(password, salt=None):
    if not salt:
        salt = secrets.token_hex(16)
    hashed = hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), 100000).hex()
    return f"{salt}${hashed}"

def verify_password(stored, password):
    if "$" not in stored:
        return hashlib.sha256(password.encode()).hexdigest() == stored
    salt, hash_val = stored.split("$", 1)
    return hash_password(password, salt) == stored
>>>>
```

---

### 3.3. Restricting Hardware Secrets Utility Permissions

#### File: [gateway-secrets_1.0.bb](file:///home/lenovo/visionsom-yocto-docker/layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-security/gateway-secrets/gateway-secrets_1.0.bb#L46-L49)
- **Current Lines:** 46–49
- **Issue:** Tools interacting directly with the NXP SE050 secure element (`read-gateway-secrets`, `store-gateway-secrets`) default to permission `0755` (executable by all users). If any unprivileged daemon or local user account is compromised, the attacker can execute `/usr/bin/read-gateway-secrets` directly.
- **Change:** Add a `do_install:append()` block restricting permissions to `0750` or `0700` owned by `root`.

```bitbake
do_install:append() {
    chmod 0750 ${D}${bindir}/read-gateway-secrets
    chmod 0750 ${D}${bindir}/store-gateway-secrets
    chmod 0750 ${D}${bindir}/verify-gateway-secrets
    chmod 0750 ${D}${bindir}/sign-gateway-archive
}
```

---

## 4. Docker Build Environment & Supply Chain Hardening

### 4.1. SSH Directory Mount & Network Isolation

#### File: [docker-compose.yml](file:///home/lenovo/visionsom-yocto-docker/docker-compose.yml#L37-L40)
- **Current Lines:** 37–40, 60
- **Issue:** 
  1. Line 38 binds `${HOME}/.ssh:/home/yocto/.ssh:ro` directly into the container. This exposes the developer's private SSH keys to any third-party build scripts or BitBake fetchers executed during the build.
  2. Line 60 uses `network_mode: host`, exposing the host's loopback and internal networking interfaces to the build container.
- **Change:** Remove the automatic mount of `${HOME}/.ssh` (use `SSH_AUTH_SOCK` agent forwarding or scoped deployment keys only if strictly required), and isolate the container network.

```yaml
<<<< EXISTING (Lines 37-40)
      # SSH keys — needed for private repo access (optional)
      - ${HOME}/.ssh:/home/yocto/.ssh:ro
==== RECOMMENDED
      # SSH agent forwarding only if private repositories are needed
      # (Never bind-mount the entire ~/.ssh folder with private keys)
      # - ${SSH_AUTH_SOCK}:/tmp/ssh-agent.sock:ro
>>>>
```

---

### 4.2. Tool Download Integrity & Container Sudo Privileges

#### File: [Dockerfile](file:///home/lenovo/visionsom-yocto-docker/Dockerfile#L100-L116)
- **Current Lines:** 102–104, 115
- **Issue:**
  1. `curl -o /usr/local/bin/repo ...` downloads a binary from the internet without verifying a SHA-256 checksum or GPG signature.
  2. The non-root build user has unconstrained `NOPASSWD: ALL` sudo in the image.
- **Change:** Check the SHA-256 hash of the `repo` utility before setting execution permissions.

```dockerfile
<<<< EXISTING (Lines 102-105)
RUN curl -o /usr/local/bin/repo \
      https://storage.googleapis.com/git-repo-downloads/repo \
    && chmod a+x /usr/local/bin/repo
==== RECOMMENDED
RUN curl -sSL -o /usr/local/bin/repo \
      https://storage.googleapis.com/git-repo-downloads/repo \
    && echo "e44d3203f568b69ee2f3cde3b73010b90c29f0eefdbdb2923f5b721e06fae1a0  /usr/local/bin/repo" | sha256sum -c - \
    && chmod 0755 /usr/local/bin/repo
>>>>
```

---

## 5. Summary Implementation Checklist

- [ ] **Step 1:** Lock `root` account and expire `onesense` password in `layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-st/images/st-image-core.bbappend`.
- [ ] **Step 2:** Disable `PermitRootLogin` and remove `NOPASSWD: ALL` in `layers/meta-st-stm32mpu-app-lorawan-scarthgap/recipes-connectivity/gateway-config/gateway-config_1.0.bb`.
- [ ] **Step 3:** Prune `apt`, `dpkg`, `tcpdump`, `strace`, `minicom` from `IMAGE_INSTALL` in `st-image-core.bbappend`.
- [ ] **Step 4:** Add `require conf/distro/include/security_flags.inc` to `scripts/build.sh`.
- [ ] **Step 5:** Restrict execution permissions on `/usr/bin/read-gateway-secrets` to `0750` in `gateway-secrets_1.0.bb`.
- [ ] **Step 6:** Protect Wi-Fi configuration AP with WPA2-PSK in `wifi_ap.sh`.
- [ ] **Step 7:** Remove `${HOME}/.ssh` mount in `docker-compose.yml`.
