# System Audio to MP3 — Design Spec

**Date**: 2026-05-09
**Status**: Approved, ready for implementation planning
**Target**: macOS 14.4+ (Sonoma)
**Distribution**: Notarized direct download (Developer ID, no sandbox)

---

## 1. Problem & Goal

Recording macOS system audio to MP3 currently requires extra software (BlackHole, Soundflower, Loopback, Audio Hijack) and several setup steps that confuse non-technical users. We're building a single, signed, notarized macOS app that lets a user record system audio (and optionally microphone) to MP3 with no virtual audio devices, no driver installs, and minimal decisions.

**Core requirement**: simple to use. Hide complexity. A first-time user should be able to make a recording without making any choices.

---

## 2. Decisions Locked In

| Area | Decision |
|---|---|
| Form factor | Full GUI macOS app, SwiftUI window + menu bar status item |
| Audio sources | Per-app picker, system-wide presets, optional microphone mix |
| Output structure | Per session: single mixed MP3 (default) OR separate MP3 per source |
| OS minimum | macOS 14.4 (uses Core Audio Tap APIs introduced in 14.4) |
| Encoding pipeline | Record 32-bit float WAV during session; encode WAV → MP3 after Stop on a background queue |
| Distribution | Developer ID signed + notarized, direct download. **Not** Mac App Store. |
| Capture engine | Pure Core Audio Tap (`CATapDescription` + `AudioHardwareCreateProcessTap`). No ScreenCaptureKit, no virtual audio device. |
| Session features | Pause/resume, live level meters, per-source gain (in advanced view), global hotkey, background encoding on stop, auto-stop on duration or silence |
| Default mic state | OFF — system audio only |

---

## 3. Module Architecture

The app is split into a UI layer, an orchestration layer, and an audio engine layer that has zero SwiftUI dependencies and is unit-testable headlessly.

| Module | Responsibility | Depends on |
|---|---|---|
| `AudioSourceCatalog` | Enumerates running audio-emitting processes; refresh on demand. | CoreAudio HAL |
| `ProcessTapCapture` | Creates/destroys a Core Audio Tap for selected PIDs; emits PCM buffers per source. | CoreAudio, AVFoundation |
| `MicrophoneCapture` | Wraps `AVAudioEngine` input node for the chosen mic device. | AVFoundation |
| `MixerGraph` | Per-source gain, mix bus, level-meter taps, separate-output taps. | AVFoundation |
| `WAVWriter` | Streams one or many `AVAudioFile`s during a session. | AVFoundation |
| `RecordingSession` | Orchestrates a session: start/pause/resume/stop, auto-stop, holds settings. | All audio modules |
| `LameEncoder` | Wraps bundled libmp3lame; encodes WAV → MP3, reports progress. | LAME (vendored) |
| `EncodingQueue` | Background `OperationQueue` draining pending WAV → MP3 jobs after Stop. | LameEncoder |
| `PermissionManager` | Requests/checks microphone + Core Audio Tap entitlements. | AVFoundation |
| `HotkeyManager` | Global shortcut → toggle session. | `KeyboardShortcuts` SPM package |
| `MenuBarController` | NSStatusItem with state-driven icon and dropdown menu. | AppKit, AppStore |
| `AppStore` (`@Observable`) | Top-level state: current session, source list, settings, encoding jobs. | All of the above |
| Views | `SourcePickerView`, `MixerPanelView`, `RecordControlsView`, `OutputSettingsView`, `EncodingJobsView`, `ContentView`. | `AppStore` |

**Why this split**: rows 1–9 have no SwiftUI dependencies, so they're testable with a synthetic PCM source. The UI is a thin reactive layer over `AppStore`.

**External dependencies (SPM)**: `KeyboardShortcuts` (Sindre Sorhus) for the global hotkey. LAME is vendored as a static `.xcframework` (universal arm64 + x86_64) built once from canonical lame-3.100 source — checked into the repo so notarization is reproducible.

---

## 4. UX

### 4.1 Default screen

```
┌──────────────────────────────────────────┐
│  System Audio Recorder              ⚙︎   │
│                                          │
│  Recording from:  Everything       ⌄     │
│                                          │
│       ┌──────────────────────────┐       │
│       │  ●  Start Recording      │       │
│       └──────────────────────────┘       │
│                                          │
│  ▁▂▃▄▅▆ ───────────────  -12 dB           │
└──────────────────────────────────────────┘
```

One source dropdown, one big button, one unified level meter. Most users never need to leave this view.

### 4.2 Source dropdown options

- **Everything** *(default — all system audio, no mic)*
- Everything + Mic
- Microphone only
- Specific app… *(opens app picker)*
- Advanced… *(opens multi-source mixer panel)*

### 4.3 Recording state

```
┌──────────────────────────────────────────┐
│       ┌──────────────────────────┐       │
│       │  ⏸  Pause     ■  Stop    │       │
│       └──────────────────────────┘       │
│  ▁▂▃▄▅▆▇█▇▆▅▄▃▂                          │
│  00:03:42                                │
└──────────────────────────────────────────┘
```

### 4.4 After Stop

A single toast: `Saved → ~/Music/Recordings/2026-05-09 19-42.mp3` with a Reveal button. If encoding is still running, the toast says *"Encoding…"* and updates in place.

### 4.5 Menu bar status item

Three icon states (distinct shapes — not just colors — for accessibility):
- **Idle**: outlined waveform glyph (template image)
- **Recording**: filled red dot + small waveform
- **Paused**: filled outlined dot

Menu while recording:

```
●  Recording — 00:03:42
─────────────────────────
⏸  Pause
■  Stop
─────────────────────────
Source: Everything ▸
─────────────────────────
Open Window…
Settings…
─────────────────────────
Quit
```

While idle, the top section becomes `▶ Start Recording` plus the source preset picker.

A `Show in Dock` setting (default ON) lets the user run the app as menu-bar-only by flipping `NSApp.setActivationPolicy(.accessory)` at runtime.

### 4.6 Where complex features hide

| Feature | Lives in |
|---|---|
| Per-source gain sliders + per-source meters | "Advanced…" mixer panel only |
| Mixed-vs-separate output | Settings ⚙︎ → defaults to "one mixed file" |
| MP3 bitrate | Settings ⚙︎ → defaults to 192 kbps VBR |
| Auto-stop (duration/silence) | Optional toggle inside source dropdown's expanded view, off by default |
| Global hotkey | Settings ⚙︎ → unset by default |
| Output folder | Settings ⚙︎ → defaults to `~/Music/Recordings` |

### 4.7 Permission UX

- Requested **lazily** on first record attempt — never on launch.
- Mic prompt fires only when the chosen source involves the mic.
- Audio-tap entitlement check fires only when system audio is involved.
- A user who only ever uses "Microphone only" never sees the audio-tap prompt; the default user (Everything) never sees the mic prompt.

---

## 5. Audio Capture & Data Flow

### 5.1 Per-process system audio (Core Audio Tap)

1. `AudioSourceCatalog` polls `kAudioHardwarePropertyProcessObjectList` to enumerate audio-emitting processes (pid, bundle id, display name, icon). Refresh fires when the dropdown opens.
2. On record start, `ProcessTapCapture` builds a `CATapDescription` with the chosen PIDs and `.unmuted` mode (audio is captured without muting playback to the user's speakers). It calls `AudioHardwareCreateProcessTap`, then creates a private aggregate device that aggregates the tap. An `AUHAL` audio unit on that aggregate device delivers PCM via a render callback.
3. Buffers (typically 48 kHz Float32 stereo) are posted to a lockless ring buffer, then pulled into `AVAudioEngine` via an `AVAudioSourceNode` — one source node per tapped process so separate-output mode preserves per-source streams.

### 5.2 Microphone (when enabled)

`AVAudioEngine.inputNode` chained through its own `AVAudioPlayerNode` path. Selected device comes from `AVCaptureDevice` enumeration; set on the engine input.

### 5.3 Mixer graph

```
[tap source 1] ─┐
[tap source 2] ─┤── per-source gain ── per-source meter ─┐
[mic input]    ─┘                                          │
                                                           ▼
                                                     [mix node] ── mix meter
                                                           │
                                                           ├──→ AVAudioFile (mix.wav)
                                                           │
                                                           └─[separate-mode only]
                                                              ├→ source1.wav
                                                              ├→ source2.wav
                                                              └→ mic.wav
```

Per-source gain: `AVAudioMixerNode` with `outputVolume` from the UI slider (or fixed at 1.0 in simple mode). Meters: 50 Hz UI updates from `installTap(onBus:)` — the audio thread writes RMS values into a lockless ring buffer; a main-thread `Timer` drains it and updates `@Observable` state.

### 5.4 Format normalization

Every source is resampled to a single common format (48 kHz, Float32, stereo) at its source node before reaching the mixer. WAV files are written at the same 48 kHz Float32. No format-mismatch surprises mid-session.

### 5.5 Pause / resume

`RecordingSession.pause()` calls `engine.pause()` and freezes WAV file cursors. Resume re-attaches and continues — output WAV is one continuous file with the paused gap removed (no silent fill). Auto-stop timers freeze during pause.

### 5.6 Auto-stop

- **Duration**: `DispatchSourceTimer` set on session start; cancelled on stop/pause; recreated on resume with remaining time.
- **Silence**: separate tap on the mix node computes a 200 ms RMS window. If it stays below −60 dBFS for the user-configured threshold (default 30 s), `RecordingSession.stop()` is called from the main queue. Skipped during the first 2 s of recording so we don't trip before any audio arrives.

### 5.7 Stop → encoding handoff

`session.stop()` synchronously: stops the engine, closes WAV files, enqueues an `EncodingJob` per WAV → MP3 pair on `EncodingQueue`. UI returns instantly with the toast. `LameEncoder` reads the WAV in 1 s chunks, feeds `lame_encode_buffer_ieee_float`, finalizes with `lame_encode_flush`. Setting (default ON): delete WAV after successful encode.

### 5.8 Known technical risks

1. **Tapped process dies mid-recording** — the tap silently goes quiet. Mitigation: poll process aliveness on a 1 Hz timer; on death, post a non-fatal warning ("Spotify quit — recording continues with remaining sources").
2. **Sample rate drift** when an app changes its output rate mid-stream. Mitigation: recreate the AUHAL render format on `kAudioDevicePropertyNominalSampleRate` change. Dedicated test required.
3. **Audio-input entitlement prompt wording** — needs a clear `NSAudioCaptureUsageDescription` in Info.plist. Final wording reviewed against current macOS 14.4+ system prompt phrasing during implementation.

---

## 6. Output, Settings & Errors

### 6.1 File naming

- Mixed mode: `~/Music/Recordings/2026-05-09 19-42-08.mp3`
- Separate mode adds source suffix: `2026-05-09 19-42-08 - Spotify.mp3`, `… - Mic.mp3`, `… - Mix.mp3`
- Date-time stamp at session start, second precision (collision-proof for solo use)

### 6.2 Settings storage

`UserDefaults` under suite `com.tomkaczocha.SystemAudioRecorder`. Persisted keys:

| Key | Default | Notes |
|---|---|---|
| `outputFolderBookmark` | `~/Music/Recordings` (security-scoped bookmark) | First save offers inline "Change folder" link |
| `bitrate` | 192 kbps | |
| `bitrateMode` | VBR | CBR/VBR |
| `outputMode` | mixed | mixed / separate |
| `keepWAVAfterEncode` | false | |
| `hotkey` | unset | Single global shortcut |
| `lastSourcePreset` | "Everything" | |
| `micDeviceID` | system default | |
| `showInDock` | true | |
| `autoStopDurationSeconds` | nil (off) | |
| `autoStopSilenceSeconds` | nil (off) | |

### 6.3 Error surfaces

The audio engine layer throws typed errors (`CaptureError`, `EncodingError`); the orchestration layer maps each to one UI surface.

| Severity | UI | Examples |
|---|---|---|
| Fatal — recording cannot continue | Modal alert with "Try Again" + "Open System Settings" | Mic permission denied, audio-tap entitlement denied |
| Non-fatal — recording continues | Inline warning banner in recording window, dismissible | Tapped app quit mid-session; one source's resample failed (drops that source, continues others) |
| Background (post-stop) | Toast | Encoding failed → keeps the WAV, surfaces "Encoding failed — WAV preserved at …" with Reveal |

### 6.4 Crash safety

WAV files are flushed every 1 s during recording. On unclean shutdown, an unfinalized WAV is detected on next launch; the app offers to repair its header and encode it ("Recover unfinished recording from May 9?"). Session metadata is stored as a sidecar JSON next to the WAV during recording.

### 6.5 Permission failure paths

- **Mic denied**: dropdown options that need mic are disabled with "Mic access denied — Open Settings" affordance.
- **Audio-tap denied**: all options except "Microphone only" are disabled with the same affordance.
- **MDM blocks tap APIs**: caught at start; modal explains and offers fallback to mic-only.

---

## 7. Testing

The audio engine layer (modules 1–9) has no UI dependencies, so it tests headlessly.

1. **Unit tests** (XCTest): `LameEncoder` (encode known sine WAVs at multiple bitrates; verify file size + decoded waveform vs source within tolerance), `WAVWriter` (header correctness, multi-second writes, pause/resume continuity), silence detection (synthetic buffers — silent, loud, mixed), file naming, settings persistence, format normalization.
2. **Integration tests**: `RecordingSession` driven by a `MockAudioSource` conforming to the same buffer-emitter protocol as `ProcessTapCapture`/`MicrophoneCapture`. Full start → pause → resume → stop → encode flows in CI without real audio devices.
3. **Manual test plan** (`docs/manual-tests.md`): Core Audio Tap against Spotify/Safari, mic capture, permission prompts, sample-rate drift, target-app-quits-mid-recording. Run before each release.

CI: GitHub Actions, macOS-14 runner, layers 1 & 2 on every push. Layer 3 gated by release checklist.

---

## 8. Non-Goals (v1)

- ❌ Editing recordings (trim, fade, effects) — users use other tools
- ❌ Cloud upload, share sheet, transcoding to other formats post-hoc
- ❌ Multi-channel surround beyond stereo
- ❌ Routing recorded audio back to a virtual output (we do not replace BlackHole)
- ❌ Automation / AppleScript / URL scheme — possible v2 addition
- ❌ Cross-Mac sync of recordings or settings

---

## 9. Project Layout

```
system-audio-to-mp3/
├── App/
│   ├── SystemAudioToMP3App.swift      # SwiftUI @main
│   ├── AppStore.swift                 # @Observable top-level state
│   ├── MenuBar/
│   │   └── MenuBarController.swift    # NSStatusItem + dropdown menu
│   └── Views/
│       ├── ContentView.swift
│       ├── SourcePickerView.swift
│       ├── MixerPanelView.swift       # Advanced multi-source view
│       ├── RecordControlsView.swift
│       ├── OutputSettingsView.swift
│       └── EncodingJobsView.swift
├── AudioEngine/                       # Pure-Swift, no UI
│   ├── Capture/
│   │   ├── AudioSourceCatalog.swift
│   │   ├── ProcessTapCapture.swift
│   │   └── MicrophoneCapture.swift
│   ├── Mixer/
│   │   └── MixerGraph.swift
│   ├── Recording/
│   │   ├── RecordingSession.swift
│   │   └── WAVWriter.swift
│   └── Encoding/
│       ├── LameEncoder.swift
│       └── EncodingQueue.swift
├── Permissions/
│   └── PermissionManager.swift
├── Hotkey/
│   └── HotkeyManager.swift
├── Resources/
│   ├── Info.plist
│   ├── SystemAudioToMP3.entitlements
│   └── Assets.xcassets
├── Vendor/
│   └── lame.xcframework/              # Bundled libmp3lame
├── Tests/
│   ├── AudioEngineTests/
│   └── IntegrationTests/
├── docs/
│   ├── superpowers/specs/             # This spec
│   └── manual-tests.md
├── Package.swift                      # SPM: KeyboardShortcuts
└── SystemAudioToMP3.xcodeproj
```

---

## 10. Estimated Scope

Solo developer estimate, calendar weeks: **6–8 weeks** to a shippable v1 (covering all features above plus notarization, manual test pass, and a basic landing page). Plausible compression options if needed: drop auto-stop (saves ~3 days), drop pause/resume (saves ~5 days), drop separate-output mode (saves ~3 days). All features confirmed in scope at design time.

---

## 11. Next Step

Hand off to the `writing-plans` skill to produce an increment-by-increment implementation plan that respects the module boundaries above.
