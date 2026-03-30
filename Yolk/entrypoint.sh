#!/usr/bin/env bash
set -euo pipefail

CONTAINER_HOME="${CONTAINER_HOME:-/home/container}"
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
BAKED_WINEPREFIX="${SBOX_BAKED_WINEPREFIX:-/opt/sbox-wine-prefix}"
BAKED_SERVER_TEMPLATE="${SBOX_BAKED_SERVER_TEMPLATE:-/opt/sbox-server-template}"

SBOX_INSTALL_DIR="${SBOX_INSTALL_DIR:-/home/container/sbox}"
SBOX_SERVER_EXE="${SBOX_SERVER_EXE:-${SBOX_INSTALL_DIR}/sbox-server.exe}"
SBOX_APP_ID="${SBOX_APP_ID:-1892930}"
SBOX_AUTO_UPDATE="${SBOX_AUTO_UPDATE:-1}"
SBOX_BRANCH="${SBOX_BRANCH:-}"
STEAM_PLATFORM="${STEAM_PLATFORM:-windows}"
STEAMCMD_DIR="${STEAMCMD_DIR:-${CONTAINER_HOME}/steamcmd}"

GAME="${GAME:-}"
MAP="${MAP:-}"
SERVER_NAME="${SERVER_NAME:-}"
TOKEN="${TOKEN:-}"
SBOX_PROJECT="${SBOX_PROJECT:-}"
SBOX_EXTRA_ARGS="${SBOX_EXTRA_ARGS:-}"

STEAM_COMPAT_LOADER="/opt/steam-compat/lib/ld-linux.so.2"
STEAM_COMPAT_LIB_PATH="/opt/steam-compat/lib/i386-linux-gnu:/opt/steam-compat/usr/lib/i386-linux-gnu:/opt/steam-compat/lib"
SBOX_PREBAKED_SEEDED=0

if [ -z "${SERVER_NAME}" ] && [ -n "${HOSTNAME:-}" ] && ! [[ "${HOSTNAME}" =~ ^[0-9a-f]{12,64}$ ]]; then
    SERVER_NAME="${HOSTNAME}"
fi

seed_runtime_files() {
    local seed_sbox=0
    local seed_reason=""

    if [ ! -d "${SBOX_INSTALL_DIR}" ]; then
        seed_sbox=1
        seed_reason="missing install directory"
    elif [ -z "$(find "${SBOX_INSTALL_DIR}" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        seed_sbox=1
        seed_reason="empty install directory"
    elif [ ! -f "${SBOX_SERVER_EXE}" ]; then
        seed_sbox=1
        seed_reason="missing Windows server executable"
    fi

    mkdir -p "${CONTAINER_HOME}" "${WINEPREFIX}" "${SBOX_INSTALL_DIR}" "${CONTAINER_HOME}/logs" "${CONTAINER_HOME}/data" "${STEAMCMD_DIR}"

    if [ ! -f "${WINEPREFIX}/system.reg" ] && [ -d "${BAKED_WINEPREFIX}/drive_c" ]; then
        echo "info: seeding Wine prefix from ${BAKED_WINEPREFIX}" >&2
        cp -r "${BAKED_WINEPREFIX}/." "${WINEPREFIX}/"
    fi

    if [ "${seed_sbox}" = "1" ] && [ -d "${BAKED_SERVER_TEMPLATE}" ]; then
        echo "info: seeding S&Box files from ${BAKED_SERVER_TEMPLATE} (${seed_reason})" >&2
        cp -r "${BAKED_SERVER_TEMPLATE}/." "${SBOX_INSTALL_DIR}/"
        SBOX_PREBAKED_SEEDED=1
    elif [ "${seed_sbox}" = "1" ]; then
        echo "warn: ${SBOX_INSTALL_DIR} requires reseed (${seed_reason}) but prebaked template was not found at ${BAKED_SERVER_TEMPLATE}" >&2
    fi

}

steamcmd_installed() {
    local steamcmd_bin=""

    steamcmd_bin="$(resolve_steamcmd_binary)"
    if [ -z "${steamcmd_bin}" ]; then
        return 1
    fi

    if [ ! -x "${steamcmd_bin}" ]; then
        chmod 0755 "${steamcmd_bin}" 2>/dev/null || true
    fi

    [ -x "${steamcmd_bin}" ]
}

resolve_steamcmd_binary() {
    local candidate=""

    for candidate in \
        "${STEAMCMD_DIR}/linux32/steamcmd" \
        "${CONTAINER_HOME}/Steam/linux32/steamcmd"
    do
        if [ -f "${candidate}" ]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done

    return 1
}

run_steamcmd() {
    local -a args=("$@")
    local steamcmd_bin=""
    local steamcmd_root=""

    steamcmd_bin="$(resolve_steamcmd_binary || true)"

    if ! steamcmd_installed; then
        echo "warn: SteamCMD runtime binary was not found (checked ${STEAMCMD_DIR}/linux32/steamcmd and ${CONTAINER_HOME}/Steam/linux32/steamcmd)" >&2
        return 1
    fi

    if [ ! -x "${STEAM_COMPAT_LOADER}" ]; then
        echo "warn: Steam compatibility loader missing at ${STEAM_COMPAT_LOADER}" >&2
        return 1
    fi

    steamcmd_root="$(cd "$(dirname "${steamcmd_bin}")/.." && pwd)"

    (
        cd "${steamcmd_root}"
        "${STEAM_COMPAT_LOADER}" \
            --library-path "${STEAM_COMPAT_LIB_PATH}" \
            "${steamcmd_bin}" \
            "${args[@]}"
    )
}

update_sbox() {
    local -a steam_args
    local force_platform="windows"

    steam_args=(
        +@ShutdownOnFailedCommand 1
        +@NoPromptForPassword 1
        +@sSteamCmdForcePlatformType "${force_platform}"
        +force_install_dir "${SBOX_INSTALL_DIR}"
        +login anonymous
        +app_update "${SBOX_APP_ID}"
    )

    if [ -n "${SBOX_BRANCH}" ]; then
        steam_args+=( -beta "${SBOX_BRANCH}" )
    fi

    steam_args+=( validate +quit )

    if ! run_steamcmd +quit >/dev/null 2>&1; then
        echo "warn: SteamCMD runtime probe failed; cannot run auto-update" >&2
        if [ ! -f "${SBOX_SERVER_EXE}" ]; then
            echo "error: SteamCMD probe failed and ${SBOX_SERVER_EXE} is missing" >&2
            return 1
        fi
        return 0
    fi

    echo "info: running SteamCMD app_update for app ${SBOX_APP_ID} with forced platform '${force_platform}'" >&2
    if ! run_steamcmd "${steam_args[@]}"; then
        echo "warn: SteamCMD update failed with forced platform '${force_platform}'; refusing Linux fallback to preserve Wine-compatible server files" >&2
        return 1
    fi

    if [ ! -f "${SBOX_SERVER_EXE}" ] && [ -d "${SBOX_INSTALL_DIR}/linux64" ]; then
        echo "warn: update finished but Windows server executable is still missing while linux64 content exists in ${SBOX_INSTALL_DIR}" >&2
    fi
}

run_sbox() {
    local -a args=()
    local -a extra=()
    local -a launch_env=()

    if [ ! -f "${SBOX_SERVER_EXE}" ]; then
        echo "error: ${SBOX_SERVER_EXE} was not found" >&2
        echo "error: run the egg installation script, or enable auto-update after SteamCMD has been installed" >&2
        exit 1
    fi

    if [ -n "${SBOX_PROJECT}" ]; then
        args+=( "${SBOX_PROJECT}" )
    elif [ -n "${GAME}" ]; then
        args+=( +game "${GAME}" )
        if [ -n "${MAP}" ]; then
            args+=( "${MAP}" )
        fi
    fi

    if [ -n "${SERVER_NAME}" ]; then
        args+=( +hostname "${SERVER_NAME}" )
    fi

    if [ -n "${TOKEN}" ]; then
        args+=( +net_game_server_token "${TOKEN}" )
    fi

    if [ -n "${SBOX_EXTRA_ARGS}" ]; then
        read -r -a extra <<< "${SBOX_EXTRA_ARGS}"
        args+=( "${extra[@]}" )
    fi

    unset DOTNET_ROOT DOTNET_ROOT_X86 DOTNET_ROOT_X64

    launch_env=(
        DOTNET_EnableWriteXorExecute=0
        COMPlus_TieredCompilation=0
        COMPlus_ReadyToRun=0
        COMPlus_ZapDisable=1
    )

    cd "${SBOX_INSTALL_DIR}"
    exec env "${launch_env[@]}" wine "${SBOX_SERVER_EXE}" "${args[@]}"
}

if [ "${1:-}" = "start-sbox" ]; then
    shift
fi

seed_runtime_files

if [ "${1:-}" = "" ]; then
    if [ "${SBOX_AUTO_UPDATE}" = "1" ] || [ "${SBOX_PREBAKED_SEEDED}" = "1" ] || [ ! -f "${SBOX_SERVER_EXE}" ]; then
        update_sbox
    fi
    run_sbox
fi

exec "$@"
