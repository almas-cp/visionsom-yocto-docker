# Disable cryptodev-linux hardware acceleration module for OpenSSL.
# The cryptodev engine in OpenSSL 3.0 on 32-bit ARM (ARMv7) can produce
# mathematically corrupted RSA/ECDSA cryptographic signatures. Disabling it forces
# OpenSSL to use software cryptography, ensuring correct certificate signatures for
# Azure IoT Edge module handshakes.

PACKAGECONFIG:remove = "cryptodev-linux"
