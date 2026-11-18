/*
 * store_gateway_secrets.c
 *
 * Stores WiFi password, Azure IoT Hub SAS key / connection string, TTN API key,
 * HaLow password, ZIP password, and arbitrary custom credentials into the
 * NXP SE050 HSM as persistent secure objects.
 *
 * Dynamic Custom Credentials:
 *   Any arbitrary secret name or hex slot ID can be stored without recompilation.
 *
 * Usage:
 *   store-gateway-secrets [<i2c-dev>] --stdin
 *   store-gateway-secrets [<i2c-dev>] --set <name_or_id> <secret_value_or_->
 *   store-gateway-secrets [<i2c-dev>] --del <name_or_id>
 *   store-gateway-secrets [<i2c-dev>] --clear
 *   store-gateway-secrets [<i2c-dev>] <wifi_pw> <azure_cs> <ttn_key> <halow_pw> [zip_pw]
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

static void secure_zero(void *v, size_t n)
{
    if (!v) return;
    volatile uint8_t *p = (volatile uint8_t *)v;
    while (n--) *p++ = 0;
}

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

    /* Dynamic deterministic hash for arbitrary custom secret name.
     * Maps into range 0x7FFF1000 - 0x7FFFFEFF (avoids 0x7FFF02xx builtins). */
    uint32_t h = fnv1a_hash(name);
    return 0x7FFF1000U | (h & 0x0000EFFFU);
}

static int is_builtin_id(uint32_t id)
{
    return (id >= 0x7FFF0211U && id <= 0x7FFF0215U) || (id == SECRETS_CATALOG_ID);
}

static sss_status_t erase_slot(ex_sss_boot_ctx_t *ctx, uint32_t object_id, const char *name)
{
    sss_object_t obj;
    memset(&obj, 0, sizeof(obj));
    if (sss_key_object_init(&obj, &ctx->ks) == kStatus_SSS_Success) {
        if (sss_key_object_get_handle(&obj, object_id) == kStatus_SSS_Success) {
            if (sss_key_store_erase_key(&ctx->ks, &obj) == kStatus_SSS_Success) {
                if (name) printf("Erased object '%s' (0x%08X)\n", name, object_id);
                else printf("Erased object 0x%08X\n", object_id);
                return kStatus_SSS_Success;
            }
        }
    }
    return kStatus_SSS_Fail;
}

static sss_status_t write_blob(ex_sss_boot_ctx_t *ctx,
                               uint32_t object_id,
                               const char *name,
                               const uint8_t *data,
                               size_t data_len,
                               sss_cipher_type_t cipher_type)
{
    sss_status_t status;
    sss_object_t obj;

    memset(&obj, 0, sizeof(obj));
    printf("%s: preparing to store in SE050 (len=%zu, id=0x%08X)\n", name, data_len, object_id);

    /* STEP 1 — init and try to erase any existing object at this ID */
    status = sss_key_object_init(&obj, &ctx->ks);
    if (status != kStatus_SSS_Success) {
        printf("%s: ERROR init rc=%d\n", name, status);
        return status;
    }

    status = sss_key_object_get_handle(&obj, object_id);
    if (status == kStatus_SSS_Success) {
        status = sss_key_store_erase_key(&ctx->ks, &obj);
        if (status == kStatus_SSS_Success) {
            printf("%s: old object erased\n", name);
        } else {
            printf("%s: WARN erase failed (rc=%d), continuing...\n", name, status);
        }
    }

    /* STEP 2 — fresh init after erase */
    memset(&obj, 0, sizeof(obj));
    status = sss_key_object_init(&obj, &ctx->ks);
    if (status != kStatus_SSS_Success) {
        printf("%s: ERROR re-init rc=%d\n", name, status);
        return status;
    }

    /* STEP 3 — allocate a persistent binary/HMAC object */
    status = sss_key_object_allocate_handle(
        &obj,
        object_id,
        kSSS_KeyPart_Default,
        cipher_type,
        data_len,
        kKeyObject_Mode_Persistent);

    if (status != kStatus_SSS_Success) {
        printf("%s: ERROR allocate rc=%d\n", name, status);
        return status;
    }

    /* STEP 4 — write data */
    status = sss_key_store_set_key(
        &ctx->ks,
        &obj,
        data,
        data_len,
        data_len * 8,
        NULL,
        0);

    if (status != kStatus_SSS_Success) {
        printf("%s: ERROR set key rc=%d\n", name, status);
        return status;
    }

    printf("%s: STORED successfully (id=0x%08X)\n", name, object_id);
    return kStatus_SSS_Success;
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

static void catalog_add(ex_sss_boot_ctx_t *ctx, const char *name)
{
    if (is_builtin_id(name_to_id(name))) return;

    char catalog[2048] = {0};
    catalog_read(ctx, catalog, sizeof(catalog));

    char needle[128];
    snprintf(needle, sizeof(needle), "%s\n", name);
    if (strstr(catalog, needle) == NULL) {
        strncat(catalog, needle, sizeof(catalog) - strlen(catalog) - 1);
        write_blob(ctx, SECRETS_CATALOG_ID, "catalog", (const uint8_t *)catalog, strlen(catalog), kSSS_CipherType_Binary);
    }
}

static void catalog_remove(ex_sss_boot_ctx_t *ctx, const char *name)
{
    char catalog[2048] = {0};
    if (!catalog_read(ctx, catalog, sizeof(catalog))) return;

    char new_cat[2048] = {0};
    char *copy = strdup(catalog);
    if (!copy) return;

    char *line = strtok(copy, "\r\n");
    while (line) {
        if (strcmp(line, name) != 0) {
            strncat(new_cat, line, sizeof(new_cat) - strlen(new_cat) - 2);
            strcat(new_cat, "\n");
        }
        line = strtok(NULL, "\r\n");
    }
    free(copy);

    if (new_cat[0]) {
        write_blob(ctx, SECRETS_CATALOG_ID, "catalog", (const uint8_t *)new_cat, strlen(new_cat), kSSS_CipherType_Binary);
    } else {
        erase_slot(ctx, SECRETS_CATALOG_ID, "catalog");
    }
}

static void save_non_sensitive_field(const char *path, const char *val)
{
    if (!val || !val[0]) return;
    FILE *f = fopen(path, "w");
    if (f) {
        fprintf(f, "%s\n", val);
        fclose(f);
    }
}

static int base64_decode(const char *in, size_t in_len, uint8_t *out, size_t *out_len)
{
    static const int b64[256] = {
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,
        52,53,54,55,56,57,58,59,60,61,-1,-1,-1,-1,-1,-1,
        -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,
        15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,-1,
        -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,
        41,42,43,44,45,46,47,48,49,50,51,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
    };
    size_t i = 0, j = 0;
    uint32_t val = 0;
    int valb = -8;
    for (i = 0; i < in_len; i++) {
        if (in[i] == '=') break;
        int c = b64[(unsigned char)in[i]];
        if (c == -1) continue;
        val = (val << 6) | c;
        valb += 6;
        if (valb >= 0) {
            out[j++] = (val >> valb) & 0xFF;
            valb -= 8;
        }
    }
    *out_len = j;
    return 0;
}

static size_t parse_and_store_azure_metadata(char *cs)
{
    char *p;
    char hostname[256] = {0};
    char device_id[256] = {0};
    char sas_key_b64[256] = {0};
    size_t binary_len = 0;

    p = strstr(cs, "HostName=");
    if (p) {
        p += 9;
        char *end = strchr(p, ';');
        if (end) {
            size_t len = end - p;
            if (len < sizeof(hostname)) {
                strncpy(hostname, p, len);
                hostname[len] = '\0';
            }
        }
    }

    p = strstr(cs, "DeviceId=");
    if (p) {
        p += 9;
        char *end = strchr(p, ';');
        if (end) {
            size_t len = end - p;
            if (len < sizeof(device_id)) {
                strncpy(device_id, p, len);
                device_id[len] = '\0';
            }
        }
    }

    p = strstr(cs, "SharedAccessKey=");
    if (p) {
        p += 16;
        char *end = strchr(p, ';');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (len < sizeof(sas_key_b64)) {
            strncpy(sas_key_b64, p, len);
            sas_key_b64[len] = '\0';
        }
    }

    if (hostname[0]) {
        save_non_sensitive_field("/etc/gateway/azure_hostname", hostname);
        save_non_sensitive_field("/app/config/azure_hostname", hostname);
        printf("Saved Azure HostName to config: %s\n", hostname);
    }
    if (device_id[0]) {
        save_non_sensitive_field("/etc/gateway/azure_device_id", device_id);
        save_non_sensitive_field("/app/config/azure_device_id", device_id);
        printf("Saved Azure DeviceId to config: %s\n", device_id);
    }

    remove("/etc/gateway/connection_string");
    remove("/etc/gateway/azure_connection_string");
    remove("/app/config/connection_string");

    if (sas_key_b64[0]) {
        base64_decode(sas_key_b64, strlen(sas_key_b64), (uint8_t*)cs, &binary_len);
    } else {
        base64_decode(cs, strlen(cs), (uint8_t*)cs, &binary_len);
    }

    return binary_len;
}

int main(int argc, const char *argv[])
{
    ex_sss_boot_ctx_t ctx;
    sss_status_t status;
    const char *portName = "/dev/i2c-0";

    char wifi_pw[256] = {0};
    char azure_cs[512] = {0};
    char ttn_key[256] = {0};
    char halow_pw[256] = {0};
    char zip_pw[256] = {0};

    int is_stdin = 0;
    int is_clear = 0;
    const char *set_key = NULL;
    const char *set_val = NULL;
    const char *del_key = NULL;

    /* Parse command-line flags and port name */
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "/dev/i2c-", 9) == 0 || strcmp(argv[i], "0") == 0 || strcmp(argv[i], "4") == 0) {
            portName = argv[i];
        } else if (strcmp(argv[i], "--stdin") == 0) {
            is_stdin = 1;
        } else if (strcmp(argv[i], "--clear") == 0) {
            is_clear = 1;
        } else if ((strcmp(argv[i], "--set") == 0) && (i + 2 < argc)) {
            set_key = argv[++i];
            set_val = argv[++i];
        } else if ((strcmp(argv[i], "--del") == 0 || strcmp(argv[i], "--delete") == 0) && (i + 1 < argc)) {
            del_key = argv[++i];
        }
    }

    /* Open HSM Connection */
    memset(&ctx, 0, sizeof(ctx));
    printf("store-gateway-secrets: opening secure element on %s\n", portName);

    const char *connect_argv[] = { argv[0], portName, NULL };
    char *chosen_port = NULL;
    status = ex_sss_boot_connectstring(2, connect_argv, &chosen_port);
    if (status != kStatus_SSS_Success || !chosen_port) {
        chosen_port = (char *)portName;
    }

    status = ex_sss_boot_open(&ctx, chosen_port);
    if (status != kStatus_SSS_Success) {
        fprintf(stderr, "ERROR: ex_sss_boot_open failed\n");
        return 3;
    }

    status = ex_sss_key_store_and_object_init(&ctx);
    if (status != kStatus_SSS_Success) {
        fprintf(stderr, "ERROR: ex_sss_key_store_and_object_init failed\n");
        sss_session_close(&ctx.session);
        return 4;
    }

    /* MODE 1: Single Key Deletion (--del <name_or_id>) */
    if (del_key) {
        uint32_t id = name_to_id(del_key);
        if (id == 0) {
            fprintf(stderr, "ERROR: Invalid key name or ID '%s'\n", del_key);
            status = kStatus_SSS_Fail;
            goto cleanup;
        }
        status = erase_slot(&ctx, id, del_key);
        catalog_remove(&ctx, del_key);
        goto cleanup;
    }

    /* MODE 2: Single Key Insertion/Update (--set <name_or_id> <value>) */
    if (set_key && set_val) {
        uint32_t id = name_to_id(set_key);
        if (id == 0) {
            fprintf(stderr, "ERROR: Invalid key name or ID '%s'\n", set_key);
            status = kStatus_SSS_Fail;
            goto cleanup;
        }

        char buffer[1024];
        const char *data_to_write = set_val;

        /* If value is '-', read from standard input */
        if (strcmp(set_val, "-") == 0) {
            size_t n = fread(buffer, 1, sizeof(buffer) - 1, stdin);
            buffer[n] = '\0';
            while (n > 0 && (buffer[n - 1] == '\n' || buffer[n - 1] == '\r')) {
                buffer[--n] = '\0';
            }
            data_to_write = buffer;
        }

        if (id == AZURE_CONNECTION_STRING_ID) {
            char cs_copy[1024];
            strncpy(cs_copy, data_to_write, sizeof(cs_copy) - 1);
            size_t bin_len = parse_and_store_azure_metadata(cs_copy);
            status = write_blob(&ctx, id, set_key, (const uint8_t *)cs_copy, bin_len, kSSS_CipherType_Binary);
        } else {
            status = write_blob(&ctx, id, set_key, (const uint8_t *)data_to_write, strlen(data_to_write), kSSS_CipherType_Binary);
            catalog_add(&ctx, set_key);
        }

        goto cleanup;
    }

    /* MODE 3: Clear All Stored Secrets & Catalog (--clear) */
    if (is_clear) {
        printf("store-gateway-secrets: clearing all secrets from HSM...\n");
        uint32_t ids[] = { WIFI_PASSWORD_ID, AZURE_CONNECTION_STRING_ID, TTN_API_KEY_ID, HALOW_PASSWORD_ID, ZIP_PASSWORD_ID };
        for (int i = 0; i < 5; i++) {
            erase_slot(&ctx, ids[i], NULL);
        }

        char catalog[2048] = {0};
        if (catalog_read(&ctx, catalog, sizeof(catalog))) {
            char *copy = strdup(catalog);
            if (copy) {
                char *line = strtok(copy, "\r\n");
                while (line) {
                    uint32_t cid = name_to_id(line);
                    erase_slot(&ctx, cid, line);
                    line = strtok(NULL, "\r\n");
                }
                free(copy);
            }
            erase_slot(&ctx, SECRETS_CATALOG_ID, "catalog");
        }
        status = kStatus_SSS_Success;
        goto cleanup;
    }

    /* MODE 4: Stdin Stream (Parses standard and custom key=val pairs) */
    if (is_stdin) {
        char line[1024];
        while (fgets(line, sizeof(line), stdin)) {
            char *nl = strpbrk(line, "\r\n");
            if (nl) *nl = '\0';
            if (!line[0] || line[0] == '#') continue;

            char *eq = strchr(line, '=');
            if (!eq) continue;
            *eq = '\0';
            char *k = line;
            char *v = eq + 1;

            if (strcmp(k, "wifi_password") == 0) {
                strncpy(wifi_pw, v, sizeof(wifi_pw) - 1);
            } else if (strcmp(k, "azure_connection_string") == 0) {
                strncpy(azure_cs, v, sizeof(azure_cs) - 1);
            } else if (strcmp(k, "ttn_api_key") == 0) {
                strncpy(ttn_key, v, sizeof(ttn_key) - 1);
            } else if (strcmp(k, "halow_password") == 0) {
                strncpy(halow_pw, v, sizeof(halow_pw) - 1);
            } else if (strcmp(k, "zip_password") == 0) {
                strncpy(zip_pw, v, sizeof(zip_pw) - 1);
            } else {
                /* Custom key passed via stdin */
                uint32_t cid = name_to_id(k);
                if (v[0]) {
                    write_blob(&ctx, cid, k, (const uint8_t *)v, strlen(v), kSSS_CipherType_Binary);
                    catalog_add(&ctx, k);
                } else {
                    erase_slot(&ctx, cid, k);
                    catalog_remove(&ctx, k);
                }
            }
        }
    } else if (argc >= 5) {
        /* Positional invocation */
        int arg_idx = 1;
        if (strncmp(argv[arg_idx], "/dev/i2c-", 9) == 0 || strcmp(argv[arg_idx], "0") == 0 || strcmp(argv[arg_idx], "4") == 0) {
            arg_idx++;
        }
        if (arg_idx < argc) strncpy(wifi_pw, argv[arg_idx++], sizeof(wifi_pw) - 1);
        if (arg_idx < argc) strncpy(azure_cs, argv[arg_idx++], sizeof(azure_cs) - 1);
        if (arg_idx < argc) strncpy(ttn_key, argv[arg_idx++], sizeof(ttn_key) - 1);
        if (arg_idx < argc) strncpy(halow_pw, argv[arg_idx++], sizeof(halow_pw) - 1);
        if (arg_idx < argc) strncpy(zip_pw, argv[arg_idx++], sizeof(zip_pw) - 1);
    } else {
        fprintf(stderr,
            "Usage: %s [<i2c-dev>] --stdin\n"
            "       %s [<i2c-dev>] --set <name_or_id> <value_or_->\n"
            "       %s [<i2c-dev>] --del <name_or_id>\n"
            "       %s [<i2c-dev>] --clear\n"
            "   or: %s [<i2c-dev>] <wifi_password> <azure_connection_string> <ttn_api_key> <halow_password> [zip_password]\n",
            argv[0], argv[0], argv[0], argv[0], argv[0]);
        status = kStatus_SSS_Fail;
        goto cleanup;
    }

    /* Store Standard Wi-Fi password */
    if (wifi_pw[0]) {
        status = write_blob(&ctx, WIFI_PASSWORD_ID,
            "wifi_password", (const uint8_t *)wifi_pw, strlen(wifi_pw), kSSS_CipherType_Binary);
        if (status != kStatus_SSS_Success) goto cleanup;
    }

    /* Store Standard Azure credential */
    if (azure_cs[0]) {
        size_t bin_len = parse_and_store_azure_metadata(azure_cs);
        status = write_blob(&ctx, AZURE_CONNECTION_STRING_ID,
            "azure_connection_string", (const uint8_t *)azure_cs, bin_len, kSSS_CipherType_Binary);
        if (status != kStatus_SSS_Success) goto cleanup;
    }

    /* Store Standard TTN API Key */
    if (ttn_key[0]) {
        status = write_blob(&ctx, TTN_API_KEY_ID,
            "ttn_api_key", (const uint8_t *)ttn_key, strlen(ttn_key), kSSS_CipherType_Binary);
        if (status != kStatus_SSS_Success) goto cleanup;
    }

    /* Store Standard HaLow Password */
    if (halow_pw[0]) {
        status = write_blob(&ctx, HALOW_PASSWORD_ID,
            "halow_password", (const uint8_t *)halow_pw, strlen(halow_pw), kSSS_CipherType_Binary);
        if (status != kStatus_SSS_Success) goto cleanup;
    }

    /* Store Standard ZIP Password */
    if (zip_pw[0]) {
        status = write_blob(&ctx, ZIP_PASSWORD_ID,
            "zip_password", (const uint8_t *)zip_pw, strlen(zip_pw), kSSS_CipherType_Binary);
        if (status != kStatus_SSS_Success) goto cleanup;
    }

    printf("Secrets stored securely into SE050 HSM.\n");

cleanup:
    secure_zero(wifi_pw, sizeof(wifi_pw));
    secure_zero(azure_cs, sizeof(azure_cs));
    secure_zero(ttn_key, sizeof(ttn_key));
    secure_zero(halow_pw, sizeof(halow_pw));
    secure_zero(zip_pw, sizeof(zip_pw));

    sss_key_store_context_free(&ctx.ks);
    sss_session_close(&ctx.session);
    return (status == kStatus_SSS_Success) ? 0 : 5;
}
