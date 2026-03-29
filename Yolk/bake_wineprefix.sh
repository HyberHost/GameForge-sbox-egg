#!/usr/bin/env bash
set -euo pipefail

CONTAINER_HOME="${CONTAINER_HOME:-/home/container}"
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
WINEARCH="${WINEARCH:-win64}"
BAKE_WINETRICKS_VERBS="${BAKE_WINETRICKS_VERBS:-win10 vcrun2022 dotnet48 dotnet10}"
BAKE_WINETRICKS_STRICT="${BAKE_WINETRICKS_STRICT:-0}"
BAKE_WIN_DOTNET_VERSION="${BAKE_WIN_DOTNET_VERSION:-10.0.2}"

WINETRICKS_BIN="/usr/local/bin/winetricks"
CACHE_DIR="${CONTAINER_HOME}/.cache"
RUNTIME_INSTALLER="${CACHE_DIR}/dotnet-runtime-${BAKE_WIN_DOTNET_VERSION}-win-x64.exe"
INSTALLER_URL_PRIMARY="https://dotnetcli.azureedge.net/dotnet/Runtime/${BAKE_WIN_DOTNET_VERSION}/dotnet-runtime-${BAKE_WIN_DOTNET_VERSION}-win-x64.exe"
INSTALLER_URL_FALLBACK="https://builds.dotnet.microsoft.com/dotnet/Runtime/${BAKE_WIN_DOTNET_VERSION}/dotnet-runtime-${BAKE_WIN_DOTNET_VERSION}-win-x64.exe"

export HOME="${CONTAINER_HOME}"
export WINEPREFIX
export WINEARCH

mkdir -p "${CACHE_DIR}" "${WINEPREFIX}" "${WINEPREFIX}/drive_c/Program Files/dotnet"

# Build-time initialization so runtime startup does not need to create registry/prefix state.
xvfb-run -a wineboot -u >/tmp/wineboot-build.log 2>&1

if [ ! -x "${WINETRICKS_BIN}" ]; then
    echo "fatal: winetricks not available at ${WINETRICKS_BIN}" >&2
    exit 1
fi

list_all="$(bash "${WINETRICKS_BIN}" list-all 2>/dev/null || true)"
for verb in ${BAKE_WINETRICKS_VERBS}; do
    if [ -z "${verb}" ]; then
        continue
    fi

    if ! printf '%s\n' "${list_all}" | awk '{print $1}' | grep -qx "${verb}"; then
        if [ "${BAKE_WINETRICKS_STRICT}" = "1" ]; then
            echo "fatal: build-time winetricks verb ${verb} is unavailable" >&2
            exit 1
        fi
        echo "warn: build-time winetricks verb ${verb} unavailable; skipping" >&2
        continue
    fi

    echo "info: build-time winetricks install ${verb}" >&2
    if ! xvfb-run -a env WINEPREFIX="${WINEPREFIX}" HOME="${CONTAINER_HOME}" bash "${WINETRICKS_BIN}" -q "${verb}" >/tmp/winetricks-build-${verb}.log 2>&1; then
        if [ "${BAKE_WINETRICKS_STRICT}" = "1" ]; then
            echo "fatal: build-time winetricks failed for ${verb}; see /tmp/winetricks-build-${verb}.log" >&2
            exit 1
        fi
        echo "warn: build-time winetricks failed for ${verb}; continuing (BAKE_WINETRICKS_STRICT=0)" >&2
    fi
done

if [ ! -s "${RUNTIME_INSTALLER}" ]; then
    echo "info: downloading build-time Windows .NET runtime installer ${BAKE_WIN_DOTNET_VERSION}" >&2
    if ! wget -qO "${RUNTIME_INSTALLER}" "${INSTALLER_URL_PRIMARY}"; then
        wget -qO "${RUNTIME_INSTALLER}" "${INSTALLER_URL_FALLBACK}"
    fi
fi

echo "info: installing build-time Windows .NET runtime ${BAKE_WIN_DOTNET_VERSION}" >&2
xvfb-run -a wine "${RUNTIME_INSTALLER}" /install /quiet /norestart >/tmp/dotnet-installer-build.log 2>&1 || true

hostfxr_path="$(find "${WINEPREFIX}/drive_c/Program Files/dotnet" -type f -name hostfxr.dll 2>/dev/null | head -n 1 || true)"
if [ -z "${hostfxr_path}" ]; then
    echo "fatal: build-time runtime install completed but hostfxr.dll was not found" >&2
    exit 1
fi

echo "info: build-time hostfxr detected at ${hostfxr_path}" >&2
touch "${WINEPREFIX}/.dotnet-baked"
wineserver -k >/dev/null 2>&1 || true
