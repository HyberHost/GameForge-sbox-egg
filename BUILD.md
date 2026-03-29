# Build and Deploy Guide

This guide covers building the image, publishing it, and using it with the included egg.

## 1. Build (Baked Wine Prefix + Windows .NET)

Run from repository root:

```bash
docker build --platform linux/amd64 \
  -f Yolk/DockerFile \
  -t hyberhost/gameforge-sbox-egg:latest \
  --build-arg BAKE_WINEPREFIX=1 \
   --build-arg BAKE_WINETRICKS_VERBS="win10 vcrun2022 dotnet48 dotnet10" \
  --build-arg BAKE_WIN_DOTNET_VERSION=10.0.2 \
  .
```

Optional strict verb enforcement:

```bash
--build-arg BAKE_WINETRICKS_STRICT=1
```

Optional: pre-bake S&Box server files during image build (production style):

```bash
--build-arg BAKE_SBOX_SERVER=1
```

Optional with staging branch:

```bash
--build-arg BAKE_SBOX_SERVER=1 --build-arg BAKE_SBOX_BRANCH=staging
```

## 2. Push to Registry

Example for Docker Hub:

```bash
docker push hyberhost/gameforge-sbox-egg:latest
```

## 3. Import Egg

Import:

- `sandbox-pterodactyl.json`

Ensure egg image points to your pushed tag.

## 4. Recommended Egg Variables

Use these defaults unless troubleshooting:

- `STEAM_PLATFORM=windows`
- `SBOX_AUTO_UPDATE=0` (preferred when server is baked at build time)
- `DOTNET_MULTILEVEL_LOOKUP=0`
- `INSTALL_WINETRICKS_DOTNET=0`
- `INSTALL_WIN_DOTNET=0`

Set one startup mode:

- Package mode: set `GAME` (optional `MAP`)
- Project mode: set `SBOX_PROJECT` to an absolute `.sbproj` path

## 5. Runtime Verification

Successful startup typically includes:

- SteamCMD update/install success for app `1892930`
- No `hostfxr.dll` missing errors
- No CLR internal errors during app launch

## 6. Troubleshooting

If startup still fails:

1. Confirm image tag updated in egg
2. Confirm `STEAM_PLATFORM=windows`
3. Temporarily enable runtime fallback installers:
   - `INSTALL_WINETRICKS_DOTNET=1`
   - `INSTALL_WIN_DOTNET=1`
4. Check startup logs for:
   - Winetricks verb availability
   - hostfxr detection path
   - Wine prefix architecture mismatch warnings

## 7. Notes

- Pterodactyl may run with UID 999 and remapped GID values. The entrypoint allows this behavior.
- Build-time baking is preferred for stability and faster container starts.
