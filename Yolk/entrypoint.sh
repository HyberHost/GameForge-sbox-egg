#!/usr/bin/env bash
set -euo pipefail

EXPECTED_UID="${PUID:-999}"
EXPECTED_GID="${PGID:-$(id -g)}"
CONTAINER_HOME="${CONTAINER_HOME:-/home/container}"
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
# Pre-baked Wine prefix inside the image; not subject to Pterodactyl's
# /home/container volume mount, so it is always accessible at startup.
BAKED_WINEPREFIX="${SBOX_BAKED_WINEPREFIX:-/opt/sbox-wine-prefix}"
LOCK_DIR="${WINEPREFIX}/.init-lock"
SBOX_INSTALL_DIR="${SBOX_INSTALL_DIR:-/home/container/sbox}"
SBOX_SERVER_EXE="${SBOX_SERVER_EXE:-${SBOX_INSTALL_DIR}/sbox-server.exe}"
SBOX_APP_ID="${SBOX_APP_ID:-1892930}"
SBOX_AUTO_UPDATE="${SBOX_AUTO_UPDATE:-0}"
SBOX_BRANCH="${SBOX_BRANCH:-}"
STEAM_PLATFORM="${STEAM_PLATFORM:-windows}"
RESET_WINEPREFIX_ON_ARCH_MISMATCH="${RESET_WINEPREFIX_ON_ARCH_MISMATCH:-1}"
INSTALL_WINETRICKS_DOTNET="${INSTALL_WINETRICKS_DOTNET:-0}"
WINETRICKS_VERBS="${WINETRICKS_VERBS:-win10 vcrun2022 dotnet48 dotnet10}"
WINETRICKS_STRICT="${WINETRICKS_STRICT:-0}"
INSTALL_WIN_DOTNET="${INSTALL_WIN_DOTNET:-0}"
WIN_DOTNET_VERSION="${WIN_DOTNET_VERSION:-10.0.0}"
WIN_DOTNET_INSTALL_METHOD="${WIN_DOTNET_INSTALL_METHOD:-installer}"
WIN_DOTNET_ROOT="${WIN_DOTNET_ROOT:-C:\\Program Files\\dotnet}"
DOTNET_MULTILEVEL_LOOKUP="${DOTNET_MULTILEVEL_LOOKUP:-0}"
SBOX_WINEDEBUG="${SBOX_WINEDEBUG:-${WINEDEBUG:--all}}"
GAME="${GAME:-}"
MAP="${MAP:-}"
SERVER_NAME="${HOSTNAME:-}"
TOKEN="${TOKEN:-}"
SBOX_PROJECT="${SBOX_PROJECT:-}"
SBOX_EXTRA_ARGS="${SBOX_EXTRA_ARGS:-}"
SBOX_USE_XVFB="${SBOX_USE_XVFB:-0}"
SBOX_DEBUG_LOGGING="${SBOX_DEBUG_LOGGING:-0}"
SBOX_TRACE_STRACE="${SBOX_TRACE_STRACE:-0}"
SBOX_PURGE_CACHE="${SBOX_PURGE_CACHE:-0}"

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

# On the first start with a fresh Pterodactyl volume, the Wings daemon
# bind-mounts the server data directory over /home/container, hiding anything
# that was baked into that path in the image layer.  The pre-baked Wine prefix
# is stored at BAKED_WINEPREFIX (/opt/sbox-wine-prefix), which is outside the
# volume mount and always accessible.  Copy it into WINEPREFIX once.
if [ ! -f "${WINEPREFIX}/system.reg" ] && [ -d "${BAKED_WINEPREFIX}/drive_c" ]; then
    echo "info: first run — copying pre-initialized Wine prefix from ${BAKED_WINEPREFIX} into ${WINEPREFIX}..." >&2
    cp -a "${BAKED_WINEPREFIX}/." "${WINEPREFIX}/"
    echo "info: Wine prefix copied and ready." >&2
elif [ -f "${WINEPREFIX}/system.reg" ]; then
    echo "info: Wine prefix already initialized at ${WINEPREFIX}" >&2
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

verify_dotnet_runtime() {
    local win_dotnet_dir="${WINEPREFIX}/drive_c/Program Files/dotnet"
    local hostfxr_path
    local clrcore_path
    
    echo "info: verifying Windows .NET runtime in Wine prefix..." >&2
    echo "  WINEPREFIX: ${WINEPREFIX}" >&2
    echo "  WINEARCH: ${WINEARCH}" >&2
    echo "  WIN_DOTNET_VERSION: ${WIN_DOTNET_VERSION}" >&2
    
    # Check for hostfxr.dll
    hostfxr_path="$(find "${win_dotnet_dir}" -type f -name hostfxr.dll 2>/dev/null | head -n 1 || true)"
    if [ -z "${hostfxr_path}" ]; then
        echo "warn: hostfxr.dll not found in ${win_dotnet_dir}; S&Box may fail with CLR errors" >&2
        echo "info: attempting to search entire WINEPREFIX..." >&2
        hostfxr_path="$(find "${WINEPREFIX}" -type f -name hostfxr.dll 2>/dev/null | head -n 1 || true)"
        if [ -n "${hostfxr_path}" ]; then
            echo "info: found hostfxr at: ${hostfxr_path}" >&2
        else
            echo "error: hostfxr.dll not found anywhere in WINEPREFIX" >&2
        fi
    else
        echo "ok: found hostfxr at: ${hostfxr_path}" >&2
    fi
    
    # Check for coreclr.dll
    clrcore_path="$(find "${WINEPREFIX}" -type f -name coreclr.dll 2>/dev/null | head -n 1 || true)"
    if [ -n "${clrcore_path}" ]; then
        echo "ok: found coreclr at: ${clrcore_path}" >&2
    else
        echo "error: coreclr.dll not found; CLR initialization will fail" >&2
    fi
    
    # Check for mscoree.dll
    local mscoree_path
    mscoree_path="$(find "${WINEPREFIX}" -type f -name mscoree.dll 2>/dev/null | head -n 1 || true)"
    if [ -n "${mscoree_path}" ]; then
        echo "ok: found mscoree at: ${mscoree_path}" >&2
    else
        echo "warn: mscoree.dll not found" >&2
    fi
    
    # List what's actually in the Wine .NET directory
    if [ -d "${win_dotnet_dir}" ]; then
        echo "info: Windows .NET directory contents:" >&2
        ls -la "${win_dotnet_dir}" 2>&1 | head -30 | sed 's/^/  /' >&2
    else
        echo "warn: Windows .NET directory does not exist: ${win_dotnet_dir}" >&2
        echo "info: searching for dotnet installations in WINEPREFIX:" >&2
        find "${WINEPREFIX}/drive_c" -maxdepth 3 -type d \( -name dotnet -o -name '.dotnet' \) 2>/dev/null | sed 's/^/  /' >&2
    fi
    
    # Check Wine version
    echo "info: Wine version:" >&2
    wine --version 2>&1 | sed 's/^/  /' >&2
    
    # Check if S&Box can at least load
    echo "info: checking S&Box executable..." >&2
    if [ -f "${SBOX_SERVER_EXE}" ]; then
        ls -lh "${SBOX_SERVER_EXE}" 2>&1 | sed 's/^/  /' >&2
        echo "warn: S&Box built for this .NET version? Check runtimes.json if present" >&2
        if [ -f "${SBOX_INSTALL_DIR}/runtimes.json" ]; then
            echo "info: runtimes.json (required .NET version):" >&2
            cat "${SBOX_INSTALL_DIR}/runtimes.json" 2>/dev/null | head -10 | sed 's/^/    /' >&2
        fi
        if [ -f "${SBOX_INSTALL_DIR}/.dotnet-version" ]; then
            echo "info: .dotnet-version file:" >&2
            cat "${SBOX_INSTALL_DIR}/.dotnet-version" 2>/dev/null | sed 's/^/    /' >&2
        fi
    fi
}

purge_sbox_cache() {
    local target
    local -a purge_targets

    if [ "${SBOX_PURGE_CACHE}" != "1" ]; then
        return 0
    fi

    purge_targets=(
        "${SBOX_INSTALL_DIR}/addons/menu/.bin"
        "${SBOX_INSTALL_DIR}/addons/base/.bin"
        "${CONTAINER_HOME}/data/.source2"
        "${CONTAINER_HOME}/data/.shadercache"
        "${WINEPREFIX}/drive_c/users/${USER:-container}/AppData/Local/Facepunch"
        "${WINEPREFIX}/drive_c/users/${USER:-container}/AppData/Roaming/Facepunch"
        "${WINEPREFIX}/drive_c/users/${USER:-container}/Temp"
    )

    echo "info: purging S&Box caches (SBOX_PURGE_CACHE=1)" >&2
    for target in "${purge_targets[@]}"; do
        if [ -e "${target}" ]; then
            echo "  purge: ${target}" >&2
            rm -rf "${target}" || true
        fi
    done
}

log_suspicious_directories() {
    local dir_path
    local -a dirs

    dirs=(
        "${SBOX_INSTALL_DIR}/addons/menu/.bin"
        "${SBOX_INSTALL_DIR}/addons/base/.bin"
        "${CONTAINER_HOME}/data"
        "${WINEPREFIX}/drive_c/users/${USER:-container}/AppData/Local/Facepunch"
        "${WINEPREFIX}/drive_c/users/${USER:-container}/AppData/Roaming/Facepunch"
    )

    echo "info: suspicious directory snapshot" >&2
    for dir_path in "${dirs[@]}"; do
        if [ -d "${dir_path}" ]; then
            echo "  dir=${dir_path}" >&2
            find "${dir_path}" -maxdepth 2 -mindepth 1 2>/dev/null | head -n 25 | sed 's/^/    /' >&2 || true
        fi
    done
}

log_suspicious_artifacts() {
    local report_limit="${SBOX_MANAGED_REPORT_LIMIT:-40}"
    local file_path
    local size
    local hash

    echo "info: suspicious artifact scan (limit=${report_limit})" >&2
    shopt -s nullglob globstar
    for file_path in \
        "${SBOX_INSTALL_DIR}"/addons/*/.bin/*.dll \
        "${SBOX_INSTALL_DIR}"/addons/*/.bin/*.pdb \
        "${SBOX_INSTALL_DIR}"/addons/*/.bin/*.deps.json \
        "${SBOX_INSTALL_DIR}"/addons/*/.bin/*.runtimeconfig.json \
        "${CONTAINER_HOME}"/data/**/*.dll \
        "${CONTAINER_HOME}"/data/**/*.pdb \
        "${WINEPREFIX}"/drive_c/users/${USER:-container}/AppData/Local/Facepunch/**/*.dll \
        "${WINEPREFIX}"/drive_c/users/${USER:-container}/AppData/Roaming/Facepunch/**/*.dll; do
        if [ ! -f "${file_path}" ]; then
            continue
        fi
        size="$(stat -c '%s' "${file_path}" 2>/dev/null || echo 0)"
        hash="$(sha256sum "${file_path}" 2>/dev/null | awk '{print $1}' || echo unavailable)"
        echo "  file=${file_path} size=${size} sha256=${hash}" >&2
        report_limit=$((report_limit - 1))
        if [ "${report_limit}" -le 0 ]; then
            break
        fi
    done
    shopt -u nullglob globstar

    find "${SBOX_INSTALL_DIR}" "${CONTAINER_HOME}/data" "${WINEPREFIX}/drive_c/users/${USER:-container}/AppData" -type f -size 0 2>/dev/null \
        | head -n 20 | sed 's/^/  zero-byte: /' >&2 || true

    return 0
}

run_sbox() {
    local -a args
    local -a extra
    local log_file="${1:-}"
    local -a launch_env
    local -a launch_cmd
    local rc

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

    # Strip Linux .NET env vars so Wine chooses runtime paths like the dxura image.
    unset DOTNET_ROOT DOTNET_ROOT_X86 DOTNET_ROOT_X64

    # If no log file provided, create one
    if [ -z "${log_file}" ]; then
        local timestamp="$(date +%Y%m%d-%H%M%S)"
        mkdir -p "${CONTAINER_HOME}/logs"
        log_file="${CONTAINER_HOME}/logs/sbox-server-${timestamp}.log"
    fi

    cd "${SBOX_INSTALL_DIR}"
    
    # Log startup info
    {
        echo "=== S&Box Server Starting at $(date -u) ==="
        echo "SBOX_INSTALL_DIR: ${SBOX_INSTALL_DIR}"
        echo "SBOX_SERVER_EXE: ${SBOX_SERVER_EXE}"
        echo "WINEPREFIX: ${WINEPREFIX}"
        echo "WINEARCH: ${WINEARCH:-win64}"
        echo "SBOX_WINEDEBUG: ${SBOX_WINEDEBUG}"
        echo "Container IPs: $(hostname -I 2>/dev/null || echo unknown)"
        echo "SBOX_USE_XVFB: ${SBOX_USE_XVFB}"
        echo "SBOX_DEBUG_LOGGING: ${SBOX_DEBUG_LOGGING}"
        echo "SBOX_TRACE_STRACE: ${SBOX_TRACE_STRACE}"
        echo "SBOX_PURGE_CACHE: ${SBOX_PURGE_CACHE}"
        echo "Game: ${GAME:-none}"
        echo "Map: ${MAP:-none}"
        echo "Server Name: ${SERVER_NAME:-none}"
        echo "Extra Args: ${SBOX_EXTRA_ARGS:-none}"
        echo "=== OUTPUT START ==="
    } >> "${log_file}"

    # Route all subsequent stdout/stderr to both console and the timestamped log.
    exec > >(tee -a "${log_file}") 2>&1

    launch_env=(
        WINEDEBUG="${SBOX_WINEDEBUG}"
        WINE_CPU_TOPOLOGY=2:2
        WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-icu,icuuc=d}"
    )

    if [ "${SBOX_DEBUG_LOGGING}" = "1" ]; then
        echo "info: debug snapshot: routes" >&2
        ip route 2>/dev/null || true
        echo "info: debug snapshot: interfaces" >&2
        ip -br address 2>/dev/null || true
        echo "info: debug snapshot: resolv.conf" >&2
        cat /etc/resolv.conf 2>/dev/null || true
        log_suspicious_directories
        log_suspicious_artifacts
    fi

    # Capture the real process exit code even with `set -e` enabled globally.
    set +e
    if [ "${SBOX_USE_XVFB}" = "1" ] && command -v xvfb-run >/dev/null 2>&1; then
        echo "info: launching with xvfb-run (SBOX_USE_XVFB=1)" >&2
        if [ "${SBOX_TRACE_STRACE}" = "1" ] && command -v strace >/dev/null 2>&1; then
            echo "info: tracing with strace (-ff -tt) to ${CONTAINER_HOME}/logs/strace-sbox" >&2
            launch_cmd=(strace -ff -tt -s 256 -o "${CONTAINER_HOME}/logs/strace-sbox" xvfb-run -a wine "${SBOX_SERVER_EXE}" "${args[@]}")
            env "${launch_env[@]}" "${launch_cmd[@]}"
        else
            env "${launch_env[@]}" xvfb-run -a wine "${SBOX_SERVER_EXE}" "${args[@]}"
        fi
        rc=$?
    else
        echo "info: launching without xvfb-run (dxura-style headless wine)" >&2
        if [ "${SBOX_TRACE_STRACE}" = "1" ] && command -v strace >/dev/null 2>&1; then
            echo "info: tracing with strace (-ff -tt) to ${CONTAINER_HOME}/logs/strace-sbox" >&2
            launch_cmd=(strace -ff -tt -s 256 -o "${CONTAINER_HOME}/logs/strace-sbox" wine "${SBOX_SERVER_EXE}" "${args[@]}")
            env "${launch_env[@]}" "${launch_cmd[@]}"
        else
            env "${launch_env[@]}" wine "${SBOX_SERVER_EXE}" "${args[@]}"
        fi
        rc=$?
    fi
    set -e

    if [ "${rc}" -ge 128 ]; then
        echo "fatal: sbox-server terminated by signal $((rc - 128)) (exit ${rc})" >&2
    fi
    echo "fatal: sbox-server exited with code ${rc}" >&2
    exit "${rc}"
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
purge_sbox_cache

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

    # Create a timestamped log file from the start
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    LOGS_DIR="${CONTAINER_HOME}/logs"
    mkdir -p "${LOGS_DIR}"
    DIAG_LOG="${LOGS_DIR}/sbox-server-${TIMESTAMP}.log"
    
    # Run diagnostics and capture to log file
    {
        echo "=== S&Box Runtime Diagnostics at $(date -u) ==="
        echo ""
        verify_dotnet_runtime
        echo ""
        echo "=== Starting Server ==="
    } >> "${DIAG_LOG}" 2>&1
    
    # Now run S&Box with the same log file
    run_sbox "${DIAG_LOG}"
fi

exec "$@"
