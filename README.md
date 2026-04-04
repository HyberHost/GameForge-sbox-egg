# GameForge S&Box Pterodactyl Egg

This repository contains a Pterodactyl egg and container build assets for running an S&Box dedicated server with Wine.

This is now working in production. We use it to offer S&Box server hosting: [Looking for a server?](https://gameforge.gg/games/sbox)

## Primary Goal

Provide a production-ready Pterodactyl egg that:
- uses `start-sbox` as startup,
- supports common server variables from the panel,
- runs as non-root in container environments,
- seeds runtime files from baked templates (Wine prefix and server template).

## Repository Layout

- `sandbox-pterodactyl.json`: Pterodactyl egg export (import this into your panel).
- `Yolk/DockerFile`: Docker image build for the egg runtime.
- `Yolk/entrypoint.sh`: runtime startup logic.
- `ref/`: reference files used during development. (not in the public repo)

## Pterodactyl Egg Focus

The egg in `sandbox-pterodactyl.json` is the main integration point.

Key details:
- Startup command: `start-sbox`
- Done detection: `Loading game|Server started`
- Main variables:
  - `GAME`
  - `SERVER_NAME`
  - `MAP`
  - `SBOX_PROJECT`
  - `SBOX_EXTRA_ARGS`

## Runtime Behavior

At container start, `Yolk/entrypoint.sh`:
1. Seeds Wine and server files from baked templates if missing.
2. Starts `sbox-server.exe` under Wine with selected startup args.

Project selection precedence:
1. `SBOX_PROJECT` (absolute path, or value resolved under `/home/container/projects`)
2. `GAME` (with optional `MAP`)

When a project target is selected, startup uses `+game <project-target>`.

## Quick Start

1. Build and push image (see `Yolk/README.md`). (Optional: The egg can import our build)
2. Import `sandbox-pterodactyl.json` into Pterodactyl.
3. Select your pushed image in egg settings.
4. Create a server and set variables.
5. Start server.

## Notes

- This repo is tuned for Linux/amd64 container runtime.
- Changes to runtime behavior usually belong in `Yolk/entrypoint.sh`.
- Changes to panel UX and variables belong in `sandbox-pterodactyl.json`.

## Notes for Hosting Providers

While this egg was built for [GameForge](https://gameforge.gg) to sell S&Box, We are more than happy to see other providers use this and are open to pull requests.

