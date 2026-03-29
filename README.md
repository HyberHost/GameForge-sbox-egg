# GameForge S&Box Egg (Pterodactyl)

This repository contains a custom S&Box dedicated server image and egg configuration for Pterodactyl.

The container is designed for non-root runtime and panel compatibility:

- Uses `/home/container` as runtime home
- Supports Pterodactyl user remapping behavior
- Uses Wine to run Windows S&Box dedicated server binaries
- Uses SteamCMD to install/update app `1892930`
- Supports game, map, hostname, token, and local `.sbproj` startup inputs

## Repository Layout

- `Yolk/DockerFile` - Docker image definition
- `Yolk/entrypoint.sh` - runtime startup logic
- `Yolk/bake_wineprefix.sh` - build-time Wine prefix and Windows .NET bake script
- `sandbox-pterodactyl.json` - importable Pterodactyl egg

## Runtime Model

The image is now configured for build-time baked Wine/.NET by default. This reduces startup variance and avoids repeated first-run provisioning.

Default behavior:

- Build bakes Wine prefix and Windows .NET runtime (with `win10`, `vcrun2022`, `dotnet48`, `dotnet10`)
- Runtime does SteamCMD app update and launches S&Box
- Runtime fallback installers are still available via env vars when needed

Optional production behavior:

- Build can also pre-bake S&Box server files (`app 1892930`) using build args, then run with `SBOX_AUTO_UPDATE=0`

## Key Environment Variables

Startup inputs:

- `GAME` - package identifier (for example `facepunch.walker`)
- `MAP` - optional map package identifier
- `HOSTNAME` - server title
- `TOKEN` - optional `+net_game_server_token`
- `SBOX_PROJECT` - optional absolute `.sbproj` path (used instead of `GAME`/`MAP`)
- `SBOX_EXTRA_ARGS` - optional extra CLI arguments

Update and platform:

- `SBOX_AUTO_UPDATE` - `1` or `0`
- `SBOX_BRANCH` - optional Steam beta branch
- `STEAM_PLATFORM` - keep as `windows`

Runtime .NET and prefix controls:

- `DOTNET_MULTILEVEL_LOOKUP` - default `0`
- `INSTALL_WINETRICKS_DOTNET` - runtime fallback toggle (default `0`)
- `INSTALL_WIN_DOTNET` - runtime fallback toggle (default `0`)
- `WINETRICKS_VERBS` - defaults to `dotnet48 dotnet10`
- `WIN_DOTNET_VERSION` - defaults to `10.0.2`

## Pterodactyl Egg

Import `sandbox-pterodactyl.json` into Pterodactyl and ensure the selected image points to your built tag.

Use startup command:

- `start-sbox`

## Build Guide

See `BUILD.md` for full build and deploy steps.
