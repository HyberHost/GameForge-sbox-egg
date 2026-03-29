#!/usr/bin/env bash
set -euo pipefail

EXPECTED_UID="${PUID:-999}"
EXPECTED_GID="${PGID:-999}"
CONTAINER_HOME="${CONTAINER_HOME:-/home/container}"
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
LOCK_DIR="${WINEPREFIX}/.init-lock"
SBOX_INSTALL_DIR="${SBOX_INSTALL_DIR:-/home/container/sbox}"
SBOX_SERVER_EXE="${SBOX_SERVER_EXE:-${SBOX_INSTALL_DIR}/sbox-server.exe}"
SBOX_APP_ID="${SBOX_APP_ID:-1892930}"
SBOX_AUTO_UPDATE="${SBOX_AUTO_UPDATE:-1}"
SBOX_BRANCH="${SBOX_BRANCH:-}"
STEAM_PLATFORM="${STEAM_PLATFORM:-windows}"
GAME="${GAME:-}"
MAP="${MAP:-}"
SERVER_NAME="${HOSTNAME:-}"
TOKEN="${TOKEN:-}"
SBOX_PROJECT="${SBOX_PROJECT:-}"
SBOX_EXTRA_ARGS="${SBOX_EXTRA_ARGS:-}"

if [ "$(id -u)" != "${EXPECTED_UID}" ]; then
    echo "fatal: running with uid $(id -u), expected ${EXPECTED_UID}" >&2
    exit 1
fi

if [ "$(id -g)" != "${EXPECTED_GID}" ]; then
    echo "warn: running with gid $(id -g), expected ${EXPECTED_GID}; continuing because some Pterodactyl setups remap group ids" >&2
fi

mkdir -p "${CONTAINER_HOME}" "${WINEPREFIX}" "${CONTAINER_HOME}/data" "${CONTAINER_HOME}/download" "${CONTAINER_HOME}/logs" "${CONTAINER_HOME}/sbox"

if [ ! -w "${CONTAINER_HOME}" ]; then
    echo "fatal: ${CONTAINER_HOME} is not writable by uid $(id -u)" >&2
    exit 1
fi

cleanup() {
    wineserver -k >/dev/null 2>&1 || true
}
trap cleanup EXIT

update_sbox() {
    local steamcmd_home="${CONTAINER_HOME}/.steamcmd"
    local steamcmd_bin="${STEAMCMD_BIN:-${steamcmd_home}/steamcmd.sh}"
    local bootstrap_tar="${steamcmd_home}/steamcmd_linux.tar.gz"
    local -a steam_args

    bootstrap_steamcmd() {
        mkdir -p "${steamcmd_home}"
        if ! wget -qO "${bootstrap_tar}" https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz; then
            echo "fatal: unable to download steamcmd bootstrap archive" >&2
            return 1
        fi
        if ! tar -xzf "${bootstrap_tar}" -C "${steamcmd_home}"; then
            echo "fatal: unable to extract steamcmd bootstrap archive" >&2
            return 1
        fi
        rm -f "${bootstrap_tar}"

        if [ -f "${steamcmd_home}/steamcmd.sh" ]; then
            chmod 0755 "${steamcmd_home}/steamcmd.sh" || true
            steamcmd_bin="${steamcmd_home}/steamcmd.sh"
            return 0
        fi

        echo "fatal: steamcmd bootstrap did not produce steamcmd.sh" >&2
        return 1
    }

    if [ ! -r "${steamcmd_bin}" ]; then
        if ! bootstrap_steamcmd; then
            exit 1
        fi
    fi

    mkdir -p "${SBOX_INSTALL_DIR}"

    steam_args=(
        +@sSteamCmdForcePlatformType "${STEAM_PLATFORM}"
        +force_install_dir "${SBOX_INSTALL_DIR}"
        +login anonymous
        +app_update "${SBOX_APP_ID}"
    )

    if [ -n "${SBOX_BRANCH}" ]; then
        steam_args+=( -beta "${SBOX_BRANCH}" )
    fi

    steam_args+=( validate +quit )

    echo "info: steamcmd path ${steamcmd_bin}" >&2
    if ! bash "${steamcmd_bin}" "${steam_args[@]}"; then
        echo "warn: steamcmd failed from ${steamcmd_bin}; attempting user-local bootstrap retry" >&2
        if ! bootstrap_steamcmd; then
            exit 1
        fi
        bash "${steamcmd_bin}" "${steam_args[@]}"
    fi
}

resolve_server_exe() {
    if [ -f "${SBOX_SERVER_EXE}" ]; then
        return 0
    fi

    local detected
    detected="$(find "${SBOX_INSTALL_DIR}" -maxdepth 6 -type f \( -iname 'sbox-server.exe' -o -iname 'sbox_server.exe' \) 2>/dev/null | head -n 1 || true)"
    if [ -n "${detected}" ]; then
        SBOX_SERVER_EXE="${detected}"
        echo "info: auto-detected S&Box executable at ${SBOX_SERVER_EXE}" >&2
        return 0
    fi

    return 1
}

run_sbox() {
    local -a args
    local -a extra

    if ! resolve_server_exe; then
        echo "fatal: no Windows S&Box server executable found under ${SBOX_INSTALL_DIR}. Verify STEAM_PLATFORM=windows and app/depot content." >&2
        exit 1
    fi

    if [ -n "${SBOX_PROJECT}" ]; then
        case "${SBOX_PROJECT}" in
            *.sbproj)
                args+=( "${SBOX_PROJECT}" )
                ;;
            *)
                echo "fatal: SBOX_PROJECT must point to a .sbproj file" >&2
                exit 1
                ;;
        esac
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

    cd "${SBOX_INSTALL_DIR}"
    if command -v xvfb-run >/dev/null 2>&1; then
        exec xvfb-run -a wine "${SBOX_SERVER_EXE}" "${args[@]}"
    fi
    exec wine "${SBOX_SERVER_EXE}" "${args[@]}"
}

if [ ! -f "${WINEPREFIX}/system.reg" ]; then
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
        if [ ! -f "${WINEPREFIX}/system.reg" ]; then
            export HOME="${CONTAINER_HOME}"
            export WINEPREFIX
            export WINEARCH="${WINEARCH:-win32}"

            if command -v xvfb-run >/dev/null 2>&1; then
                xvfb-run -a wineboot -u >/tmp/wineboot.log 2>&1 || true
            else
                wineboot -u >/tmp/wineboot.log 2>&1 || true
            fi
        fi
        rmdir "${LOCK_DIR}" || true
    else
        for _ in $(seq 1 60); do
            if [ -f "${WINEPREFIX}/system.reg" ]; then
                break
            fi
            sleep 1
        done
    fi
fi

if [ "$#" -eq 0 ] || [ "${1:-}" = "start-sbox" ]; then
    if [ "${1:-}" = "start-sbox" ]; then
        shift
    fi

    if [ "${SBOX_AUTO_UPDATE}" = "1" ] || [ ! -f "${SBOX_SERVER_EXE}" ]; then
        update_sbox
    fi

    if [ "$#" -gt 0 ]; then
        exec "$@"
    fi

    run_sbox
fi

exec "$@"
