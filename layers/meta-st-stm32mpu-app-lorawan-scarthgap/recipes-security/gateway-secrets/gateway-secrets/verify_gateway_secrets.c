/*
 * verify_gateway_secrets.c
 *
 * Verifies that the WiFi password, Azure connection string, and TTN API key
 * objects are present in the NXP SE050 HSM.
 *
 * Usage:
 *   verify-gateway-secrets [<i2c-device>]
 *
 * Exit codes:
 *   0 — all three objects present
 *   4 — one or more objects missing
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "ex_sss_boot.h"
#include "fsl_sss_api.h"
#include "fsl_sss_se05x_apis.h"

#define WIFI_PASSWORD_ID            0x7FFF0211U
#define AZURE_CONNECTION_STRING_ID  0x7FFF0212U
#define TTN_API_KEY_ID              0x7FFF0213U
#define HALOW_PASSWORD_ID           0x7FFF0214U

static int check_object(sss_key_store_t *ks, uint32_t object_id, const char *name)
{
    sss_status_t status;
    sss_object_t obj;

    memset(&obj, 0, sizeof(obj));

    status = sss_key_object_init(&obj, ks);
    if (status != kStatus_SSS_Success) {
        printf("%s: ERROR initializing object handle (rc=%d)\n", name, status);
        return 0;
    }

    status = sss_key_object_get_handle(&obj, object_id);
    if (status != kStatus_SSS_Success) {
        printf("%s: MISSING (object 0x%08X not found)\n", name, object_id);
        return 0;
    }

    printf("%s: OK (object 0x%08X present)\n", name, object_id);
    return 1;
}

int main(int argc, const char *argv[])
{
    sss_status_t status;
    ex_sss_boot_ctx_t ctx;
    char *portName = NULL;
    int ok = 1;

    memset(&ctx, 0, sizeof(ctx));

    if (argc < 2) {
        const char *default_argv[] = { argv[0], "none:/dev/i2c-0", NULL };
        status = ex_sss_boot_connectstring(2, (const char **)default_argv, &portName);
    } else {
        status = ex_sss_boot_connectstring(argc, argv, &portName);
    }

    if (status != kStatus_SSS_Success || portName == NULL) {
        fprintf(stderr, "ERROR: failed to parse connect string\n");
        return 1;
    }

    printf("verify-gateway-secrets: opening secure element on %s\n", portName);

    status = ex_sss_boot_open(&ctx, portName);
    if (status != kStatus_SSS_Success) {
        fprintf(stderr, "ERROR: ex_sss_boot_open failed\n");
        return 2;
    }

    status = ex_sss_key_store_and_object_init(&ctx);
    if (status != kStatus_SSS_Success) {
        fprintf(stderr, "ERROR: ex_sss_key_store_and_object_init failed\n");
        sss_session_close(&ctx.session);
        return 3;
    }

    ok &= check_object(&ctx.ks, WIFI_PASSWORD_ID,            "wifi_password");
    ok &= check_object(&ctx.ks, AZURE_CONNECTION_STRING_ID,  "azure_connection_string");
    ok &= check_object(&ctx.ks, TTN_API_KEY_ID,              "ttn_api_key");
    ok &= check_object(&ctx.ks, HALOW_PASSWORD_ID,           "halow_password");

    sss_key_store_context_free(&ctx.ks);
    sss_session_close(&ctx.session);

    if (ok) {
        printf("All gateway secret objects are present\n");
        return 0;
    }

    printf("One or more gateway secret objects are missing\n");
    return 4;
}
