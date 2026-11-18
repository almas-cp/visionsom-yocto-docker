cmake_minimum_required(VERSION 3.10)
project(gateway-secrets C)

add_definitions(-DSSS_USE_FTR_FILE)

include(GNUInstallDirs)

# ── Locate se05x-mw headers ────────────────────────────────────────────────────
# These are installed by the se05x-mw Yocto recipe into the sysroot.
find_path(SSS_INC_DIR
    NAMES fsl_sss_api.h
    PATH_SUFFIXES se05x
    REQUIRED
)

find_path(EX_SSS_INC_DIR
    NAMES ex_sss_boot.h
    PATH_SUFFIXES se05x
    REQUIRED
)

find_path(SE05X_INC_DIR
    NAMES fsl_sss_se05x_apis.h
    PATH_SUFFIXES se05x
    REQUIRED
)

# ── Locate se05x-mw shared libraries ─────────────────────────────────────────
find_library(SSS_APIS_LIB
    NAMES SSS_APIs
    REQUIRED
)

find_library(EX_COMMON_LIB
    NAMES ex_common
    REQUIRED
)

find_library(SE05X_LIB
    NAMES se05x
    REQUIRED
)

find_package(OpenSSL REQUIRED)

set(SE05X_INCLUDES
    ${SSS_INC_DIR}
    ${EX_SSS_INC_DIR}
    ${SE05X_INC_DIR}
    ${OPENSSL_INCLUDE_DIR}
)

set(SE05X_LIBS
    ${SSS_APIS_LIB}
    ${EX_COMMON_LIB}
    ${SE05X_LIB}
    OpenSSL::Crypto
)

# ── Build each tool ─────────────────────────────────────────────────────────
foreach(TOOL
    store_gateway_secrets
    read_gateway_secrets
    verify_gateway_secrets
    sign_gateway_archive
)
    add_executable(${TOOL} ${TOOL}.c)
    string(REPLACE "_" "-" TOOL_BIN ${TOOL})
    set_target_properties(${TOOL} PROPERTIES OUTPUT_NAME ${TOOL_BIN})
    target_include_directories(${TOOL} PRIVATE ${SE05X_INCLUDES})
    target_link_libraries(${TOOL} ${SE05X_LIBS})

    install(TARGETS ${TOOL}
        DESTINATION ${CMAKE_INSTALL_BINDIR}
    )
endforeach()
