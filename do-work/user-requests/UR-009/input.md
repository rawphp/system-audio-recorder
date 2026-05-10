---
ur: UR-009
received: 2026-05-10
status: intake
---

# UR-009: User Request

## Request

I want to release this app for free via github... what is the best setup for this project?
what files should not be included in git?

[Follow-up: "all 3" — referring to the three actions the assistant offered:]

1. Write the `.gitignore` and remove the tracked files that shouldn't be (`xcuserstate`, optionally `.xcodeproj/` and `do-work/`).
2. Add an MIT `LICENSE`.
3. Sketch a release GitHub Actions workflow.

## Context from prior assistant analysis (for reference, not part of the brief)

Current state observed:
- No `.gitignore` exists.
- `UserInterfaceState.xcuserstate` is committed.
- `do-work/` (internal task system) is currently tracked.
- No `LICENSE` file.
- No secrets/keys committed.
- `Vendor/lame.xcframework` (724K) is fine to keep — build dependency, LAME licenses already in folder.

Two decisions surfaced for the user:
1. Track `.xcodeproj` or not? — xcodegen with `project.yml` is source of truth; assistant recommended not tracking the generated `.xcodeproj`.
2. Keep `do-work/` public? — assistant recommended gitignoring it.

Recommended `.gitignore` proposed:

```
# macOS
.DS_Store

# Xcode user state
**/xcuserdata/
*.xcuserstate
*.xcworkspace/xcuserdata/

# Xcode build output
build/
DerivedData/
*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration/

# Xcodegen-generated project (project.yml is source of truth)
SystemAudioRecorder.xcodeproj/

# SwiftPM
.swiftpm/
.build/
Package.resolved

# Release artifacts
dist/
*.dmg
*.app
*.zip

# Signing — never commit
*.p12
*.cer
*.mobileprovision
ExportOptions.plist
.env
.env.*

# Tooling
.claude/
do-work/
```

Additional recommendations made for free GitHub release:
- Add MIT or Apache-2.0 LICENSE (LAME is LGPL — already bundled, that's correct).
- Use GitHub Releases for the notarized DMG.
- Sketch a release GitHub Actions workflow that runs `scripts/release.sh` on tag push, with signing certs as encrypted secrets.
- README "Download" section pointing at Releases, plus "Building from source" with `brew install xcodegen` + `make build`.
