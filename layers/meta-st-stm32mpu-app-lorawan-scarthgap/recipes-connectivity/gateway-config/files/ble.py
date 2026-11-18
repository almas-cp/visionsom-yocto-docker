#!/usr/bin/env python3

import asyncio
import re
import os
import subprocess
import threading
import traceback

from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method, dbus_property
from dbus_next.constants import PropertyAccess

from main import (
    update_wifi_config,
    set_network_priority,
    func_config_gatewayid,
    func_config_azure,
    start_gateway,
    set_log_password,
    store_secrets_to_hsm,
    configure_halow,
    disable_halow,
    is_gateway_configured,
)

SERVICE_UUID = '41d915f3-fc48-4324-a0b9-1244f70fffe6'
CHAR_UUID = '3980b00e-7502-4db9-a061-4e0dfb254008'

BLE_MESSAGE_START = '##'
BLE_MESSAGE_END = '##!'
BLE_STATUS_IDLE = 'idle'
BLE_STATUS_PROCESSING = 'processing'
BLE_STATUS_SUCCESS = 'success'
BLE_STATUS_FAILED = 'failed'

# Keep BLE service alive until configuration succeeds/fails and the app has
# enough time to read the ACK and send "restart".
BLE_IDLE_TIMEOUT_SECONDS = 900  # 15 minutes — allows customers enough time to configure via app
BLE_RESTART_GRACE_SECONDS = 30


def set_led_brightness(led_name, value):
    try:
        path = f"/sys/class/leds/{led_name}/brightness"
        if os.path.exists(path):
            with open(path, 'w') as f:
                f.write(str(value))
    except Exception as e:
        print(f"Failed to set LED {led_name} to {value}: {e}")


async def led_control_loop(bus):
    print("Starting LED control loop (BLE mode: ble-led only, wifi-led OFF)")
    set_led_brightness("wifi-led", 0)
    led_state = False

    try:
        while True:
            connected = False

            try:
                introspect_iface = await bus.introspect('org.bluez', '/')
                proxy_obj = bus.get_proxy_object(
                    'org.bluez', '/', introspect_iface
                )
                obj_manager = proxy_obj.get_interface(
                    'org.freedesktop.DBus.ObjectManager'
                )
                objects = await obj_manager.call_get_managed_objects()

                for path, interfaces in objects.items():
                    if 'org.bluez.Device1' in interfaces:
                        device_props = interfaces['org.bluez.Device1']
                        connected_prop = device_props.get('Connected')

                        if connected_prop:
                            val = getattr(
                                connected_prop,
                                'value',
                                connected_prop
                            )

                            if val is True:
                                connected = True
                                break

            except Exception as e:
                print(f"Error checking BLE connection: {e}")

            set_led_brightness("wifi-led", 0)
            if connected:
                # Mobile app connected: SOLID ON
                set_led_brightness("ble-led", 1)
                await asyncio.sleep(0.5)
            else:
                # Waiting for connection: BLINK (0.5s ON, 0.5s OFF)
                led_state = not led_state
                set_led_brightness("ble-led", 1 if led_state else 0)
                await asyncio.sleep(0.5)

    except asyncio.CancelledError:
        print("LED control loop cancelled")

    finally:
        set_led_brightness("ble-led", 0)
        set_led_brightness("wifi-led", 0)


class GattCharacteristic(ServiceInterface):
    def __init__(self, path, service_path, config_done_event):
        super().__init__('org.bluez.GattCharacteristic1')

        self.path = path
        self.service_path = service_path

        self.notifying = False

        # Current ACK/status exposed through ReadValue()
        self._config_status = BLE_STATUS_IDLE

        # Accumulates fragmented BLE writes until ##...##! is complete.
        self._receive_buffer = ""

        # Event used by main() so the BLE service stays alive.
        self._config_done = config_done_event

        # Prevent multiple provisioning threads at the same time.
        self._processing_lock = threading.Lock()

        # Used when the mobile application sends "restart".
        self._restart_triggered = False

        # Signals that background provisioning tasks have finished.
        self._config_tasks_completed = threading.Event()

    def _set_status(self, status):
        self._config_status = status
        print(f"BLE status -> {status}")

        # Notify if a client is subscribed.
        if self.notifying:
            try:
                self.emit_properties_changed(
                    {'Value': self._config_status.encode('utf-8')}
                )
                print(f"BLE notification sent -> {status}")
            except Exception as e:
                print(f"Failed to send BLE notification: {e}")

    @method()
    async def ReadValue(self, options: 'a{sv}') -> 'ay':
        value = self._config_status.encode('utf-8')
        print(
            f"ReadValue called -> status={self._config_status}, "
            f"length={len(value)}"
        )
        return value

    @method()
    async def WriteValue(self, value: 'ay', options: 'a{sv}'):

        try:
            chunk = bytes(value)
            received_data = chunk.decode('utf-8', errors='ignore')

            print(
                f"WriteValue called: chunk_len={len(chunk)} "
                f"data={received_data!r}"
            )

            # ---------------------------------------------------------
            # RESTART COMMAND
            # ---------------------------------------------------------
            if received_data.strip().lower() == "restart":
                print("Restart command received over BLE")

                self._restart_triggered = True

                if self._config_status == BLE_STATUS_SUCCESS:
                    print("Restart command received. Waiting for background configuration tasks to finish...")
                    
                    def wait_and_restart():
                        # Wait up to 60 seconds for provisioning to finish
                        self._config_tasks_completed.wait(timeout=60.0)
                        print("Configuration tasks finished. Starting gateway...")
                        try:
                            start_gateway()
                        except Exception as e:
                            print(f"start_gateway() failed: {e}")

                    threading.Thread(target=wait_and_restart, daemon=True).start()
                else:
                    print(
                        f"Restart ignored because config status is "
                        f"{self._config_status}"
                    )

                return

            # ---------------------------------------------------------
            # BUFFER BLE CHUNKS
            # ---------------------------------------------------------
            self._receive_buffer += received_data

            if len(self._receive_buffer) > 4096:
                print("BLE receive buffer exceeded 4KB limit. Flushing buffer to prevent memory exhaustion.")
                self._receive_buffer = ""
                return

            print(
                f"BLE receive buffer length="
                f"{len(self._receive_buffer)}"
            )

            # Wait until the complete frame terminator is available.
            if BLE_MESSAGE_END not in self._receive_buffer:
                print("Waiting for more BLE chunks...")
                return

            # Find the first complete frame.
            start_index = self._receive_buffer.find(BLE_MESSAGE_START)
            end_index = self._receive_buffer.find(
                BLE_MESSAGE_END,
                start_index if start_index >= 0 else 0
            )

            if start_index < 0 or end_index < 0:
                print("Invalid BLE frame boundaries; waiting for more data.")
                return

            end_index += len(BLE_MESSAGE_END)

            frame = self._receive_buffer[start_index:end_index]

            # Preserve anything after the first complete frame.
            self._receive_buffer = self._receive_buffer[end_index:]

            print(f"Complete BLE frame received: length={len(frame)}")

            match = re.fullmatch(
                r'##(.*?)##!',
                frame,
                flags=re.DOTALL
            )

            if not match:
                print("Invalid BLE frame format.")
                self._set_status(BLE_STATUS_FAILED)
                self._receive_buffer = ""
                return

            conn_data = match.group(1)
            print(f"Connection data length={len(conn_data)}")

            # ---------------------------------------------------------
            # PREVENT SIMULTANEOUS CONFIGURATION REQUESTS
            # ---------------------------------------------------------
            if not self._processing_lock.acquire(blocking=False):
                print("Configuration already in progress.")
                self._set_status(BLE_STATUS_PROCESSING)
                return

            try:
                self._set_status(BLE_STATUS_PROCESSING)

                # -----------------------------------------------------
                # PARSE CURRENT APP PAYLOAD
                #
                # No HaLow = 9 fields:
                # 1  wifiName
                # 2  wifiPassword
                # 3  loraServer
                # 4  networkPriority
                # 5  regionProfile
                # 6  zipPassword
                # 7  logLevel
                # 8  connectionString
                # 9  ttnApiKey
                #
                # HaLow enabled = 13 fields:
                # 1  wifiName
                # 2  wifiPassword
                # 3  halowSsid
                # 4  halowPassword
                # 5  halowBandwidth
                # 6  halowSecurity
                # 7  loraServer
                # 8  networkPriority
                # 9  regionProfile
                # 10 zipPassword
                # 11 logLevel
                # 12 connectionString
                # 13 ttnApiKey
                # -----------------------------------------------------

                parts = [p.strip() for p in conn_data.split(',')]

                print(f"Parsed field count={len(parts)}")

                halow_password = ""

                if len(parts) == 13:
                    (
                        ssid,
                        password,
                        halow_ssid,
                        halow_password,
                        raw_bw,
                        raw_sec,
                        server_address,
                        net_prio,
                        region_profile,
                        zip_pw,
                        zip_log_level,
                        connection_string,
                        api_key,
                    ) = parts

                    # Example: "4 MHz" -> "4"
                    bw_match = re.search(r'(\d+)', raw_bw)
                    halow_bw = bw_match.group(1) if bw_match else "4"

                    # Normalize security:
                    # WPA3 / SAE -> SAE
                    # NONE / OPEN -> NONE
                    # Everything else -> WPA-PSK
                    raw_sec_u = raw_sec.upper()

                    if "SAE" in raw_sec_u or "WPA3" in raw_sec_u:
                        halow_sec = "SAE"
                    elif "NONE" in raw_sec_u or "OPEN" in raw_sec_u:
                        halow_sec = "NONE"
                    else:
                        halow_sec = "WPA-PSK"

                    print(
                        f"HaLow enabled: ssid={halow_ssid!r}, "
                        f"bandwidth={halow_bw} MHz, "
                        f"security={halow_sec}"
                    )

                    try:
                        configure_halow(
                            halow_ssid,
                            halow_password,
                            halow_bw,
                            halow_sec,
                        )
                    except Exception as e:
                        print(f"configure_halow() failed: {e}")
                        self._set_status(BLE_STATUS_FAILED)
                        return

                elif len(parts) == 9:
                    (
                        ssid,
                        password,
                        server_address,
                        net_prio,
                        region_profile,
                        zip_pw,
                        zip_log_level,
                        connection_string,
                        api_key,
                    ) = parts

                    print(
                        "HaLow disabled: removing previous HaLow "
                        "configuration"
                    )

                    try:
                        disable_halow()
                    except Exception as e:
                        print(f"disable_halow() failed: {e}")
                        self._set_status(BLE_STATUS_FAILED)
                        return

                else:
                    print(
                        f"Unexpected number of BLE fields: {len(parts)}. "
                        f"Expected 9 or 13."
                    )
                    self._set_status(BLE_STATUS_FAILED)
                    return

                # -----------------------------------------------------
                # VALIDATE REQUIRED FIELDS (password is optional for open networks)
                # -----------------------------------------------------
                required_fields = {
                    "ssid": ssid,
                    "server_address": server_address,
                    "net_prio": net_prio,
                    "region_profile": region_profile,
                    "zip_pw": zip_pw,
                    "zip_log_level": zip_log_level,
                    "connection_string": connection_string,
                    "api_key": api_key,
                }

                empty_fields = [
                    name
                    for name, value in required_fields.items()
                    if not value
                ]

                if empty_fields:
                    print(
                        f"Required BLE fields are empty: "
                        f"{empty_fields}"
                    )
                    self._set_status(BLE_STATUS_FAILED)
                    return

                if not password:
                    print("Wi-Fi network configured as OPEN (non-secure, no password provided).")
                else:
                    print("Wi-Fi network configured as SECURED.")

                # -----------------------------------------------------
                # VALIDATE AZURE CONNECTION STRING
                # -----------------------------------------------------
                if not all(
                    token in connection_string
                    for token in (
                        "HostName=",
                        "DeviceId=",
                        "SharedAccessKey=",
                    )
                ):
                    print("Invalid Azure IoT Hub connection string format.")
                    self._set_status(BLE_STATUS_FAILED)
                    return

                # -----------------------------------------------------
                # ACK TO APP
                #
                # The existing app waits ~3 seconds then ReadAsync().
                # Therefore expose "success" now, after payload validation,
                # but perform the slow provisioning actions in background.
                # -----------------------------------------------------
                self._set_status(BLE_STATUS_SUCCESS)
                self._config_done.set()

                print(
                    "BLE payload valid -> status set to success. "
                    "Starting provisioning tasks in background."
                )

                # -----------------------------------------------------
                # BACKGROUND PROVISIONING
                # -----------------------------------------------------
                def delayed_tasks():
                    try:
                        print("Configuration thread started")

                        store_secrets_to_hsm(
                            password,
                            connection_string,
                            api_key,
                            halow_password,
                            zip_pw
                        )

                        
                        set_network_priority(net_prio)

                        set_log_password(
                            zip_pw,
                            zip_log_level
                        )

                        update_wifi_config(
                            ssid,
                            password
                        )

                        func_config_gatewayid(
                            server_address,
                            api_key,
                            region_profile
                        )

                        func_config_azure(
                            connection_string
                        )

                        print(
                            "All background configuration tasks "
                            "completed successfully"
                        )
                        self._config_tasks_completed.set()

                    except Exception as e:
                        print(
                            "Error during background configuration "
                            f"tasks: {e}"
                        )
                        traceback.print_exc()
                        # Allow restart to proceed even if there's an error so the device doesn't hang forever
                        self._config_tasks_completed.set()

                    # Give the application enough time to:
                    # 1. Read "success"
                    # 2. Send "restart"
                    if not self._restart_triggered:
                        print(
                            f"Waiting {BLE_RESTART_GRACE_SECONDS}s "
                            "for restart command..."
                        )

                        for _ in range(BLE_RESTART_GRACE_SECONDS):
                            if self._restart_triggered:
                                break
                            threading.Event().wait(1)

                    # Fallback if application did not send restart.
                    if not self._restart_triggered:
                        print(
                            "Restart command was not received. "
                            "Starting gateway as fallback."
                        )

                        try:
                            start_gateway()
                        except Exception as e:
                            print(
                                f"Fallback start_gateway() failed: {e}"
                            )
                    else:
                        print(
                            "Restart command already received. "
                            "No fallback restart required."
                        )

                threading.Thread(
                    target=delayed_tasks,
                    daemon=True,
                    name="ble-config-worker",
                ).start()

            finally:
                self._processing_lock.release()

        except Exception as e:
            print(f"WriteValue processing error: {e}")
            traceback.print_exc()
            self._set_status(BLE_STATUS_FAILED)

    @method()
    async def StartNotify(self):
        self.notifying = True
        print("StartNotify called")

    @method()
    async def StopNotify(self):
        self.notifying = False
        print("StopNotify called")

    @dbus_property(PropertyAccess.READ)
    def UUID(self) -> 's':
        return CHAR_UUID

    @dbus_property(PropertyAccess.READ)
    def Service(self) -> 'o':
        return self.service_path

    @dbus_property(PropertyAccess.READ)
    def Flags(self) -> 'as':
        return [
            'read',
            'write',
            'write-without-response',
        ]

    @dbus_property(PropertyAccess.READ)
    def Value(self) -> 'ay':
        return self._config_status.encode('utf-8')


class GattService(ServiceInterface):
    def __init__(self, path):
        super().__init__('org.bluez.GattService1')
        self.path = path

    @dbus_property(PropertyAccess.READ)
    def UUID(self) -> 's':
        return SERVICE_UUID

    @dbus_property(PropertyAccess.READ)
    def Primary(self) -> 'b':
        return True


class Application(ServiceInterface):
    def __init__(self, path):
        super().__init__('org.freedesktop.DBus.ObjectManager')
        self.path = path

    @method()
    async def GetManagedObjects(self) -> 'a{oa{sa{sv}}}':
        print("GetManagedObjects called")

        service_path = self.path + '/service0'
        char_path = service_path + '/char0'

        return {
            service_path: {
                'org.bluez.GattService1': {
                    'UUID': SERVICE_UUID,
                    'Primary': True,
                }
            },
            char_path: {
                'org.bluez.GattCharacteristic1': {
                    'UUID': CHAR_UUID,
                    'Service': service_path,
                    'Flags': [
                        'read',
                        'write',
                        'write-without-response',
                    ],
                }
            }
        }


class Advertisement(ServiceInterface):
    def __init__(self, path):
        super().__init__('org.bluez.LEAdvertisement1')
        self.path = path

    @method()
    async def Release(self):
        print("Advertisement released")

    @dbus_property(PropertyAccess.READ)
    def Type(self) -> 's':
        return 'peripheral'

    @dbus_property(PropertyAccess.READ)
    def LocalName(self) -> 's':
        return LOCAL_NAME

    @dbus_property(PropertyAccess.READ)
    def ServiceUUIDs(self) -> 'as':
        return [SERVICE_UUID]

    @dbus_property(PropertyAccess.READ)
    def Includes(self) -> 'as':
        return ['tx-power']


def get_gateway_ble_name():
    try:
        # Check cached EUI first.
        for path in (
            '/app/config/gateway_eui',
            '/etc/gateway/gateway_eui',
        ):
            if os.path.exists(path):
                try:
                    with open(path, 'r') as f:
                        eui = f.read().strip().lower()

                    if eui:
                        print(
                            f"Found cached gateway EUI: {eui}"
                        )
                        return f"Edgegateway-{eui}"

                except Exception:
                    pass

        env = os.environ.copy()
        env["PATH"] = (
            "/app/usr/bin:" +
            env.get("PATH", "")
        )

        cmd_list = (
            ['/app/usr/bin/chip_id']
            if os.path.exists('/app/usr/bin/chip_id')
            else ['chip_id']
        )

        result = subprocess.run(
            cmd_list,
            capture_output=True,
            text=True,
            timeout=20,
            env=env,
        )

        output = (
            (result.stdout or '') +
            '\n' +
            (result.stderr or '')
        )

        match = re.search(
            r'concentrator EUI:\s*0x([0-9a-fA-F]+)',
            output,
        )

        if match:
            eui = match.group(1).lower()

            print(
                "Parsed concentrator EUI using chip_id: "
                f"{eui}"
            )

            try:
                os.makedirs('/app/config', exist_ok=True)

                with open('/app/config/gateway_eui', 'w') as f:
                    f.write(eui)

            except Exception as ex:
                print(
                    f"Could not cache gateway_eui: {ex}"
                )

            return f"Edgegateway-{eui}"

        print(
            "chip_id output did not match EUI pattern. "
            f"Output:\n{output}"
        )

    except Exception as e:
        print(
            f"Error reading EUI in ConfigModule: {e}"
        )

    return "Edgegateway-unknown"


LOCAL_NAME = get_gateway_ble_name()


async def main():
    print("BLE application starting")

    led_task = None
    config_done_event = asyncio.Event()

    try:
        bus = await MessageBus(
            bus_address='unix:path=/var/run/dbus/system_bus_socket'
        ).connect()

        print("Connected to system bus")

        app_path = '/org/bluez/app'
        adv_path = '/org/bluez/adv0'
        service_path = app_path + '/service0'
        char_path = service_path + '/char0'

        app = Application(app_path)
        service = GattService(service_path)

        char = GattCharacteristic(
            char_path,
            service_path,
            config_done_event,
        )

        adv = Advertisement(adv_path)

        bus.export(app_path, app)
        bus.export(service_path, service)
        bus.export(char_path, char)
        bus.export(adv_path, adv)

        introspect_iface = await bus.introspect(
            'org.bluez',
            '/org/bluez/hci0'
        )

        proxy_obj = bus.get_proxy_object(
            'org.bluez',
            '/org/bluez/hci0',
            introspect_iface
        )

        gatt_iface = proxy_obj.get_interface(
            'org.bluez.GattManager1'
        )

        adv_iface = proxy_obj.get_interface(
            'org.bluez.LEAdvertisingManager1'
        )

        await gatt_iface.call_register_application(
            app_path,
            {}
        )

        await adv_iface.call_register_advertisement(
            adv_path,
            {}
        )

        print(
            f"GATT application and advertisement registered "
            f"as {LOCAL_NAME}"
        )

        led_task = asyncio.create_task(
            led_control_loop(bus)
        )

        print(
            f"BLE server waiting for configuration "
            f"(timeout={BLE_IDLE_TIMEOUT_SECONDS}s)"
        )

        # ---------------------------------------------------------
        # WAIT FOR CONFIGURATION OR TIMEOUT
        # ---------------------------------------------------------
        while not config_done_event.is_set():
            try:
                await asyncio.wait_for(
                    config_done_event.wait(),
                    timeout=BLE_IDLE_TIMEOUT_SECONDS,
                )

                print(
                    "Configuration received. Keeping BLE alive while "
                    "background tasks and restart complete."
                )

                # The config worker handles the actual restart/fallback timeout.
                # Keep main alive long enough for all slow tasks (Wi-Fi, etc) to finish.
                await asyncio.sleep(300)
                break

            except asyncio.TimeoutError:
                if not is_gateway_configured():
                    print(
                        f"BLE timeout ({BLE_IDLE_TIMEOUT_SECONDS}s) reached, but gateway is UNCONFIGURED. "
                        "Continuing BLE advertisement and keeping Blue LED solid ON until device gets configured..."
                    )
                    continue
                else:
                    print(
                        f"BLE timeout: gateway is configured and idle timeout of "
                        f"{BLE_IDLE_TIMEOUT_SECONDS}s reached. Exiting BLE mode."
                    )
                    break

    except Exception as e:
        print(f"main failed: {e}")
        traceback.print_exc()
        raise

    finally:
        if led_task:
            led_task.cancel()

            try:
                await led_task
            except asyncio.CancelledError:
                pass

        set_led_brightness("ble-led", 0)


if __name__ == '__main__':
    asyncio.run(main())
