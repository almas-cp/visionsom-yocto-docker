/*
 * read_gateway_secrets.c
 *
 * Reads WiFi password, Azure IoT Hub SAS key, TTN API key, HaLow password,
 * ZIP password, and arbitrary custom credentials stored inside the NXP SE050 HSM.
 *
 * Usage:
 *   read-gateway-secrets [<i2c-device>]
 *   read-gateway-secrets [<i2c-device>] --get <name_or_id>
 *   read-gateway-secrets [<i2c-device>] --raw <name_or_id>
 *   read-gateway-secrets [<i2c-device>] --list
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include "ex_sss_boot.h"
#include "fsl_sss_api.h"
#include "fsl_sss_se05x_apis.h"

#define WIFI_PASSWORD_ID            0x7FFF0211U
#define AZURE_CONNECTION_STRING_ID  0x7FFF0212U
#define TTN_API_KEY_ID              0x7FFF0213U
#define HALOW_PASSWORD_ID           0x7FFF0214U
#define ZIP_PASSWORD_ID             0x7FFF0215U
#define SECRETS_CATALOG_ID          0x7FFF0210U

static uint32_t fnv1a_hash(const char *str)
{
    uint32_t hash = 2166136261u;
    while (*str) {
        hash ^= (uint8_t)*str++;
        hash *= 16777619u;
    }
    return hash;
}

static uint32_t name_to_id(const char *name)
{
    if (!name || !*name) return 0;

    /* Hex literal (e.g. 0x7FFF0220) */
    if (name[0] == '0' && (name[1] == 'x' || name[1] == 'X')) {
        return (uint32_t)strtoul(name, NULL, 16);
    }

    /* Decimal digits only */
    char *endptr = NULL;
    unsigned long val = strtoul(name, &endptr, 10);
    if (endptr && *endptr == '\0' && val > 0) {
        return (uint32_t)val;
    }

    /* Known built-in slots */
    if (strcmp(name, "wifi_password") == 0) return WIFI_PASSWORD_ID;
    if (strcmp(name, "azure_connection_string") == 0) return AZURE_CONNECTION_STRING_ID;
    if (strcmp(name, "ttn_api_key") == 0) return TTN_API_KEY_ID;
    if (strcmp(name, "halow_password") == 0) return HALOW_PASSWORD_ID;
    if (strcmp(name, "zip_password") == 0) return ZIP_PASSWORD_ID;
    if (strcmp(name, "catalog") == 0) return SECRETS_CATALOG_ID;

    /* Dynamic deterministic hash for arbitrary custom secret name. */
    uint32_t h = fnv1a_hash(name);
    return 0x7FFF1000U | (h & 0x0000EFFFU);
}

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

static int read_blob(ex_sss_boot_ctx_t *ctx, uint32_t id, const char *name)
{
    sss_status_t status;
    sss_object_t obj;
    uint8_t buffer[1024];
    size_t buffer_len = sizeof(buffer);
    size_t bit_len = 0;
    char b64_out[2048];

    memset(&obj, 0, sizeof(obj));
    status = sss_key_object_init(&obj, &ctx->ks);
    if (status != kStatus_SSS_Success) {
        printf("%s: ERROR init failed\n", name);
        return 1;
    }

    status = sss_key_object_get_handle(&obj, id);
    if (status != kStatus_SSS_Success) {
        printf("%s: NOT FOUND\n", name);
        return 2;
    }

    status = sss_key_store_get_key(
        &ctx->ks,
        &obj,
        buffer,
        &buffer_len,
        &bit_len);

    if (status != kStatus_SSS_Success) {
        printf("%s: ERROR read failed (rc=%d)\n", name, status);
        return 3;
    }

    /* Print as Base64 to safely handle binary keys and strings alike */
    base64_encode(buffer, buffer_len, b64_out);
    printf("%s: %s\n", name, b64_out);
    return 0;
}

static int read_blob_raw(ex_sss_boot_ctx_t *ctx, uint32_t id)
{
    sss_status_t status;
    sss_object_t obj;
    uint8_t buffer[1024];
    size_t buffer_len = sizeof(buffer);
    size_t bit_len = 0;

    memset(&obj, 0, sizeof(obj));
    status = sss_key_object_init(&obj, &ctx->ks);
    if (status != kStatus_SSS_Success) return 1;

    status = sss_key_object_get_handle(&obj, id);
    if (status != kStatus_SSS_Success) return 2;

    status = sss_key_store_get_key(
        &ctx->ks,
        &obj,
        buffer,
        &buffer_len,
        &bit_len);

    if (status != kStatus_SSS_Success) return 3;

    fwrite(buffer, 1, buffer_len, stdout);
    return 0;
}

static int check_slot_exists(ex_sss_boot_ctx_t *ctx, uint32_t id)
{
    sss_status_t status;
    sss_object_t obj;
    memset(&obj, 0, sizeof(obj));
    if (sss_key_object_init(&obj, &ctx->ks) != kStatus_SSS_Success) return 0;
    status = sss_key_object_get_handle(&obj, id);
    return (status == kStatus_SSS_Success);
}

static int catalog_read(ex_sss_boot_ctx_t *ctx, char *out, size_t max_len)
{
    sss_object_t obj;
    size_t out_len = max_len - 1;
    size_t bit_len = 0;
    out[0] = '\0';
    memset(&obj, 0, sizeof(obj));
    if (sss_key_object_init(&obj, &ctx->ks) != kStatus_SSS_Success) return 0;
    if (sss_key_object_get_handle(&obj, SECRETS_CATALOG_ID) != kStatus_SSS_Success) return 0;
    if (sss_key_store_get_key(&ctx->ks, &obj, (uint8_t *)out, &out_len, &bit_len) != kStatus_SSS_Success) return 0;
    out[out_len] = '\0';
    return (int)out_len;
}

int main(int argc, const char *argv[])
{
    ex_sss_boot_ctx_t ctx;
    sss_status_t status;
    const char *portName = "/dev/i2c-0";

    const char *get_key = NULL;
    const char *raw_key = NULL;
    int is_list = 0;

    /* Parse flags and port name */
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "/dev/i2c-", 9) == 0 || strcmp(argv[i], "0") == 0 || strcmp(argv[i], "4") == 0) {
            portName = argv[i];
        } else if (strcmp(argv[i], "--list") == 0) {
            is_list = 1;
        } else if ((strcmp(argv[i], "--get") == 0) && (i + 1 < argc)) {
            get_key = argv[++i];
        } else if ((strcmp(argv[i], "--raw") == 0) && (i + 1 < argc)) {
            raw_key = argv[++i];
        }
    }

    const char *connect_argv[] = { argv[0], portName, NULL };
    char *chosen_port = NULL;
    status = ex_sss_boot_connectstring(2, connect_argv, &chosen_port);
    if (status != kStatus_SSS_Success || !chosen_port) {
        chosen_port = (char *)portName;
    }

    if (!raw_key) {
        printf("read-gateway-secrets: opening secure element on %s\n", chosen_port);
    }

    memset(&ctx, 0, sizeof(ctx));
    status = ex_sss_boot_open(&ctx, chosen_port);
    if (status != kStatus_SSS_Success) {
        if (!raw_key) fprintf(stderr, "ERROR: ex_sss_boot_open failed\n");
        return 2;
    }

    status = ex_sss_key_store_and_object_init(&ctx);
    if (status != kStatus_SSS_Success) {
        if (!raw_key) fprintf(stderr, "ERROR: ex_sss_key_store_and_object_init failed\n");
        sss_session_close(&ctx.session);
        return 3;
    }

    /* MODE 1: Raw Output to stdout (no labels, ideal for scripts) */
    if (raw_key) {
        uint32_t id = name_to_id(raw_key);
        int rc = read_blob_raw(&ctx, id);
        sss_key_store_context_free(&ctx.ks);
        sss_session_close(&ctx.session);
        return (rc == 0) ? 0 : 4;
    }

    /* MODE 2: Single Key Base64 Output */
    if (get_key) {
        uint32_t id = name_to_id(get_key);
        int rc = read_blob(&ctx, id, get_key);
        sss_key_store_context_free(&ctx.ks);
        sss_session_close(&ctx.session);
        return (rc == 0) ? 0 : 4;
    }

    /* MODE 3: List all populated keys and slot IDs */
    if (is_list) {
        printf("--- Active Stored Secrets in SE050 HSM ---\n");
        struct { uint32_t id; const char *name; } builtins[] = {
            { WIFI_PASSWORD_ID, "wifi_password" },
            { AZURE_CONNECTION_STRING_ID, "azure_connection_string" },
            { TTN_API_KEY_ID, "ttn_api_key" },
            { HALOW_PASSWORD_ID, "halow_password" },
            { ZIP_PASSWORD_ID, "zip_password" },
        };
        for (int i = 0; i < 5; i++) {
            if (check_slot_exists(&ctx, builtins[i].id)) {
                printf("[0x%08X] %s (builtin)\n", builtins[i].id, builtins[i].name);
            }
        }

        char catalog[2048] = {0};
        if (catalog_read(&ctx, catalog, sizeof(catalog))) {
            char *copy = strdup(catalog);
            if (copy) {
                char *line = strtok(copy, "\r\n");
                while (line) {
                    uint32_t cid = name_to_id(line);
                    if (check_slot_exists(&ctx, cid)) {
                        printf("[0x%08X] %s (custom)\n", cid, line);
                    }
                    line = strtok(NULL, "\r\n");
                }
                free(copy);
            }
        }
        sss_key_store_context_free(&ctx.ks);
        sss_session_close(&ctx.session);
        return 0;
    }

    /* MODE 4: Default Full Read (Built-ins + all Custom Catalog Secrets) */
    read_blob(&ctx, WIFI_PASSWORD_ID,            "wifi_password");
    read_blob(&ctx, AZURE_CONNECTION_STRING_ID,  "azure_connection_string");
    read_blob(&ctx, TTN_API_KEY_ID,              "ttn_api_key");
    read_blob(&ctx, HALOW_PASSWORD_ID,           "halow_password");
    read_blob(&ctx, ZIP_PASSWORD_ID,             "zip_password");

    char catalog[2048] = {0};
    if (catalog_read(&ctx, catalog, sizeof(catalog))) {
        char *copy = strdup(catalog);
        if (copy) {
            char *line = strtok(copy, "\r\n");
            while (line) {
                uint32_t cid = name_to_id(line);
                read_blob(&ctx, cid, line);
                line = strtok(NULL, "\r\n");
            }
            free(copy);
        }
    }

    sss_key_store_context_free(&ctx.ks);
    sss_session_close(&ctx.session);
    return 0;
}
