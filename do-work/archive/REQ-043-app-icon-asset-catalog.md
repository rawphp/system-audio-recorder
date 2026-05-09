# REQ-043: Add App Icon Asset Catalog

**UR:** UR-003
**Status:** done
**Created:** 2026-05-10
**Layer:** supporting

## Task

Bundle `rsa-icon.png` (500×500 PNG at the repo root) as the SystemAudioRecorder app icon by creating an `Assets.xcassets/AppIcon.appiconset` under `Resources/` containing the standard macOS icon sizes, wiring the asset catalog into `project.yml`, and setting `ASSETCATALOG_COMPILER_APPICON_NAME` to `AppIcon` so the icon appears in Finder, Dock, and Cmd-Tab.

## Context

User request UR-003: "add this icon to this app: /Users/tomkaczocha/EA/projects/system-audio-to-mp3/rsa-icon.png".

Project currently has no asset catalog (`find . -name "*.xcassets"` returns nothing) and `project.yml` has no `ASSETCATALOG_COMPILER_APPICON_NAME` entry. macOS apps render an icon when the build produces `Assets.car` containing an `AppIcon` entry; the standard layout is `Resources/Assets.xcassets/AppIcon.appiconset/` with PNGs at 16, 32, 64, 128, 256, 512, 1024 px (1x and 2x variants per size where applicable) and a `Contents.json` declaring them.

Source `rsa-icon.png` is 500×500 RGBA — must be resized via `sips` to each required size. macOS `AppIcon.appiconset` standard sizes:

| idiom | size | scale | filename |
|---|---|---|---|
| mac | 16x16 | 1x | icon_16x16.png (16) |
| mac | 16x16 | 2x | icon_16x16@2x.png (32) |
| mac | 32x32 | 1x | icon_32x32.png (32) |
| mac | 32x32 | 2x | icon_32x32@2x.png (64) |
| mac | 128x128 | 1x | icon_128x128.png (128) |
| mac | 128x128 | 2x | icon_128x128@2x.png (256) |
| mac | 256x256 | 1x | icon_256x256.png (256) |
| mac | 256x256 | 2x | icon_256x256@2x.png (512) |
| mac | 512x512 | 1x | icon_512x512.png (512) |
| mac | 512x512 | 2x | icon_512x512@2x.png (1024) |

`Resources/` is already declared as a target source path in `project.yml`, so the asset catalog will be picked up automatically once placed there.

## Acceptance Criteria

- [x] `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` exists and declares all 10 standard macOS sizes (16/32/128/256/512 at 1x and 2x).
- [x] All 10 PNG files are present in the appiconset, sized correctly (verified with `sips -g pixelWidth -g pixelHeight`).
- [x] `project.yml` sets `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in the SystemAudioRecorder target's base settings.
- [x] `make build` succeeds and the produced `.app` bundle contains `Assets.car` with an AppIcon entry (verified via `assetutil --info` on `Contents/Resources/Assets.car`).
- [ ] Launching the built `.app` shows the rsa-icon in the Dock and Cmd-Tab switcher (not the generic placeholder icon). _(Pending visual confirmation by user — Assets.car contains AppIcon renditions at all 10 sizes and AppIcon.icns is in the bundle.)_
- [x] Source `rsa-icon.png` moved to `Resources/AppIconSource.png` as the master — no loose file at repo root.

## Verification Steps

1. **build** `make generate && make build`
   - Expected: build succeeds with no errors. Output settings show `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.
2. **runtime** Inspect the built bundle: `assetutil --info $(find ~/Library/Developer/Xcode/DerivedData/SystemAudioRecorder-*/Build/Products/Debug -name 'Assets.car' | head -1)`
   - Expected: output contains an entry whose `Name` is `AppIcon` with rendition data for each declared size.
3. **ui** Launch via `make run`, then check the Dock tile and Cmd-Tab switcher.
   - Expected: the running app shows the rsa-icon (red/black SF-symbols-style icon visible in `rsa-icon.png`), not the default placeholder. Take a screenshot of the Dock for evidence.
4. **runtime** `sips -g pixelWidth -g pixelHeight Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png`
   - Expected: pixelWidth: 1024, pixelHeight: 1024.

## Integration

**Reachability:** The icon is reached automatically by macOS through the app bundle — no code path. Build pipeline reaches it via `Resources/` (already declared as a target source in `project.yml:38`) plus the new `ASSETCATALOG_COMPILER_APPICON_NAME` build setting that tells `actool` which catalog entry to compile as the primary app icon.

**Data dependencies:** Reads `rsa-icon.png` (currently at repo root, will be relocated as the source master inside `Resources/Assets.xcassets/AppIcon.appiconset/` or kept beside the appiconset as the original). Writes the 10 derived PNGs and `Contents.json` into the appiconset. No runtime data, no models, no persisted state.

**Service dependencies:** Depends on `xcodegen` (used by `make generate`, see `Makefile:21-22`) to translate the new `project.yml` setting into `.xcodeproj`, and on Xcode's `actool` to compile the catalog into `Assets.car` at build time. No app-runtime services involved.

## Assets

- `Resources/AppIconSource.png` — 500×500 RGBA source icon (master), downscaled into the appiconset.

## Outputs

- `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` — appiconset manifest declaring 10 macOS sizes
- `Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png` — 10 generated PNG variants (16→1024 px)
- `Resources/Assets.xcassets/Contents.json` — asset catalog root manifest
- `Resources/AppIconSource.png` — relocated source master (was `rsa-icon.png` at repo root)
- `project.yml` — adds `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` to SystemAudioRecorder target
