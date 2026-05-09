---
ur: UR-002
received: 2026-05-10
status: intake
---

# UR-002: User Request

## Request

Runtime errors observed when launching the freshly-built `SystemAudioRecorder.app`:

```
Cannot index window tabs due to missing main bundle identifier
Type: Error | Timestamp: 2026-05-10 08:34:35.900052+10:00 | Process: SystemAudioRecorder | Library: AppKit | Subsystem: com.apple.AppKit | Category: WindowTab | TID: 0x3937c4d

No symbol named '' found in system symbol set
Type: Fault | Timestamp: 2026-05-10 08:34:38.786132+10:00 | Process: SystemAudioRecorder | Library: SwiftUICore | Subsystem: com.apple.SwiftUI | Category: Invalid Configuration | TID: 0x3937c4d

No symbol named '' found in system symbol set
Type: Fault | Timestamp: 2026-05-10 08:34:38.786627+10:00 | Process: SystemAudioRecorder | Library: SwiftUICore | Subsystem: com.apple.SwiftUI | Category: Invalid Configuration | TID: 0x3937c4d

No symbol named '' found in system symbol set
Type: Fault | Timestamp: 2026-05-10 08:34:38.786993+10:00 | Process: SystemAudioRecorder | Library: SwiftUICore | Subsystem: com.apple.SwiftUI | Category: Invalid Configuration | TID: 0x3937c4d

No symbol named '' found in system symbol set
Type: Fault | Timestamp: 2026-05-10 08:34:38.787042+10:00 | Process: SystemAudioRecorder | Library: SwiftUICore | Subsystem: com.apple.SwiftUI | Category: Invalid Configuration | TID: 0x3937c4d

Unable to obtain a task name port right for pid 391: (os/kern) failure (0x5)
Type: Error | Timestamp: 2026-05-10 08:34:39.580461+10:00 | Process: SystemAudioRecorder | Library: BaseBoard | Subsystem: com.apple.BaseBoard | Category: Common | TID: 0x3937fa1

cannot open file at line 51043 of [f0ca7bba1c]
Type: Error | Timestamp: 2026-05-10 08:34:40.007177+10:00 | Process: SystemAudioRecorder | Library: libsqlite3.dylib | Subsystem: com.apple.libsqlite3 | Category: logging-persist | TID: 0x3937c4d

os_unix.c:51043: (2) open(/private/var/db/DetachedSignatures) - No such file or directory
Type: Error | Timestamp: 2026-05-10 08:34:40.007192+10:00 | Process: SystemAudioRecorder | Library: libsqlite3.dylib | Subsystem: com.apple.libsqlite3 | Category: logging-persist | TID: 0x3937c4d
```

Observed after the UR-001 build completed and the user launched the app for the first time.

## Root-cause notes (added during intake triage)

- **Missing bundle identity keys.** The source `Resources/Info.plist` only contains version + permission strings. With `GENERATE_INFOPLIST_FILE: NO`, the built `.app/Contents/Info.plist` lacks `CFBundleIdentifier`, `CFBundleName`, `CFBundleExecutable`, `CFBundlePackageType`. This is the root cause of the "Cannot index window tabs due to missing main bundle identifier" error and likely cascades into the SQLite/DetachedSignatures errors (security frameworks fall back to disk-scanning when bundle ID lookup fails).
  - Fix: add `$(PRODUCT_BUNDLE_IDENTIFIER)`, `$(PRODUCT_NAME)`, `$(EXECUTABLE_NAME)`, `APPL` to `Resources/Info.plist` as build-variable substitutions.
- **Empty SF Symbol fault (×4).** `Image(systemName: "")` is being rendered somewhere — likely in `MenuBarController` or one of the SwiftUI views where an icon name resolves to an empty string. Needs grep + audit.
- **`Unable to obtain a task name port right for pid 391`** — likely AudioSourceCatalog (REQ-006) probing a process that exited or that the app lacks `task_for_pid` access to. May be benign, but worth filtering or downgrading to debug-level log.
