cmake_minimum_required(VERSION 3.15)
project(gpu-proxy VERSION 2.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Find OpenSSL - use pkg-config or find in nix store
find_package(PkgConfig)
if(PKG_CONFIG_FOUND)
    pkg_check_modules(OPENSSL openssl)
endif()

# Fallback: find OpenSSL in nix store
if(NOT OPENSSL_FOUND)
    find_package(OpenSSL)
endif()

# Last resort: find OpenSSL libs in nix store
if(NOT OPENSSL_FOUND AND NOT OPENSSL_LIBRARIES)
    execute_process(
        COMMAND bash -c "find /nix/store -name 'libssl.so*' -type f 2>/dev/null | grep -v node | head -1 | xargs dirname"
        OUTPUT_VARIABLE OPENSSL_NIX_LIB
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    if(OPENSSL_NIX_LIB AND NOT "${OPENSSL_NIX_LIB}" STREQUAL "")
        set(OPENSSL_LIBRARIES "${OPENSSL_NIX_LIB}/libssl.so" "${OPENSSL_NIX_LIB}/libcrypto.so")
        # Find matching include dir
        execute_process(
            COMMAND bash -c "find /nix/store -name 'ssl.h' -path '*/include/openssl/*' 2>/dev/null | grep -v node | head -1 | xargs dirname | xargs dirname"
            OUTPUT_VARIABLE OPENSSL_NIX_INC
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
        set(OPENSSL_INCLUDE_DIRS "${OPENSSL_NIX_INC}")
        set(OPENSSL_FOUND TRUE)
        message(STATUS "Found OpenSSL in nix store: lib=${OPENSSL_NIX_LIB} inc=${OPENSSL_NIX_INC}")
    endif()
endif()

# Find nlohmann_json - try multiple paths for NixOS
find_path(NLOHMANN_JSON_INCLUDE_DIR nlohmann/json.hpp
    PATHS
        /nix/store/*/nlohmann_json-*/include
        /run/current-system/sw/include
        ${CMAKE_INCLUDE_PATH}
)

if(NOT NLOHMANN_JSON_INCLUDE_DIR)
    message(STATUS "nlohmann/json.hpp not found in standard paths")
    # Try to find it in nix store directly via json.hpp
    execute_process(
        COMMAND bash -c "find /nix/store -name 'json.hpp' -path '*/nlohmann/*' 2>/dev/null | head -1 | xargs dirname | xargs dirname"
        OUTPUT_VARIABLE NLOHMANN_NIX_INCLUDE
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    if(NLOHMANN_NIX_INCLUDE AND NOT "${NLOHMANN_NIX_INCLUDE}" STREQUAL "")
        set(NLOHMANN_JSON_INCLUDE_DIR "${NLOHMANN_NIX_INCLUDE}")
        message(STATUS "Found nlohmann_json at: ${NLOHMANN_JSON_INCLUDE_DIR}")
    else()
        # For NixOS build, will be provided by buildInputs
        set(NLOHMANN_JSON_INCLUDE_DIR "")
    endif()
endif()

add_executable(gpu-proxy
    src/main.cpp
    src/config.cpp
    src/ssl_utils.cpp
    src/stratum.cpp
    src/connection.cpp
    src/event_loop.cpp
    src/pool_manager.cpp
    src/worker_manager.cpp
)

if(NLOHMANN_JSON_INCLUDE_DIR)
    target_include_directories(gpu-proxy PRIVATE ${NLOHMANN_JSON_INCLUDE_DIR})
endif()

if(OPENSSL_FOUND)
    target_include_directories(gpu-proxy PRIVATE ${OPENSSL_INCLUDE_DIRS})
    target_link_libraries(gpu-proxy ${OPENSSL_LIBRARIES} pthread)
elseif(TARGET OpenSSL::SSL)
    target_link_libraries(gpu-proxy OpenSSL::SSL OpenSSL::Crypto pthread)
endif()

# Installation
install(TARGETS gpu-proxy DESTINATION bin)
