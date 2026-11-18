#!/bin/sh
# /usr/local/bin/apply_gateway_config.sh
# Applies Azure IoT Edge and TTN LoRaWAN configurations retrieved from the HSM

CONFIG_DIR="/etc/gateway"
AZURE_CONFIG="/etc/aziot/config.toml"
BASICSTATION_CONF="/etc/basicstation/station.conf"

# Parse arguments
NO_RESTART=0
for arg in "$@"; do
    if [ "$arg" = "--no-restart" ]; then
        NO_RESTART=1
    fi
done

# Read non-sensitive settings
LOG_LEVEL=$(cat "$CONFIG_DIR/log_level" 2>/dev/null || echo "INFO")
REGION_PROFILE=$(cat "$CONFIG_DIR/region_profile" 2>/dev/null || echo "US915")
NETWORK_SERVER=$(cat "$CONFIG_DIR/network_server" 2>/dev/null || echo "")
AZURE_HOSTNAME=$(cat "$CONFIG_DIR/azure_hostname" 2>/dev/null || cat /app/config/azure_hostname 2>/dev/null)
AZURE_DEVICEID=$(cat "$CONFIG_DIR/azure_device_id" 2>/dev/null || cat /app/config/azure_device_id 2>/dev/null)

# Read secrets from HSM
echo "Reading secrets from HSM..."
SECRETS=$(/usr/bin/read-gateway-secrets /dev/i2c-0 2>/dev/null)
AZURE_CS=$(echo "$SECRETS" | grep "^azure_connection_string:" | cut -d' ' -f2-)
TTN_KEY=$(echo "$SECRETS" | grep "^ttn_api_key:" | cut -d' ' -f2-)
case "$AZURE_CS" in
    NOT\ FOUND*|ERROR*|"") AZURE_CS="" ;;
esac
case "$TTN_KEY" in
    NOT\ FOUND*|ERROR*|"") TTN_KEY="" ;;
    *) [ -n "$TTN_KEY" ] && TTN_KEY=$(echo -n "$TTN_KEY" | base64 -d 2>/dev/null) ;;
esac

# Fallback: if hostname/device_id not in flat files, extract from HSM connection string
if [ -z "$AZURE_HOSTNAME" ] && [ -n "$AZURE_CS" ] && [ "$AZURE_CS" != "NOT FOUND" ]; then
    AZURE_HOSTNAME=$(echo "$AZURE_CS" | sed -n 's/.*HostName=\([^;]*\).*/\1/p')
fi
if [ -z "$AZURE_DEVICEID" ] && [ -n "$AZURE_CS" ] && [ "$AZURE_CS" != "NOT FOUND" ]; then
    AZURE_DEVICEID=$(echo "$AZURE_CS" | sed -n 's/.*DeviceId=\([^;]*\).*/\1/p')
fi

# Dynamically set system hostname to azure_device_id
if [ -n "$AZURE_DEVICEID" ] && [ "$AZURE_DEVICEID" != "NOT FOUND" ] && [ "$AZURE_DEVICEID" != "ERROR"* ]; then
    CURRENT_HN=$(hostname 2>/dev/null)
    if [ "$CURRENT_HN" != "$AZURE_DEVICEID" ]; then
        echo "Updating system hostname to Azure DeviceId: $AZURE_DEVICEID"
        echo "$AZURE_DEVICEID" > /etc/hostname
        hostnamectl set-hostname "$AZURE_DEVICEID" 2>/dev/null || hostname "$AZURE_DEVICEID" 2>/dev/null || true
    fi
fi

# Ensure system hostname and device ID resolve to 127.0.0.1 for host-network IoT Edge modules
for hn in "$(hostname 2>/dev/null)" "$(cat /etc/hostname 2>/dev/null)" "$AZURE_DEVICEID"; do
    if [ -n "$hn" ] && [ "$hn" != "NOT FOUND" ] && [ "$hn" != "ERROR"* ] && ! grep -qw "$hn" /etc/hosts 2>/dev/null; then
        echo "127.0.0.1 $hn" >> /etc/hosts
    fi
done

# Ensure MicroSD storage is mounted to /mnt/sdcard_logs for loggingmodule
setup_sdcard_logs() {
    local sd_raw="/dev/mmcblk1"
    local sd_part="/dev/mmcblk1p1"
    local mount_point="/mnt/sdcard_logs"

    if [ ! -b "$sd_raw" ]; then
        return 0
    fi

    if [ ! -b "$sd_part" ]; then
        printf 'o\nn\np\n1\n\n\nw\n' | fdisk "$sd_raw" >/dev/null 2>&1 || true
        partprobe "$sd_raw" >/dev/null 2>&1 || true
        sleep 1
        [ ! -b "$sd_part" ] && sd_part="$sd_raw"
    fi

    local fs_type
    fs_type=$(blkid -o value -s TYPE "$sd_part" 2>/dev/null)
    if [ -z "$fs_type" ] || { [ "$fs_type" != "vfat" ] && [ "$fs_type" != "fat" ]; }; then
        if command -v mkfs.vfat >/dev/null 2>&1; then
            mkfs.vfat -F 32 -n "SDCARD_LOGS" "$sd_part" >/dev/null 2>&1
        elif which mkfs.vfat >/dev/null 2>&1; then
            mkfs.vfat -F 32 -n "SDCARD_LOGS" "$sd_part" >/dev/null 2>&1
        else
            mkfs.ext4 -F -L "SDCARD_LOGS" "$sd_part" >/dev/null 2>&1
        fi
        fs_type=$(blkid -o value -s TYPE "$sd_part" 2>/dev/null)
    fi

    mkdir -p "$mount_point"

    local fstab_entry=""
    local mount_opts=""
    if [ "$fs_type" = "vfat" ] || [ "$fs_type" = "fat" ]; then
        fstab_entry="$sd_part $mount_point vfat defaults,noatime,flush,uid=0,gid=0,umask=022,utf8,nofail 0 2"
        mount_opts="-t vfat -o noatime,flush,uid=0,gid=0,umask=022,utf8"
    else
        fstab_entry="$sd_part $mount_point ext4 defaults,noatime,nofail 0 2"
        mount_opts="-t ext4 -o defaults,noatime"
    fi

    if ! grep -q "$mount_point" /etc/fstab 2>/dev/null; then
        echo "$fstab_entry" >> /etc/fstab
    elif ! grep -q "$sd_part.*$mount_point.*$fs_type" /etc/fstab 2>/dev/null; then
        sed -i "\|$mount_point|d" /etc/fstab
        echo "$fstab_entry" >> /etc/fstab
    fi

    if ! mountpoint -q "$mount_point"; then
        mount $mount_opts "$sd_part" "$mount_point" >/dev/null 2>&1 || mount "$mount_point" >/dev/null 2>&1
    fi
}
setup_sdcard_logs

# 1. Apply Azure IoT Edge Provisioning
if [ -n "$AZURE_HOSTNAME" ] && [ -n "$AZURE_DEVICEID" ]; then
    echo "Configuring Azure IoT Edge for DeviceId: $AZURE_DEVICEID, HostName: $AZURE_HOSTNAME..."

    # AZURE_CS from read-gateway-secrets is now the raw binary SAS key (base64 encoded for stdout)
    AZURE_SAS_KEY_B64=""
    if [ -n "$AZURE_CS" ] && [ "$AZURE_CS" != "NOT FOUND" ] && [ "$AZURE_CS" != "ERROR"* ]; then
        AZURE_SAS_KEY_B64="$AZURE_CS"
    fi

    # Fallback for manual plaintext provisioning (e.g., initial BLE setup before HSM store)
    if [ -z "$AZURE_SAS_KEY_B64" ]; then
        for cs_file in "$CONFIG_DIR/azure_connection_string" "$CONFIG_DIR/connection_string" "/app/config/connection_string"; do
            if [ -f "$cs_file" ]; then
                AZURE_SAS_KEY=$(cat "$cs_file" | sed -n 's/.*SharedAccessKey=\([^;]*\).*/\1/p')
                # If found on disk, we have the raw string, but we want to put it in tmpfs anyway
                [ -n "$AZURE_SAS_KEY" ] && AZURE_SAS_KEY_B64=$(echo -n "$AZURE_SAS_KEY" | base64) && break
            fi
        done
    fi

    # Normalize base64 if key came from legacy HSM read-gateway-secrets (ending with AA instead of A=, or missing =)
    if [ -n "$AZURE_SAS_KEY_B64" ]; then
        case "$AZURE_SAS_KEY_B64" in
            *AA)
                if [ ${#AZURE_SAS_KEY_B64} -eq 44 ]; then
                    AZURE_SAS_KEY_B64="${AZURE_SAS_KEY_B64%AA}A="
                fi
                ;;
        esac
        rem=$((${#AZURE_SAS_KEY_B64} % 4))
        if [ "$rem" -eq 2 ]; then
            AZURE_SAS_KEY_B64="${AZURE_SAS_KEY_B64}=="
        elif [ "$rem" -eq 3 ]; then
            AZURE_SAS_KEY_B64="${AZURE_SAS_KEY_B64}="
        fi
    fi

    if [ -z "$AZURE_SAS_KEY_B64" ]; then
        echo "WARNING: Could not extract SharedAccessKey from HSM. Azure IoT Edge will not be configured." >&2
    else
        # Setup tmpfs RAM disk for modules that strictly require connection string in file (like loggingmodule)
        mkdir -p /run/gateway_secrets
        if ! mountpoint -q /run/gateway_secrets; then
            mount -t tmpfs -o size=1M,mode=0755 tmpfs /run/gateway_secrets
        else
            chmod 755 /run/gateway_secrets
        fi
        
        # Read the entire output line by line
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                echo "$line" >> /run/gateway_secrets/raw_secrets
            fi
        done <<EOF
$SECRETS
EOF

        # Write the human-readable connection string to a secure tmpfs file
        echo "HostName=${AZURE_HOSTNAME};DeviceId=${AZURE_DEVICEID};SharedAccessKey=$AZURE_SAS_KEY_B64" > /run/gateway_secrets/azure_connection_string
        chmod 600 /run/gateway_secrets/azure_connection_string

        # Write raw SAS key file for Azure IoT Edge SAS provisioning
        echo -n "$AZURE_SAS_KEY_B64" | base64 -d > /run/gateway_secrets/azure_sas_key
        chmod 644 /run/gateway_secrets/azure_sas_key

        # Check if Azure IoT Edge is already configured with this EXACT connection string
        AZURE_HASH=$(printf "%s|%s|%s" "$AZURE_HOSTNAME" "$AZURE_DEVICEID" "$AZURE_SAS_KEY_B64" | sha256sum | cut -d' ' -f1)
        LAST_AZURE_HASH_FILE="$CONFIG_DIR/.last_azure_hash"
        LAST_AZURE_HASH=""
        [ -f "$LAST_AZURE_HASH_FILE" ] && LAST_AZURE_HASH=$(cat "$LAST_AZURE_HASH_FILE" 2>/dev/null)

        AZURE_ALREADY_CONFIGURED=0
        if [ -n "$LAST_AZURE_HASH" ] && [ "$AZURE_HASH" = "$LAST_AZURE_HASH" ] && [ -e "/etc/aziot/config.toml" ]; then
            AZURE_ALREADY_CONFIGURED=1
        fi

        if [ "$AZURE_ALREADY_CONFIGURED" -eq 1 ]; then
            echo "Azure connection string is unchanged and IoT Edge is already configured. Preserving existing running modules (no download/restart needed)."
            mkdir -p /var/secrets/aziot/keyd
            ln -sf /run/gateway_secrets/azure_sas_key /var/secrets/aziot/keyd/device-id
            chown -h aziotks:aziotks /var/secrets/aziot/keyd/device-id
        else
            # Azure IoT Edge does not support file:/// URIs for symmetric keys.
            # To maintain Zero-Plaintext, we generate the entire config.toml in the RAM disk
            # with the inline value, and symlink it to /etc/aziot/.
            # We also symlink the keyd device-id file to intercept the plaintext key generation
            # without destroying the persistent master encryption key in the keyd folder.
            AZURE_CONFIG="/etc/aziot/config.toml"
            RAM_CONFIG="/run/gateway_secrets/config.toml"
            
            # Ensure the keyd secrets directory exists
            mkdir -p /var/secrets/aziot/keyd
            chown aziotks:aziotks /var/secrets/aziot/keyd
            
            # Symlink the device-id key to RAM so iotedge config apply writes it to tmpfs
            ln -sf /run/gateway_secrets/azure_sas_key /var/secrets/aziot/keyd/device-id
            chown -h aziotks:aziotks /var/secrets/aziot/keyd/device-id

            cat <<EOF > "$RAM_CONFIG"
hostname = "$(hostname)"

[agent]
name = "edgeAgent"
type = "docker"

[agent.config]
image = "mcr.microsoft.com/azureiotedge-agent:1.5"

[agent.env]
UpstreamProtocol = "AmqpWs"
AmqpTransportSettings__KeepAliveInMilliseconds = "60000"

[provisioning]
source = "manual"
iothub_hostname = "$AZURE_HOSTNAME"
device_id = "$AZURE_DEVICEID"

[provisioning.authentication]
method = "sas"
device_id_pk = { value = "$AZURE_SAS_KEY_B64" }
EOF
            chmod 600 "$RAM_CONFIG"
            
            # Symlink the RAM disk config to /etc/aziot/
            ln -sf "$RAM_CONFIG" "$AZURE_CONFIG"

            # Apply config and restart IoT Edge services
            # Wait for Docker to be ready (iotedge config apply needs it)
            echo "Waiting for Docker daemon..."
            DOCKER_RETRIES=0
            while ! docker info >/dev/null 2>&1; do
                DOCKER_RETRIES=$((DOCKER_RETRIES + 1))
                if [ "$DOCKER_RETRIES" -ge 60 ]; then
                    echo "WARNING: Docker not ready after 60s, proceeding anyway..."
                    break
                fi
                sleep 1
            done
            echo "Docker ready after ${DOCKER_RETRIES}s."

            echo "Running iotedge config apply..."
            APPLY_OK=0
            if command -v iotedge >/dev/null 2>&1; then
                APPLY_OUTPUT=$(iotedge config apply 2>&1)
                APPLY_STATUS=$?
                echo "$APPLY_OUTPUT"
                if [ $APPLY_STATUS -eq 0 ]; then
                    APPLY_OK=1
                elif echo "$APPLY_OUTPUT" | grep -q "different from the previous hostname"; then
                    echo "Hostname changed in IoT Edge config; cleaning old modules and reapplying..."
                    iotedge system stop 2>/dev/null || true
                    docker rm -f $(docker ps -aq -f "label=net.azure-devices.edge.owner=Microsoft.Azure.Devices.Edge.Agent") 2>/dev/null || true
                    if iotedge config apply 2>&1; then
                        APPLY_OK=1
                    fi
                else
                    echo "WARNING: iotedge config apply failed, will retry on next boot."
                fi
            elif command -v aziotctl >/dev/null 2>&1; then
                if aziotctl config apply 2>&1; then
                    APPLY_OK=1
                fi
            fi

            # Record hash on success so future boots / configs with identical string don't re-apply
            if [ "$APPLY_OK" -eq 1 ]; then
                echo "$AZURE_HASH" > "$LAST_AZURE_HASH_FILE"
                chmod 600 "$LAST_AZURE_HASH_FILE"
            fi

            # CRITICAL ZERO-PLAINTEXT ENFORCEMENT
            # After iotedge config apply has consumed the SAS key from config.toml and
            # written the derived key to /var/secrets/aziot/keyd/device-id, we must:
            #   1. Rewrite config.toml in RAM to strip the SAS key completely
            #   2. Shred any persistent key file that iotedge wrote to eMMC
            #   3. Re-establish the device-id symlink to point to RAM

            # Step 1: Rewrite config.toml in RAM WITHOUT the SAS key
            # Azure IoT Edge never re-reads config.toml after config apply — the running
            # services use the derived key at /var/secrets/aziot/keyd/device-id
            cat <<REDACTED > "$RAM_CONFIG"
hostname = "$(hostname)"

[agent]
name = "edgeAgent"
type = "docker"

[agent.config]
image = "mcr.microsoft.com/azureiotedge-agent:1.5"

[agent.env]
UpstreamProtocol = "AmqpWs"
AmqpTransportSettings__KeepAliveInMilliseconds = "60000"

[provisioning]
source = "manual"
iothub_hostname = "$AZURE_HOSTNAME"
device_id = "$AZURE_DEVICEID"

[provisioning.authentication]
method = "sas"
# SAS key is stored in hardware HSM (SE050E) — never persisted in config files
# device_id_pk = { value = "REDACTED — key exists only in volatile RAM during config apply" }
REDACTED
            chmod 600 "$RAM_CONFIG"

            # Step 2: Re-establish config.toml symlink (iotedge config apply may overwrite it)
            if [ ! -L "$AZURE_CONFIG" ]; then
                rm -f "$AZURE_CONFIG"
                ln -sf "$RAM_CONFIG" "$AZURE_CONFIG"
            fi

            # Step 3: Re-establish device-id key symlink and shred any persistent copy
            if [ -f /var/secrets/aziot/keyd/device-id ] && [ ! -L /var/secrets/aziot/keyd/device-id ]; then
                # Securely destroy the persistent key file that iotedge wrote to eMMC
                dd if=/dev/urandom of=/var/secrets/aziot/keyd/device-id bs=$(stat -c%s /var/secrets/aziot/keyd/device-id 2>/dev/null || echo 64) count=1 2>/dev/null
                sync
                rm -f /var/secrets/aziot/keyd/device-id
            fi
            ln -sf /run/gateway_secrets/azure_sas_key /var/secrets/aziot/keyd/device-id
            chown -h aziotks:aziotks /var/secrets/aziot/keyd/device-id

            if [ "$NO_RESTART" -eq 0 ]; then
                systemctl restart aziot-edged 2>/dev/null || true
            fi
        fi

    fi
fi

# 2. Apply LoRaWAN Basics Station Keys
if [ -n "$TTN_KEY" ] && [ "$TTN_KEY" != "NOT FOUND" ] && [ -n "$NETWORK_SERVER" ]; then
    echo "Configuring LoRaWAN Basics Station..."
    mkdir -p /etc/basicstation

    # Safeguard: Remove any directory artifacts accidentally created by Docker bind-mounts
    for bs_file in "$BASICSTATION_CONF" "/etc/basicstation/tc.key" "/etc/basicstation/tc.uri" "/etc/basicstation/tc.trust"; do
        if [ -d "$bs_file" ]; then
            echo "Removing directory collision created by Docker on $bs_file..."
            rm -rf "$bs_file"
        fi
    done

    # Write LNS WebSocket URI
    echo "wss://${NETWORK_SERVER}:8887" > /etc/basicstation/tc.uri.tmp
    mv /etc/basicstation/tc.uri.tmp /etc/basicstation/tc.uri
    chmod 644 /etc/basicstation/tc.uri

    # --- SECURITY PATCH: Write tc.key to volatile RAM-disk only, never eMMC ---
    SECRETS_DIR="/run/basicstation_secrets"
    mkdir -p "${SECRETS_DIR}"
    chmod 700 "${SECRETS_DIR}"
    echo "Authorization: Bearer ${TTN_KEY}" > "${SECRETS_DIR}/tc.key"
    chmod 600 "${SECRETS_DIR}/tc.key"

    # Symlink the expected path → volatile RAM location (idempotent)
    rm -f /etc/basicstation/tc.key /etc/basicstation/tc.key.tmp
    ln -sf "${SECRETS_DIR}/tc.key" /etc/basicstation/tc.key

    # Link system CA bundle as TLS trust anchor for wss:// connections
    ln -sf /etc/ssl/certs/ca-certificates.crt /etc/basicstation/tc.trust

    # Read concentrator EUI from chip_id (same EUI used for BLE name)
    CHIP_EUI=$(chip_id 2>&1 | grep -i 'concentrator EUI' | grep -oE '[0-9a-fA-F]{16}' | head -1)
    if [ -n "$CHIP_EUI" ]; then
        echo "Concentrator EUI: $CHIP_EUI"
        # Format as colon-separated EUI-64: AABBCCDDEE112233
        ROUTER_ID=$(echo "$CHIP_EUI" | sed 's/../&:/g' | sed 's/:$//')
    else
        echo "WARNING: Could not read chip_id EUI, routerid will be auto-detected"
        ROUTER_ID=""
    fi

    # Generate station.conf with AU915 radio config and hardware EUI as routerid safely using atomic tempfile
    cat > "${BASICSTATION_CONF}.tmp" << EOF
{
    "SX1302_conf": {
        "lorawan_public": true,
        "clksrc": 0,
        "radio_0": {
            "enable": true,
            "type": "SX1250",
            "freq": 916800000,
            "rssi_offset": -215.4,
            "tx_enable": true
        },
        "radio_1": {
            "enable": true,
            "type": "SX1250",
            "freq": 923300000,
            "rssi_offset": -215.4,
            "tx_enable": false
        },
        "chan_multiSF_0": { "enable": true, "radio": 0, "if": -400000 },
        "chan_multiSF_1": { "enable": true, "radio": 0, "if": -200000 },
        "chan_multiSF_2": { "enable": true, "radio": 0, "if": 0 },
        "chan_multiSF_3": { "enable": true, "radio": 0, "if": 200000 },
        "chan_multiSF_4": { "enable": true, "radio": 1, "if": -400000 },
        "chan_multiSF_5": { "enable": true, "radio": 1, "if": -200000 },
        "chan_multiSF_6": { "enable": true, "radio": 1, "if": 0 },
        "chan_multiSF_7": { "enable": true, "radio": 1, "if": 200000 },
        "chan_Lora_std": {
            "enable": true,
            "radio": 1,
            "if": 300000,
            "bandwidth": 500000,
            "spread_factor": 8
        },
        "chan_FSK": { "enable": false }
    },
    "station_conf": {
        $([ -n "$ROUTER_ID" ] && echo "\"routerid\": \"$ROUTER_ID\",")
        "log_level": "DEBUG",
        "log_size": 10000000,
        "log_rotate": 3
    }
}
EOF
    mv "${BASICSTATION_CONF}.tmp" "$BASICSTATION_CONF"
    chmod 600 "$BASICSTATION_CONF"

    if [ "$NO_RESTART" -eq 0 ]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^basicstation$"; then
            echo "Restarting basicstation container with updated keys..."
            docker restart basicstation 2>/dev/null || true
        else
            systemctl restart basicstation 2>/dev/null || true
        fi
    fi
fi

# 3. Securely Clean up cleartext sensitive files from disk
rm -f "$CONFIG_DIR/wifi_password"
# rm -f "$CONFIG_DIR/azure_connection_string"
# rm -f "$CONFIG_DIR/connection_string"
# rm -f /app/config/connection_string
rm -f "$CONFIG_DIR/ttn_api_key"
rm -f "$CONFIG_DIR/api_key"
rm -f "$CONFIG_DIR/halow_password"

echo "Gateway configurations applied successfully!"
