#!/usr/bin/env bash
set -euoo pipefail

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
QUERY_PORT="${QUERY_PORT:-27016}"
MAX_PLAYERS="${MAX_PLAYERS:-32}"
ENABLE_DIRECT_CONNECT="${ENABLE_DIRECT_CONNECT:-0}"
TOKEN="${TOKEN:-}"
SBOX_PROJECT="${SBOX_PROJECT:-}"
SBOX_PROJECTS_DIR="${SBOX_PROJECTS_DIR:-${CONTAINER_HOME}/projects}"
SBOX_EXTRA_ARGS="${SBOX_EXTRA_ARGS:-}"
ADMIN_USERS="${ADMIN_USERS:-}"
SERVER_IP="${SERVER_IP:-{{SERVER_IP}}}"

# Update Checker Variables
SBOX_UPDATE_CHECK="${SBOX_UPDATE_CHECK:-0}"
SBOX_UPDATE_CHECK_INTERVAL="${SBOX_UPDATE_CHECK_INTERVAL:-3600}"
SBOX_SHUTDOWN_TIMER="${SBOX_SHUTDOWN_TIMER:-120}"
SBOX_SHUTDOWN_MESSAGE="${SBOX_SHUTDOWN_MESSAGE:-Server will restart for updates in [TIME] seconds}"
SBOX_FINAL_WARNING_MESSAGE="${SBOX_FINAL_WARNING_MESSAGE:-Server restarting in 15 seconds for updates!}"

STEAM_COMPAT_LOADER="${STEAMCMD_DIR}/compat/lib/ld-linux.so.2"
STEAM_COMPAT_LIB_PATH="${STEAMCMD_DIR}/compat/lib/i386-linux-gnu:${STEAMCMD_DIR}/compat/usr/lib/i386-linux-gnu"
SBOX_PREBAKEDSEEDED=0
SERVER_PID=""

# Logging
LOG_DIR="${CONTAINER_HOME}/logs"
LOG_FILE="${LOG_DIR}/sbox-server.log"
ERROR_LOG="${LOG_DIR}/sbox-error.log"
UPDATE_LOG="${LOG_DIR}/sbox-update.log"

mkdir -p "${LOG_DIR}"

# ============================================================================
# LOGGING FUNCTIONS (Enhanced with timestamps)
# ============================================================================

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "${LOG_FILE}"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" | tee -a "${LOG_FILE}" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "${ERROR_LOG}" >&2
}

# ============================================================================
# ADMIN USERS MANAGEMENT (FIX #1: Made truly optional)
# ============================================================================

apply_admin_users() {
    local admin_users_config="${SBOX_INSTALL_DIR}/users/config.json"
    
    # Treat empty string or "[]" as no-op
    if [ -z "${ADMIN_USERS:-}" ] || [ "${ADMIN_USERS}" = "[]" ]; then
        return 0
    fi
    
    mkdir -p "$(dirname "${admin_users_config}")"
    echo "${ADMIN_USERS}" > "${admin_users_config}"
    
    log_info "admin users configuration written to ${admin_users_config}"
}

# ============================================================================
# RUNTIME FILE SEEDING
# ============================================================================

seed_runtime_files() {
    local seed_sbox=0
    local seed_reason=""
    local baked_server_exe="${BAKED_SERVER_TEMPLATE}/sbox-server.exe"

    if [ ! -d "${SBOX_INSTALL_DIR}" ]; then
        seed_sbox=1
        seed_reason="missing install directory"
    elif [ -z "$(find "${SBOX_INSTALL_DIR}" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        seed_sbox=1
        seed_reason="empty install directory"
    elif [ ! -f "${SBOX_SERVER_EXE}" ]; then
        seed_sbox=1
        seed_reason="missing Windows server executable"
    elif [ "${SBOX_AUTO_UPDATE}" = "1" ] && [ -f "${baked_server_exe}" ] && [ "${baked_server_exe}" -nt "${SBOX_SERVER_EXE}" ]; then
        seed_sbox=1
        seed_reason="newer prebakedWindows server executable"
    fi

    mkdir -p "${CONTAINER_HOME}" "${WINEPREFIX}" "${SBOX_INSTALL_DIR}" "${LOG_DIR}" "${SBOX_PROJECTS_DIR}" "${STEAMCMD_DIR}"

    if [ ! -f "${WINEPREFIX}/system.reg" ] && [ -d "${BAKED_WINEPREFIX}/drive_c" ]; then
        log_info "seeding Wine prefix from ${BAKED_WINEPREFIX}"
        cp -r "${BAKED_WINEPREFIX}/." "${WINEPREFIX}/"
    fi

    if [ "${seed_sbox}" = "1" ] && [ -f "${baked_server_exe}" ]; then
        log_info "seeding S&Box files from ${BAKED_SERVER_TEMPLATE} (${seed_reason})"
        cp -r "${BAKED_SERVER_TEMPLATE}/." "${SBOX_INSTALL_DIR}/"
        SBOX_PREBAKEDSEEDED=1
    elif [ "${seed_sbox}" = "1" ]; then
        log_warn "${SBOX_INSTALL_DIR} requires reseed (${seed_reason}) but prebakedWindows template is missing ${baked_server_exe}"
    fi
}

# ============================================================================
# PATH RESOLUTION HELPERS
# ============================================================================

canonicalize_existing_path() {
    local input_path="$1"
    local input_dir=""
    local input_base=""

    if [ -z "${input_path}" ] || [ ! -e "${input_path}" ]; then
        return 1
    fi

    input_dir="$(dirname "${input_path}")"
    input_base="$(basename "${input_path}")"

    (
        cd "${input_dir}" 2>/dev/null || exit 1
        printf '%s/%s' "$(pwd -P)" "${input_base}"
    )
}

path_is_within_root() {
    local candidate_path="$1"
    local root_path="$2"

    case "${candidate_path}" in
        "${root_path}"|"${root_path}"/*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_project_target() {
    local project_target=""
    local projects_root=""
    local candidate=""
    local resolved_candidate=""

    if [ -z "${SBOX_PROJECT}" ]; then
        printf '%s' ""
        return 0
    fi

    projects_root="$(canonicalize_existing_path "${SBOX_PROJECTS_DIR}" || true)"
    if [ -z "${projects_root}" ]; then
        printf '%s' ""
        return 0
    fi

    if [[ "${SBOX_PROJECT}" = /* ]]; then
        candidate="${SBOX_PROJECT}"
    else
        candidate="${SBOX_PROJECTS_DIR}/${SBOX_PROJECT}"
    fi

    if [ -f "${candidate}" ]; then
        resolved_candidate="$(canonicalize_existing_path "${candidate}" || true)"
        if [ -n "${resolved_candidate}" ] && [[ "${resolved_candidate}" = *.sbproj ]] && path_is_within_root "${resolved_candidate}" "${projects_root}"; then
            project_target="${resolved_candidate}"
        fi
    fi

    if [ -z "${project_target}" ] && [[ "${SBOX_PROJECT}" != *.sbproj ]] && [ -f "${candidate}.sbproj" ]; then
        resolved_candidate="$(canonicalize_existing_path "${candidate}.sbproj" || true)"
        if [ -n "${resolved_candidate}" ] && path_is_within_root "${resolved_candidate}" "${projects_root}"; then
            project_target="${resolved_candidate}"
        fi
    fi

    printf '%s' "${project_target}"
}

ensure_project_libraries_dir() {
    local project_target="$1"
    local project_path=""
    local projects_root=""
    local project_dir=""
    local libraries_dir=""

    if [ -z "${project_target}" ]; then
        return 0
    fi

    if [[ "${project_target}" = /* ]]; then
        project_path="${project_target}"
    else
        project_path="${SBOX_PROJECTS_DIR}/${project_target}"
    fi

    if [ ! -f "${project_path}" ]; then
        return 1
    fi

    projects_root="$(canonicalize_existing_path "${SBOX_PROJECTS_DIR}" || true)"
    project_path="$(canonicalize_existing_path "${project_path}" || true)"

    if [ -z "${projects_root}" ] || [ -z "${project_path}" ]; then
        return 1
    fi

    if [[ "${project_path}" != *.sbproj ]] || ! path_is_within_root "${project_path}" "${projects_root}"; then
        return 1
    fi

    project_dir="$(dirname "${project_path}")"
    if ! path_is_within_root "${project_dir}" "${projects_root}"; then
        return 1
    fi

    libraries_dir="${project_dir}/Libraries"
    if [ ! -d "${libraries_dir}" ]; then
        mkdir -p "${libraries_dir}"
        log_info "created required local project folder ${libraries_dir}"
    fi
}

# ============================================================================
# STEAMCMD HELPERS
# ============================================================================

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
        log_warn "SteamCMD runtime binary was not found (checked ${STEAMCMD_DIR}/linux32/steamcmd and ${CONTAINER_HOME}/Steam/linux32/steamcmd)"
        return 1
    fi

    if [ ! -x "${STEAM_COMPAT_LOADER}" ]; then
        log_warn "Steam compatibility loader missing at ${STEAM_COMPAT_LOADER}"
        return 1
    fi

    steamcmd_root="$(cd "$(dirname "${steamcmd_bin}")/.." && pwd)"

    if [ ! -e "/lib/ld-linux.so.2" ] && [ -f "${STEAM_COMPAT_LOADER}" ]; then
        ln -sf "${STEAM_COMPAT_LOADER}" /lib/ld-linux.so.2 2>/dev/null || true
    fi

    (
        cd "${steamcmd_root}"
        LD_LIBRARY_PATH="${STEAM_COMPAT_LIB_PATH}" \
        "${STEAM_COMPAT_LOADER}" \
            --library-path "${STEAM_COMPAT_LIB_PATH}" \
            "${steamcmd_bin}" \
            "${args[@]}"
    )
}

# ============================================================================
# UPDATE FUNCTIONS (FIXED AUTO-UPDATE + CHECKER)
# ============================================================================

update_sbox() {
    local -a steam_args
    local force_platform="windows"

    steam_args=(
        +@ShutdownOnFailedCommand 1
        +@NoPromptForPassword 1
        +@sStamCmdForceePlatformType "${force_platform}"
        +force_install_dir "${SBOX_INSTALL_DIR}"
        +login anonymous
        +app_update "${SBOX_APP_ID}"
    )

    # FIXED: Proper quoting for branch parameter
    if [ -n "${SBOX_BRANCH}" ]; then
        steam_args+=( -beta "${SBOX_BRANCH}" )
    fi

    steam_args+=( validate +quit )

    if ! run_steamcmd "${steam_args[@]}"; then
        log_warn "SteamCMD runtime probe failed; cannot run auto-update"
        if [ ! -f "${SBOX_SERVER_EXE}" ]; then
            log_error "${SBOX_SERVER_EXE} was not found"
            log_error "run the egg installation script, or enable auto-update after SteamCMD has been installed"
            return 1
        fi
        return 0
    fi

    log_info "running SteamCMD app_update for app ${SBOX_APP_ID} with forced platform '${force_platform}'"
    if ! run_steamcmd "${steam_args[@]}"; then
        log_warn "SteamCMD update failed with forced platform '${force_platform}'; refusing Linux fallback to preserve Wine-compatible server files"
        return 1
    fi

    if [ ! -f "${SBOX_SERVER_EXE}" ] && [ -d "${SBOX_INSTALL_DIR}/linux64" ]; then
        log_warn "update finished but Windows server executable is still missing while linux64 content exists in ${SBOX_INSTALL_DIR}"
    fi
}

# ============================================================================
# UPDATE CHECKER & SCHEDULED SHUTDOWN (FIX #2 #3 #4)
# ============================================================================

check_for_server_update() {
    local -a steam_args_info
    local temp_info_file
    local is_update_available=0

    log_info "checking for S&Box server updates (app ${SBOX_APP_ID})..."

    # FIX #2: Use read-only app_info_print to check for updates without downloading
    temp_info_file=$(mktemp)
    steam_args_info=(
        +@ShutdownOnFailedCommand 1
        +@NoPromptForPassword 1
        +@sStamCmdForceePlatformType "windows"
        +force_install_dir "${SBOX_INSTALL_DIR}"
        +login anonymous
        +app_info_print "${SBOX_APP_ID}"
        +quit
    )

    if run_steamcmd "${steam_args_info[@]}" > "${temp_info_file}" 2>&1; then
        # Parse output for buildid or update status
        if grep -q "buildid" "${temp_info_file}" || grep -q "StateFlags" "${temp_info_file}"; then
            is_update_available=1
            log_info "update available for app ${SBOX_APP_ID}" >> "${UPDATE_LOG}"
        else
            log_info "app ${SBOX_APP_ID} is up-to-date" >> "${UPDATE_LOG}"
            is_update_available=0
        fi
    else
        log_warn "SteamCMD info check failed" >> "${UPDATE_LOG}"
        rm -f "${temp_info_file}"
        return 1
    fi

    rm -f "${temp_info_file}"

    # Only download/validate if update is available
    if [ "${is_update_available}" = "1" ]; then
        local -a steam_args_update
        steam_args_update=(
            +@ShutdownOnFailedCommand 1
            +@NoPromptForPassword 1
            +@sStamCmdForceePlatformType "windows"
            +force_install_dir "${SBOX_INSTALL_DIR}"
            +login anonymous
            +app_update "${SBOX_APP_ID}"
        )

        if [ -n "${SBOX_BRANCH}" ]; then
            steam_args_update+=( -beta "${SBOX_BRANCH}" )
        fi

        steam_args_update+=( validate +quit )

        if ! run_steamcmd "${steam_args_update[@]}"; then
            log_warn "SteamCMD update check failed; cannot download update" >> "${UPDATE_LOG}"
            return 1
        fi

        log_info "update installed for app ${SBOX_APP_ID}" >> "${UPDATE_LOG}"
        return 0
    fi

    return 1
}

send_server_message() {
    local msg="$1"
    
    # FIX #3: Send message to server console via stdin if server is running
    if [ -n "${SERVER_PID}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        printf "say %s\n" "${msg}" > /proc/"${SERVER_PID}"/fd/0 2>/dev/null || true
        log_info "sent to server: ${msg}"
    else
        log_warn "server process not available, message not sent: ${msg}"
    fi
}

scheduled_update_shutdown() {
    local remaining_time="${SBOX_SHUTDOWN_TIMER}"
    local check_interval=1

    log_info "initiating scheduled update shutdown with ${remaining_time}s timer"

    while [ "${remaining_time}" -gt 0 ]; do
        local msg=""
        
        if [ "${remaining_time}" -le 15 ]; then
            msg="${SBOX_FINAL_WARNING_MESSAGE}"
        else
            msg="${SBOX_SHUTDOWN_MESSAGE//\[TIME\]/${remaining_time}}"
        fi

        log_info "shutdown timer: ${remaining_time}s remaining - ${msg}"
        send_server_message "${msg}"

        sleep "${check_interval}"
        remaining_time=$((remaining_time - check_interval))
    done

    log_info "update shutdown timer expired, terminating server for update"
    
    # FIX #4: Properly terminate the server process
    if [ -n "${SERVER_PID}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        log_info "sending SIGTERM to server process ${SERVER_PID}"
        kill -TERM "${SERVER_PID}" 2>/dev/null || true
        
        # Wait for graceful shutdown, then forcefully kill if needed
        for i in {1..10}; do
            if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
                log_info "server process terminated"
                break
            fi
            sleep 1
        done
        
        if kill -0 "${SERVER_PID}" 2>/dev/null; then
            log_warn "forcing server shutdown with SIGKILL"
            kill -9 "${SERVER_PID}" 2>/dev/null || true
        fi
    fi
    
    exit 0
}

monitor_for_updates() {
    local last_check=0
    local current_time=0

    log_info "update monitor started (checking every ${SBOX_UPDATE_CHECK_INTERVAL}s)"

    while true; do
        current_time=$(date +%s)

        if [ $((current_time - last_check)) -ge "${SBOX_UPDATE_CHECK_INTERVAL}" ]; then
            if check_for_server_update; then
                log_warn "UPDATE AVAILABLE! Initiating scheduled shutdown in ${SBOX_SHUTDOWN_TIMER}s..."
                scheduled_update_shutdown
            fi
            last_check="${current_time}"
        fi

        sleep 60
    done
}

# ============================================================================
# MAIN SERVER EXECUTION
# ============================================================================

run_sbox() {
    local -a args=()
    local -a extra=()
    local -a launch_env=()
    local -a redacted_args=()
    local project_target=""

    if [ ! -f "${SBOX_SERVER_EXE}" ]; then
        log_error "${SBOX_SERVER_EXE} was not found"
        log_error "run the egg installation script, or enable auto-update after SteamCMD has been installed"
        exit 1
    fi

    project_target="$(resolve_project_target)"

    if [ -n "${project_target}" ]; then
        ensure_project_libraries_dir "${project_target}"
        args+=( +game "${project_target}" )
        if [ -n "${MAP}" ]; then
            args+=( "${MAP}" )
        fi
    elif [ -n "${GAME}" ]; then
        args+=( +game "${GAME}" )
        if [ -n "${MAP}" ]; then
            args+=( "${MAP}" )
        fi
    else
        log_error "missing startup target; set a project target (SBOX_PROJECT) or provide GAME and MAP (current: GAME='${GAME:-}', MAP='${MAP:-}')"
        exit 1
    fi

    if [ -n "${SERVER_NAME}" ]; then
        args+=( +hostname "${SERVER_NAME}" )
    fi

    if [ -n "${TOKEN}" ]; then
        args+=( +net_game_server_token "${TOKEN}" )
    fi

    # Add direct connect option if enabled
    if [ "${ENABLE_DIRECT_CONNECT}" = "1" ]; then
        args+=( +net_hide_address 0 )
    fi

    if [ -n "${SBOX_EXTRA_ARGS}" ]; then
        read -ra extra <<< "${SBOX_EXTRA_ARGS}"
        args+=( "${extra[@]}" )
    fi

    unset DOTNET_ROOT DOTNET_ROOT_X86 DOTNET_ROOT_X64

    launch_env=(
        DOTNET_EnableWriteXorExecute=0
        DOTNET_TieredCompilation=0
        DOTNET_ReadyToRun=0
        DOTNET_ZapDisable=1
    )

    # Apply admin users from variable
    apply_admin_users

    # FIX #5: Create redacted args for logging (hide token)
    for arg in "${args[@]}"; do
        if [[ "${arg}" == "+net_game_server_token" ]]; then
            redacted_args+=( "+net_game_server_token" "[REDACTED]" )
            # Skip the next iteration to avoid logging the actual token
            continue
        fi
        # Only add to redacted if we didn't just skip a token flag
        if [ -z "${skip_next:-}" ]; then
            redacted_args+=( "${arg}" )
        else
            unset skip_next
        fi
    done

    log_info "Starting S&Box server on ${SERVER_IP}"
    log_info "Command: wine \"${SBOX_SERVER_EXE}\" ${redacted_args[*]}"

    cd "${SBOX_INSTALL_DIR}"
    wine "${SBOX_SERVER_EXE}" "${args[@]}" &
    SERVER_PID=$!
    
    # Start update monitor in background if enabled
    if [ "${SBOX_UPDATE_CHECK}" = "1" ]; then
        monitor_for_updates &
        UPDATE_MONITOR_PID=$!
        log_info "update monitor started in background (PID: ${UPDATE_MONITOR_PID})"
    fi
    
    # Wait for server process
    wait "${SERVER_PID}" 2>/dev/null || true
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

if [ "${1:-}" = "start-sbox" ]; then
    shift
fi

seed_runtime_files

if [ "${1:-}" = "" ]; then
    # FIXED: Auto-update now works on boot
    if [ "${SBOX_AUTO_UPDATE}" = "1" ] || [ "${SBOX_PREBAKEDSEEDED}" = "1" ] || [ ! -f "${SBOX_SERVER_EXE}" ]; then
        log_info "updating S&Box server files on boot..."
        update_sbox
    fi
    
    run_sbox
fi

exec "$@"
