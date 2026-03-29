#!/usr/bin/env bash
set -euo pipefail

EXPECTED_UID="${PUID:-999}"
EXPECTED_GID="${PGID:-$(id -g)}"
CONTAINER_HOME="${CONTAINER_HOME:-/home/container}"
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
LOCK_DIR="${WINEPREFIX}/.init-lock"
SBOX_INSTALL_DIR="${SBOX_INSTALL_DIR:-/home/container/sbox}"
SBOX_SERVER_EXE="${SBOX_SERVER_EXE:-${SBOX_INSTALL_DIR}/sbox-server.exe}"
SBOX_APP_ID="${SBOX_APP_ID:-1892930}"
SBOX_AUTO_UPDATE="${SBOX_AUTO_UPDATE:-1}"
SBOX_BRANCH="${SBOX_BRANCH:-}"
STEAM_PLATFORM="${STEAM_PLATFORM:-windows}"
RESET_WINEPREFIX_ON_ARCH_MISMATCH="${RESET_WINEPREFIX_ON_ARCH_MISMATCH:-1}"
INSTALL_WINETRICKS_DOTNET="${INSTALL_WINETRICKS_DOTNET:-0}"
WINETRICKS_VERBS="${WINETRICKS_VERBS:-win10 vcrun2022 dotnet48 dotnet10}"
WINETRICKS_STRICT="${WINETRICKS_STRICT:-0}"
INSTALL_WIN_DOTNET="${INSTALL_WIN_DOTNET:-0}"
WIN_DOTNET_VERSION="${WIN_DOTNET_VERSION:-10.0.2}"
WIN_DOTNET_INSTALL_METHOD="${WIN_DOTNET_INSTALL_METHOD:-installer}"
WIN_DOTNET_ROOT="${WIN_DOTNET_ROOT:-C:\\Program Files\\dotnet}"
DOTNET_MULTILEVEL_LOOKUP="${DOTNET_MULTILEVEL_LOOKUP:-0}"
GAME="${GAME:-}"
MAP="${MAP:-}"
SERVER_NAME="${HOSTNAME:-}"
TOKEN="${TOKEN:-}"
SBOX_PROJECT="${SBOX_PROJECT:-}"
SBOX_EXTRA_ARGS="${SBOX_EXTRA_ARGS:-}"

detect_prefix_arch() {
    if [ ! -f "${WINEPREFIX}/system.reg" ]; then
        return 1
    fi

    if grep -qi "#arch=win64" "${WINEPREFIX}/system.reg"; then
        echo "win64"
        return 0
    fi

    if grep -qi "#arch=win32" "${WINEPREFIX}/system.reg"; then
        echo "win32"
        return 0
    fi

    return 1
}

ensure_wineprefix_arch() {
    local current_arch

    current_arch="$(detect_prefix_arch || true)"
    if [ -z "${current_arch}" ]; then
        return 0
    fi

    if [ "${current_arch}" = "${WINEARCH:-win64}" ]; then
        return 0
    fi

    if [ "${RESET_WINEPREFIX_ON_ARCH_MISMATCH}" != "1" ]; then
        echo "fatal: wine prefix architecture is ${current_arch} but WINEARCH=${WINEARCH:-win64}. Delete ${WINEPREFIX} or set RESET_WINEPREFIX_ON_ARCH_MISMATCH=1." >&2
        exit 1
    fi

    echo "warn: recreating ${WINEPREFIX} because prefix arch ${current_arch} does not match WINEARCH=${WINEARCH:-win64}" >&2
    rm -rf "${WINEPREFIX}"
    mkdir -p "${WINEPREFIX}"
}

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

ensure_wineprefix_arch

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

    # Force .NET host discovery to use Windows runtime inside Wine prefix.
    unset DOTNET_ROOT DOTNET_ROOT_X86

    cd "${SBOX_INSTALL_DIR}"
    if command -v xvfb-run >/dev/null 2>&1; then
        exec env DOTNET_ROOT="${WIN_DOTNET_ROOT}" DOTNET_ROOT_X64="${WIN_DOTNET_ROOT}" DOTNET_MULTILEVEL_LOOKUP="${DOTNET_MULTILEVEL_LOOKUP}" xvfb-run -a wine "${SBOX_SERVER_EXE}" "${args[@]}"
    fi
    exec env DOTNET_ROOT="${WIN_DOTNET_ROOT}" DOTNET_ROOT_X64="${WIN_DOTNET_ROOT}" DOTNET_MULTILEVEL_LOOKUP="${DOTNET_MULTILEVEL_LOOKUP}" wine "${SBOX_SERVER_EXE}" "${args[@]}"
}

ensure_windows_dotnet_runtime() {
    local win_dotnet_dir="${WINEPREFIX}/drive_c/Program Files/dotnet"
    local hostfxr_path=""
    local nested_root=""
    local runtime_zip="${CONTAINER_HOME}/.cache/dotnet-runtime-${WIN_DOTNET_VERSION}-win-x64.zip"
    local runtime_installer="${CONTAINER_HOME}/.cache/dotnet-runtime-${WIN_DOTNET_VERSION}-win-x64.exe"
    local url_primary="https://dotnetcli.azureedge.net/dotnet/Runtime/${WIN_DOTNET_VERSION}/dotnet-runtime-${WIN_DOTNET_VERSION}-win-x64.zip"
    local url_fallback="https://builds.dotnet.microsoft.com/dotnet/Runtime/${WIN_DOTNET_VERSION}/dotnet-runtime-${WIN_DOTNET_VERSION}-win-x64.zip"
    local installer_url_primary="https://dotnetcli.azureedge.net/dotnet/Runtime/${WIN_DOTNET_VERSION}/dotnet-runtime-${WIN_DOTNET_VERSION}-win-x64.exe"
    local installer_url_fallback="https://builds.dotnet.microsoft.com/dotnet/Runtime/${WIN_DOTNET_VERSION}/dotnet-runtime-${WIN_DOTNET_VERSION}-win-x64.exe"

    hostfxr_path="$(find "${win_dotnet_dir}" -type f -name hostfxr.dll 2>/dev/null | head -n 1 || true)"
    if [ -n "${hostfxr_path}" ]; then
        return 0
    fi

    mkdir -p "${CONTAINER_HOME}/.cache" "${win_dotnet_dir}"

    if [ "${WIN_DOTNET_INSTALL_METHOD}" = "installer" ]; then
        if [ ! -s "${runtime_installer}" ]; then
            echo "info: downloading Windows .NET runtime installer ${WIN_DOTNET_VERSION}" >&2
            if ! wget -qO "${runtime_installer}" "${installer_url_primary}"; then
                if ! wget -qO "${runtime_installer}" "${installer_url_fallback}"; then
                    echo "warn: installer download failed, falling back to zip install" >&2
                    WIN_DOTNET_INSTALL_METHOD="zip"
                fi
            fi
        fi

        if [ "${WIN_DOTNET_INSTALL_METHOD}" = "installer" ]; then
            echo "info: installing Windows .NET runtime ${WIN_DOTNET_VERSION} via installer" >&2
            if command -v xvfb-run >/dev/null 2>&1; then
                xvfb-run -a wine "${runtime_installer}" /install /quiet /norestart >/tmp/dotnet-installer.log 2>&1 || true
            else
                wine "${runtime_installer}" /install /quiet /norestart >/tmp/dotnet-installer.log 2>&1 || true
            fi

            hostfxr_path="$(find "${win_dotnet_dir}" -type f -name hostfxr.dll 2>/dev/null | head -n 1 || true)"
            if [ -n "${hostfxr_path}" ]; then
                echo "info: detected hostfxr at ${hostfxr_path}" >&2
                return 0
            fi

            echo "warn: installer path did not produce hostfxr, falling back to zip install" >&2
            WIN_DOTNET_INSTALL_METHOD="zip"
        fi
    fi

    if [ "${WIN_DOTNET_INSTALL_METHOD}" != "zip" ]; then
        WIN_DOTNET_INSTALL_METHOD="zip"
    fi

    if [ ! -s "${runtime_zip}" ]; then
        echo "info: downloading Windows .NET runtime ${WIN_DOTNET_VERSION}" >&2
        if ! wget -qO "${runtime_zip}" "${url_primary}"; then
            if ! wget -qO "${runtime_zip}" "${url_fallback}"; then
                echo "fatal: unable to download Windows .NET runtime ${WIN_DOTNET_VERSION}" >&2
                return 1
            fi
        fi
    fi

    echo "info: extracting Windows .NET runtime to ${win_dotnet_dir}" >&2
    if ! unzip -qo "${runtime_zip}" -d "${win_dotnet_dir}"; then
        echo "fatal: failed to extract Windows .NET runtime archive" >&2
        return 1
    fi

    # Some archives may extract into a versioned top-level folder.
    if [ ! -d "${win_dotnet_dir}/host" ] && [ -d "${win_dotnet_dir}/dotnet-runtime-${WIN_DOTNET_VERSION}-win-x64" ]; then
        nested_root="${win_dotnet_dir}/dotnet-runtime-${WIN_DOTNET_VERSION}-win-x64"
        find "${nested_root}" -mindepth 1 -maxdepth 1 -exec mv -f {} "${win_dotnet_dir}/" \;
        rmdir "${nested_root}" 2>/dev/null || true
    fi

    hostfxr_path="$(find "${win_dotnet_dir}" -type f -name hostfxr.dll 2>/dev/null | head -n 1 || true)"
    if [ -z "${hostfxr_path}" ]; then
        echo "fatal: Windows .NET runtime extracted but hostfxr.dll still missing" >&2
        return 1
    fi

    echo "info: detected hostfxr at ${hostfxr_path}" >&2
}

ensure_winetricks_dotnet() {
    local marker
    local winetricks_bin
    local verb
    local list_all

    if [ "${INSTALL_WINETRICKS_DOTNET}" != "1" ]; then
        return 0
    fi

    marker="${WINEPREFIX}/.winetricks-dotnet.done"
    if [ -f "${marker}" ]; then
        return 0
    fi

    if [ -x "/usr/local/bin/winetricks" ]; then
        winetricks_bin="/usr/local/bin/winetricks"
    elif command -v winetricks >/dev/null 2>&1; then
        winetricks_bin="$(command -v winetricks)"
    else
        echo "fatal: winetricks not found" >&2
        return 1
    fi

    list_all="$(bash "${winetricks_bin}" list-all 2>/dev/null || true)"

    for verb in ${WINETRICKS_VERBS}; do
        if [ -z "${verb}" ]; then
            continue
        fi

        if ! printf '%s\n' "${list_all}" | awk '{print $1}' | grep -qx "${verb}"; then
            if [ "${WINETRICKS_STRICT}" = "1" ]; then
                echo "fatal: winetricks verb ${verb} not available in current winetricks build" >&2
                return 1
            fi
            echo "warn: winetricks verb ${verb} not available; skipping" >&2
            continue
        fi

        echo "info: running winetricks verb ${verb}" >&2
        if command -v xvfb-run >/dev/null 2>&1; then
            xvfb-run -a env WINEPREFIX="${WINEPREFIX}" HOME="${CONTAINER_HOME}" bash "${winetricks_bin}" -q "${verb}" >/tmp/winetricks-${verb}.log 2>&1 || {
                if [ "${WINETRICKS_STRICT}" = "1" ]; then
                    echo "fatal: winetricks failed for ${verb}; see /tmp/winetricks-${verb}.log" >&2
                    return 1
                fi
                echo "warn: winetricks failed for ${verb}; continuing (WINETRICKS_STRICT=0)" >&2
            }
        else
            env WINEPREFIX="${WINEPREFIX}" HOME="${CONTAINER_HOME}" bash "${winetricks_bin}" -q "${verb}" >/tmp/winetricks-${verb}.log 2>&1 || {
                if [ "${WINETRICKS_STRICT}" = "1" ]; then
                    echo "fatal: winetricks failed for ${verb}; see /tmp/winetricks-${verb}.log" >&2
                    return 1
                fi
                echo "warn: winetricks failed for ${verb}; continuing (WINETRICKS_STRICT=0)" >&2
            }
        fi
    done

    touch "${marker}"
}

if [ ! -f "${WINEPREFIX}/system.reg" ]; then
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
        if [ ! -f "${WINEPREFIX}/system.reg" ]; then
            export HOME="${CONTAINER_HOME}"
            export WINEPREFIX
            export WINEARCH="${WINEARCH:-win64}"

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

if [ "${INSTALL_WIN_DOTNET}" = "1" ]; then
    ensure_windows_dotnet_runtime
fi

ensure_winetricks_dotnet

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
