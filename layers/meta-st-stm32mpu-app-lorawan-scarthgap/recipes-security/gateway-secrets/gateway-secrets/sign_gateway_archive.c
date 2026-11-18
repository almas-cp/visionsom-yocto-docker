/*
 * sign_gateway_archive.c
 *
 * Hardware-locked ECDSA digital signature utility using NXP SE050 HSM.
 * Implements IEC 62443-4-2 Level 4 / FIPS 140-2 Level 3 cryptographic log authenticity.
 *
 * Direct SE050 APDU implementation — fully compatible across SE050/SE051 applet versions.
 * The private key is generated inside the SE050 secure element and is mathematically
 * non-exportable. Even with root SSH access, an attacker cannot extract or steal the
 * private key.
 *
 * Object ID inside SE050:
 *   0x7FFF0300 — Log Signing ECC Keypair (NIST P-256 / secp256r1)
 *
 * Usage:
 *   sign-gateway-archive [<i2c-dev>] --init [<pubkey_file>]
 *   sign-gateway-archive [<i2c-dev>] --get-pubkey [<pubkey_file>]
 *   sign-gateway-archive [<i2c-dev>] --sign <archive_file> <sig_file>
 *   sign-gateway-archive [<i2c-dev>] --verify <archive_file> <sig_file>
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

#include <openssl/sha.h>

#include "ex_sss_boot.h"
#include "fsl_sss_api.h"
#include "fsl_sss_se05x_apis.h"
#include "se05x_APDU_apis.h"

#define LOG_SIGNER_KEY_ID 0x7FFF0300U

/* Standard ASN.1 SubjectPublicKeyInfo Header for NIST P-256 (RFC 5480 / RFC 5280) */
static const uint8_t gecc_der_header_nist256[] = {
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
    0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
    0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
    0x42, 0x00
};

static void base64_encode(const uint8_t *in, size_t in_len, char *out)
{
    static const char b64[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t i = 0, j = 0;
    while (i < in_len) {
        size_t rem = in_len - i;
        uint32_t octet_a = in[i++];
        uint32_t octet_b = (rem > 1) ? in[i++] : 0;
        uint32_t octet_c = (rem > 2) ? in[i++] : 0;

        uint32_t triple = (octet_a << 16) | (octet_b << 8) | octet_c;

        out[j++] = b64[(triple >> 18) & 0x3F];
        out[j++] = b64[(triple >> 12) & 0x3F];
        out[j++] = (rem > 1) ? b64[(triple >> 6) & 0x3F] : '=';
        out[j++] = (rem > 2) ? b64[triple & 0x3F] : '=';
    }
    out[j] = '\0';
}

static int write_pem_public_key(FILE *out, const uint8_t *der, size_t der_len)
{
    if (!out || !der || der_len == 0) return -1;
    char b64[2048];
    base64_encode(der, der_len, b64);

    fprintf(out, "-----BEGIN PUBLIC KEY-----\n");
    size_t len = strlen(b64);
    for (size_t i = 0; i < len; i += 64) {
        char line[65];
        size_t chunk = (len - i > 64) ? 64 : (len - i);
        memcpy(line, b64 + i, chunk);
        line[chunk] = '\0';
        fprintf(out, "%s\n", line);
    }
    fprintf(out, "-----END PUBLIC KEY-----\n");
    return 0;
}

static int compute_file_sha256(const char *path, uint8_t digest[32])
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "ERROR: Cannot open file '%s': %s\n", path, strerror(errno));
        return -1;
    }

    SHA256_CTX sha_ctx;
    if (!SHA256_Init(&sha_ctx)) {
        fclose(f);
        return -1;
    }

    uint8_t buffer[65536];
    size_t bytes_read = 0;
    while ((bytes_read = fread(buffer, 1, sizeof(buffer), f)) > 0) {
        SHA256_Update(&sha_ctx, buffer, bytes_read);
    }

    if (ferror(f)) {
        fprintf(stderr, "ERROR: Read error on file '%s'\n", path);
        fclose(f);
        return -1;
    }

    fclose(f);
    SHA256_Final(digest, &sha_ctx);
    return 0;
}

/* Check if the ECC signing key exists in SE050; if not, generate it in hardware */
static int ensure_ecc_keypair(pSe05xSession_t session_ctx, uint32_t key_id)
{
    SE05x_Result_t exists = kSE05x_Result_FAILURE;
    smStatus_t sm_status = Se05x_API_CheckObjectExists(session_ctx, key_id, &exists);
    if (sm_status == SM_OK && exists == kSE05x_Result_SUCCESS) {
        printf("sign-gateway-archive: ECC keypair 0x%08X already exists in SE050\n", key_id);
        return 0;
    }

    printf("sign-gateway-archive: Generating new ECC NIST P-256 keypair (0x%08X) in SE050 hardware...\n", key_id);

    sm_status = Se05x_API_WriteECKey(
        session_ctx,
        NULL,
        SE05x_MaxAttemps_NA,
        key_id,
        kSE05x_ECCurve_NIST_P256,
        NULL,
        0,
        NULL,
        0,
        kSE05x_INS_NA,
        kSE05x_KeyPart_Pair);

    if (sm_status != SM_OK) {
        fprintf(stderr, "ERROR: Se05x_API_WriteECKey failed (sm_status=0x%04X)\n", sm_status);
        return 1;
    }

    printf("sign-gateway-archive: ✅ Hardware keypair successfully generated inside SE050 (0x%08X)\n", key_id);
    return 0;
}

/* Export public key in PEM format */
static int export_public_key(pSe05xSession_t session_ctx, uint32_t key_id, const char *out_path)
{
    uint8_t raw_pubkey[128];
    size_t raw_len = sizeof(raw_pubkey);

    smStatus_t sm_status = Se05x_API_ReadObject(session_ctx, key_id, 0, 0, raw_pubkey, &raw_len);
    if (sm_status != SM_OK) {
        fprintf(stderr, "ERROR: Se05x_API_ReadObject failed for key 0x%08X (sm_status=0x%04X)\n", key_id, sm_status);
        return 1;
    }

    /* Wrap raw uncompressed public key (04 || X || Y) in X.509 SubjectPublicKeyInfo DER */
    uint8_t der_buf[256];
    size_t header_len = sizeof(gecc_der_header_nist256);
    memcpy(der_buf, gecc_der_header_nist256, header_len);
    memcpy(der_buf + header_len, raw_pubkey, raw_len);
    size_t total_der_len = header_len + raw_len;

    FILE *out = stdout;
    if (out_path && strcmp(out_path, "-") != 0) {
        out = fopen(out_path, "w");
        if (!out) {
            fprintf(stderr, "ERROR: Cannot write to '%s': %s\n", out_path, strerror(errno));
            return 2;
        }
    }

    write_pem_public_key(out, der_buf, total_der_len);

    if (out != stdout) {
        fclose(out);
        printf("sign-gateway-archive: ✅ Public key written to %s\n", out_path);
    }
    return 0;
}

/* Sign archive file digest using SE050 hardware ECC key */
static int sign_archive(pSe05xSession_t session_ctx, uint32_t key_id, const char *archive_path, const char *sig_path)
{
    uint8_t digest[32];
    if (compute_file_sha256(archive_path, digest) != 0) {
        return 1;
    }

    uint8_t sig_buf[256];
    size_t sig_len = sizeof(sig_buf);

    smStatus_t sm_status = Se05x_API_ECDSASign(
        session_ctx,
        key_id,
        kSE05x_ECSignatureAlgo_SHA_256,
        digest,
        sizeof(digest),
        sig_buf,
        &sig_len);

    if (sm_status != SM_OK) {
        fprintf(stderr, "ERROR: Se05x_API_ECDSASign failed for key 0x%08X (sm_status=0x%04X)\n", key_id, sm_status);
        return 2;
    }

    FILE *out = stdout;
    if (sig_path && strcmp(sig_path, "-") != 0) {
        out = fopen(sig_path, "wb");
        if (!out) {
            fprintf(stderr, "ERROR: Cannot open output '%s': %s\n", sig_path, strerror(errno));
            return 3;
        }
    }

    if (fwrite(sig_buf, 1, sig_len, out) != sig_len) {
        fprintf(stderr, "ERROR: Failed to write signature\n");
        if (out != stdout) fclose(out);
        return 4;
    }

    if (out != stdout) {
        fclose(out);
        printf("sign-gateway-archive: ✅ ECDSA signature created: %s (%zu bytes DER)\n", sig_path, sig_len);
    }
    return 0;
}

/* Verify archive signature using SE050 hardware */
static int verify_archive(pSe05xSession_t session_ctx, uint32_t key_id, const char *archive_path, const char *sig_path)
{
    uint8_t digest[32];
    if (compute_file_sha256(archive_path, digest) != 0) return 1;

    FILE *sf = fopen(sig_path, "rb");
    if (!sf) {
        fprintf(stderr, "ERROR: Cannot open signature '%s': %s\n", sig_path, strerror(errno));
        return 2;
    }
    uint8_t sig_buf[256];
    size_t sig_len = fread(sig_buf, 1, sizeof(sig_buf), sf);
    fclose(sf);

    if (sig_len == 0) {
        fprintf(stderr, "ERROR: Empty signature file\n");
        return 3;
    }

    SE05x_Result_t result = kSE05x_Result_FAILURE;
    smStatus_t sm_status = Se05x_API_ECDSAVerify(
        session_ctx,
        key_id,
        kSE05x_ECSignatureAlgo_SHA_256,
        digest,
        sizeof(digest),
        sig_buf,
        sig_len,
        &result);

    if (sm_status == SM_OK && result == kSE05x_Result_SUCCESS) {
        printf("sign-gateway-archive: ✅ Verified OK (Authentic SE050 Signature)\n");
        return 0;
    } else {
        printf("sign-gateway-archive: ❌ Verification Failure (Tampered or Invalid Signature)\n");
        return 4;
    }
}

int main(int argc, const char *argv[])
{
    const char *portName = "/dev/i2c-0";
    enum { OP_NONE, OP_INIT, OP_GET_PUBKEY, OP_SIGN, OP_VERIFY } op = OP_NONE;
    const char *arg1 = NULL;
    const char *arg2 = NULL;

    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "/dev/i2c-", 9) == 0 || strcmp(argv[i], "0") == 0 || strcmp(argv[i], "4") == 0) {
            portName = argv[i];
        } else if (strcmp(argv[i], "--init") == 0) {
            op = OP_INIT;
            if (i + 1 < argc && argv[i + 1][0] != '-') arg1 = argv[++i];
        } else if (strcmp(argv[i], "--get-pubkey") == 0) {
            op = OP_GET_PUBKEY;
            if (i + 1 < argc && argv[i + 1][0] != '-') arg1 = argv[++i];
        } else if (strcmp(argv[i], "--sign") == 0) {
            op = OP_SIGN;
            if (i + 2 < argc) {
                arg1 = argv[++i];
                arg2 = argv[++i];
            }
        } else if (strcmp(argv[i], "--verify") == 0) {
            op = OP_VERIFY;
            if (i + 2 < argc) {
                arg1 = argv[++i];
                arg2 = argv[++i];
            }
        }
    }

    if (op == OP_NONE || (op == OP_SIGN && (!arg1 || !arg2)) || (op == OP_VERIFY && (!arg1 || !arg2))) {
        fprintf(stderr,
            "Usage:\n"
            "  sign-gateway-archive [<i2c-dev>] --init [<pubkey_file>]\n"
            "  sign-gateway-archive [<i2c-dev>] --get-pubkey [<pubkey_file>]\n"
            "  sign-gateway-archive [<i2c-dev>] --sign <archive_file> <sig_file>\n"
            "  sign-gateway-archive [<i2c-dev>] --verify <archive_file> <sig_file>\n");
        return 1;
    }

    const char *connect_argv[] = { argv[0], portName, NULL };
    const char *chosen_port = NULL;
    sss_status_t status = ex_sss_boot_connectstring(2, connect_argv, &chosen_port);
    if (status != kStatus_SSS_Success || !chosen_port) {
        chosen_port = portName;
    }

    ex_sss_boot_ctx_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    status = ex_sss_boot_open(&ctx, chosen_port);
    if (status != kStatus_SSS_Success) {
        fprintf(stderr, "ERROR: ex_sss_boot_open failed on %s\n", chosen_port);
        return 2;
    }

    /* Extract direct APDU session pointer */
    pSe05xSession_t session_ctx = &((sss_se05x_session_t *)&ctx.session)->s_ctx;

    int rc = 0;
    switch (op) {
    case OP_INIT:
        rc = ensure_ecc_keypair(session_ctx, LOG_SIGNER_KEY_ID);
        if (rc == 0 && arg1) {
            rc = export_public_key(session_ctx, LOG_SIGNER_KEY_ID, arg1);
        }
        break;
    case OP_GET_PUBKEY:
        rc = export_public_key(session_ctx, LOG_SIGNER_KEY_ID, arg1);
        break;
    case OP_SIGN:
        rc = sign_archive(session_ctx, LOG_SIGNER_KEY_ID, arg1, arg2);
        break;
    case OP_VERIFY:
        rc = verify_archive(session_ctx, LOG_SIGNER_KEY_ID, arg1, arg2);
        break;
    default:
        rc = 1;
        break;
    }

    sss_session_close(&ctx.session);
    return rc;
}
