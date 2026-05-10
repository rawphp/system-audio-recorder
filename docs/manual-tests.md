# Manual Test Plan — System Audio to MP3

> **Scope**: Layer 3 manual verification tests (per spec Section 7). CI covers unit and integration layers automatically. These tests require physical hardware, a signed build, and real audio sources. Run this checklist before each release candidate.
>
> **Build to test**: a Developer ID-signed `.app` from `make build` or a notarized DMG (where noted).
>
> **Recording output location**: `~/Music/Recordings/` (default).

---

## MT-001: Real Core Audio Tap — Spotify (5 min)

**Goal**: Verify end-to-end capture of per-process system audio from a real streaming app.

### Setup

1. Install Spotify from https://www.spotify.com and sign in.
2. Open the System Audio to MP3 app.
3. Confirm the app launched without a Gatekeeper warning.
4. Open the source dropdown. Verify "Specific app…" appears.
5. Click "Specific app…" and confirm Spotify appears in the picker list.

### Steps

1. Select **Spotify** in the app picker. Dismiss the picker.
2. Start a Spotify playlist (at least 5 minutes of continuous music).
3. Click **Start Recording** in the app.
4. Confirm the level meter is active (non-zero movement).
5. Confirm the recording timer increments (`00:00:01`, `00:00:02`, …).
6. Let the recording run for **5 minutes** without pausing.
7. Click **Stop**.
8. Wait for the post-stop toast to change from *"Encoding…"* to *"Saved → ~/Music/Recordings/…mp3"*.
9. Click **Reveal** in the toast.
10. Open the MP3 in QuickTime Player. Verify playback duration is approximately 5:00 (±5 s).

### Pass Criteria

- [ ] Level meter is non-zero throughout the recording.
- [ ] Timer counts up continuously for 5 minutes without freezing.
- [ ] Toast appears on Stop; transitions from "Encoding…" to "Saved → …" within 60 s.
- [ ] MP3 file exists at the revealed path.
- [ ] MP3 plays back with clearly audible Spotify audio (no silence, no corruption, no dropout gaps).
- [ ] MP3 duration is between 4:55 and 5:05.

### Fail Criteria

- Level meter is stuck at zero throughout.
- Recording timer freezes or resets.
- App crashes or hangs on Stop.
- Output MP3 is silent, unplayable, or shorter than 4:50.

---

## MT-002: Real Core Audio Tap — Safari / YouTube (5 min)

**Goal**: Verify tap capture works against a browser rendering HTML5 audio.

### Setup

1. Open Safari.
2. Navigate to any YouTube video that is at least 5 minutes long. Start playback and confirm you hear audio from your Mac's speakers.
3. Open the System Audio to MP3 app.
4. Open the source dropdown and click "Specific app…".

### Steps

1. Confirm **Safari** appears in the app picker. Select it and dismiss the picker.
2. Click **Start Recording** in the app.
3. Confirm the level meter is active.
4. Let the recording run for **5 minutes** without pausing or switching tabs.
5. Click **Stop**.
6. Wait for the toast to show *"Saved → ~/Music/Recordings/…mp3"*.
7. Open the MP3 in QuickTime Player.

### Pass Criteria

- [ ] Safari appears in the source picker (confirms `AudioSourceCatalog` picks up browser processes).
- [ ] Level meter is non-zero throughout.
- [ ] Output MP3 plays back with clearly audible YouTube audio.
- [ ] MP3 duration is between 4:55 and 5:05.
- [ ] No other apps' audio bleeds into the recording (pause Spotify before this test and confirm it is inaudible in the output).

### Fail Criteria

- Safari does not appear in the source picker.
- Output MP3 is silent or contains audio from unselected apps.
- App crashes on Stop.

---

## MT-003: Microphone Capture — Built-in Mic Then External USB Mic

**Goal**: Verify microphone capture works with two different mic devices and that device switching is reflected without a restart.

### Setup

1. Ensure your Mac's built-in microphone is not muted in **System Settings → Sound → Input**.
2. Have a USB microphone available to plug in mid-test.
3. Open the System Audio to MP3 app.
4. In the source dropdown, select **Microphone only**.

### Steps — Part A (Built-in Mic)

1. Confirm the source label shows "Microphone only".
2. Click **Start Recording**.
3. Speak a test phrase clearly into the built-in mic: *"Built-in mic test one two three."*
4. Confirm the level meter responds to your voice.
5. Click **Stop**.
6. Wait for the toast to show *"Saved → ~/Music/Recordings/…mp3"*.
7. Open the MP3 in QuickTime Player. Confirm your spoken phrase is audible.

### Steps — Part B (USB Mic)

1. Plug in the USB microphone.
2. Open **System Settings → Sound → Input** and verify the USB mic is listed.
3. Return to the System Audio to MP3 app.
4. Open Settings (⚙︎) and change the input device to the USB mic. Close Settings.
5. Click **Start Recording**.
6. Speak a test phrase into the USB mic: *"USB mic test four five six."*
7. Confirm the level meter responds.
8. Click **Stop** and wait for the saved toast.
9. Open the MP3 in QuickTime Player. Confirm your spoken phrase is audible.

### Pass Criteria

- [ ] Part A: built-in mic audio is audible in the MP3.
- [ ] Part A: level meter responds to voice during recording.
- [ ] Part B: Settings allows selecting the USB mic by name.
- [ ] Part B: USB mic audio is audible in the MP3 without restarting the app.
- [ ] Neither recording contains system audio bleed (play music from another app during both tests; verify it is absent in output).

### Fail Criteria

- Level meter does not move when speaking.
- Recorded phrase is inaudible or silent.
- App requires a full restart to switch mic device.

---

## MT-004: First-Launch Permission Prompts (Mic + Audio Tap)

**Goal**: Verify that permission prompts are shown at the right time, with the right sequence, and not on cold launch.

### Setup

1. Delete any existing System Audio to MP3 consent records:
   ```
   tccutil reset Microphone com.yourcompany.SystemAudioRecorder
   tccutil reset ListenEvent com.yourcompany.SystemAudioRecorder
   ```
   *(Replace bundle ID with the actual bundle identifier in the signed build's Info.plist.)*
2. Quit and relaunch the app from Finder.

### Steps — Audio Tap Prompt

1. Confirm **no system dialog** appears on launch.
2. In the source dropdown, select **Everything** (default).
3. Click **Start Recording**.
4. Observe: a macOS permission dialog appears requesting audio capture access.
5. Click **Allow**.
6. Confirm recording starts (timer increments, level meter is active).
7. Click **Stop**.

### Steps — Mic Prompt

1. In the source dropdown, select **Everything + Mic**.
2. Click **Start Recording**.
3. Observe: a macOS permission dialog appears requesting microphone access.
4. Click **Allow**.
5. Confirm recording starts.
6. Click **Stop**.

### Pass Criteria

- [ ] No permission prompt appears on cold launch.
- [ ] Audio-tap prompt appears on first record attempt with a system-audio source.
- [ ] Mic prompt appears only when a mic source is first selected and record is pressed — not before.
- [ ] After granting both permissions, subsequent recordings start immediately with no further prompts.

### Fail Criteria

- Any permission prompt appears before the user clicks Start Recording.
- The app requests mic permission when "Everything" (no mic) is selected.
- The app crashes or hangs after the user grants permissions.

---

## MT-005: Permission Denial Paths — Deny Mic, Observe UX (REQ-034)

**Goal**: Verify that the app handles a denied microphone permission gracefully with a clear error banner and actionable recovery path.

### Setup

1. Reset mic permission for the app:
   ```
   tccutil reset Microphone com.yourcompany.SystemAudioRecorder
   ```
2. Relaunch the app.
3. In the source dropdown, select **Everything + Mic**.

### Steps

1. Click **Start Recording**.
2. When the microphone permission dialog appears, click **Don't Allow**.
3. Observe the app UI immediately after denial.
4. Confirm an error banner or alert is visible in the app window.
5. Read the error message text.
6. Click the **Open System Settings** (or equivalent) button shown in the banner.
7. Confirm System Settings opens to **Privacy & Security → Microphone**.
8. Toggle the app's microphone permission **ON** in System Settings.
9. Return to the app.
10. Click **Start Recording** again.
11. Confirm recording starts without a further permission prompt.

### Pass Criteria

- [ ] An error banner is displayed immediately after denial (not a crash).
- [ ] The banner clearly states microphone access was denied (no vague error text).
- [ ] The banner contains a button or link that opens System Settings directly to the Microphone privacy pane.
- [ ] After granting permission in System Settings and returning, the user can start recording without restarting the app.
- [ ] Deny the audio-tap permission (repeat steps above with "Everything" source, deny the audio-tap dialog). Confirm a similar banner is shown specific to audio capture.

### Fail Criteria

- App crashes on permission denial.
- No error message is shown — the app silently fails to record.
- The Open System Settings button does not navigate to the correct pane.
- Granting permission in System Settings still requires an app restart to take effect.

---

## MT-006: Sample Rate Drift — Track Switch Mid-Recording

**Goal**: Verify that the recording continues seamlessly when the system-level audio sample rate changes mid-session (e.g., switching between a 44.1 kHz track and a 48 kHz track).

### Setup

1. Locate two audio files at **different sample rates**: one at 44,100 Hz and one at 48,000 Hz. Import both into iTunes/Music or QuickTime. Confirm sample rates by selecting the file in Finder → Get Info.
2. Open the System Audio to MP3 app.
3. Select source: **Everything**.

### Steps

1. Click **Start Recording**.
2. Begin playback of the 44,100 Hz audio file in Music app.
3. Let it play for **30 seconds** while watching the level meter (should show activity).
4. Without stopping the recording, stop the 44.1 kHz track and immediately start the 48,000 Hz track.
5. Let it play for another **30 seconds**.
6. Click **Stop** in the recorder.
7. Wait for the saved toast.
8. Open the output MP3 in QuickTime Player.

### Pass Criteria

- [ ] The recording does not crash or stop when the sample rate switches.
- [ ] The level meter remains active after the track switch (no freeze).
- [ ] The output MP3 plays as one continuous file — no hard cuts, no silence gap, no corruption at the switch point (~0:30 mark).
- [ ] Both the 44.1 kHz and 48 kHz audio portions are audible in the output MP3.
- [ ] Total MP3 duration is approximately 60 seconds (±5 s).

### Fail Criteria

- App crashes or stops recording at the sample rate switch point.
- Output MP3 has a gap, silence, or corruption at the ~0:30 mark.
- Output MP3 contains only one of the two tracks.

---

## MT-007: Target App Quits Mid-Recording — Warning Banner + Recording Continues

**Goal**: Verify that killing a tapped app mid-recording triggers a visible warning and that the recording continues for remaining sources.

### Setup

1. Open Spotify and start a playlist.
2. Open the System Audio to MP3 app.
3. In the source dropdown, select "Specific app…" and pick **Spotify**.
4. Also add your Mac's built-in mic or a second source if you want to verify the remaining source continues. *(Alternatively, use "Everything" as the source so the recording has a path to continue after Spotify quits.)*
5. Click **Start Recording**. Confirm the level meter is active and the timer is running.

### Steps

1. Wait **30 seconds** with recording active.
2. Force-quit Spotify using one of these methods:
   - Option-click the Spotify Dock icon → **Force Quit**, OR
   - Run in Terminal: `killall Spotify`
3. Within 5 seconds, observe the app UI.
4. Confirm a warning banner or alert appears stating that the tapped source (Spotify) has quit.
5. Confirm the recording timer **continues to increment** (recording is not stopped).
6. Wait an additional **30 seconds** with Spotify closed.
7. Click **Stop**.
8. Open the output MP3 in QuickTime Player.

### Pass Criteria

- [ ] A warning banner appears within 5 seconds of Spotify quitting — message clearly names the source that disconnected.
- [ ] The recording timer continues running after the warning (recording is not auto-stopped).
- [ ] The output MP3 plays without crashing the audio player.
- [ ] The first ~30 seconds contain Spotify audio; after the quit point the recording may be silent (if Spotify-only source) or continue with other audio (if "Everything").
- [ ] The app does not crash when the tapped process exits.

### Fail Criteria

- No warning banner appears when Spotify quits.
- The recording stops automatically on source quit (without user action).
- The app crashes when the tapped process exits.

---

## MT-008: Long Recording Stress Test — 60-Minute Everything+Mic, No Memory Leaks

**Goal**: Verify the app does not accumulate memory or CPU over a long session.

### Setup

1. Open **Activity Monitor** (Applications → Utilities → Activity Monitor).
2. In the CPU tab, locate the System Audio to MP3 process. Note its current **Memory** (Real Memory column) at idle. Record the value: _____ MB.
3. Open the System Audio to MP3 app.
4. In the source dropdown, select **Everything + Mic**.
5. Start a continuous audio source (e.g., a long YouTube livestream in Safari, or a radio stream in Music app).
6. Plug in or enable the microphone.

### Steps

1. Click **Start Recording**.
2. Confirm the level meter is active (system audio side) and the mic is picking up ambient sound.
3. Note the memory reading in Activity Monitor at recording start: _____ MB.
4. Let the recording run for **60 minutes** without touching the app.
5. At the 60-minute mark, note the memory reading again: _____ MB.
6. Confirm the CPU usage has not spiked above 15% sustained average (brief spikes are acceptable).
7. Click **Stop**.
8. Wait for the encoding to complete (toast shows "Saved → …").
9. Note memory after encoding completes: _____ MB (should return close to idle level).
10. Open the output MP3 in QuickTime Player. Confirm playback for at least the first and last 30 seconds.

### Pass Criteria

- [ ] The recording runs for the full 60 minutes without the app crashing or freezing.
- [ ] Memory growth from recording-start to 60-minute mark is less than **50 MB** (indicates no ring buffer or file handle leak).
- [ ] CPU usage during recording stays below 15% average on an M-series Mac.
- [ ] After encoding completes, memory returns to within 20 MB of the pre-recording idle level.
- [ ] Output MP3 duration is between 59:50 and 60:10.
- [ ] First 30 seconds and last 30 seconds of the MP3 are both audible with no corruption.

### Fail Criteria

- App crashes or hangs at any point during the 60-minute session.
- Memory grows more than 50 MB over the recording period.
- Output MP3 is silent, corrupted, or has a duration significantly shorter than 60 minutes.

---

## MT-009: Notarized DMG Install — No Gatekeeper Warning

> **Prerequisite**: This test requires REQ-042 (notarization and DMG packaging) to be complete. Skip this test until the notarized DMG artifact is produced by the release pipeline.

**Goal**: Verify that a fresh DMG download installs and launches without any Gatekeeper or security warning.

### Setup

1. On a **clean Mac** that has never run this app before (or after running `tccutil reset All com.yourcompany.SystemAudioRecorder` and clearing the app from `~/Applications`).
2. Ensure the Mac is connected to the internet (notarization ticket lookup requires network access on first launch).
3. Download the release DMG from the distribution URL provided in the release notes.

### Steps

1. In Finder, double-click the downloaded `.dmg` file.
2. Observe: no Gatekeeper dialog saying *"SystemAudioRecorder.dmg cannot be opened because it is from an unidentified developer."*
3. The DMG mounts and its window opens.
4. Drag the app icon to the Applications folder alias in the DMG.
5. Eject the DMG.
6. In Finder, navigate to Applications and double-click **System Audio to MP3**.
7. Observe: no Gatekeeper dialog saying *"SystemAudioRecorder cannot be opened because it is from an unidentified developer."*
8. Observe: macOS may show *"SystemAudioRecorder is an app downloaded from the internet. Are you sure you want to open it?"* — click **Open**. This is expected on first launch and is not a failure.
9. Confirm the app's main window appears.
10. Run the `spctl` check in Terminal:
    ```
    spctl --assess --verbose --type execute /Applications/SystemAudioRecorder.app
    ```
    Expected output: `accepted` with source `Notarized Developer ID`.

### Pass Criteria

- [ ] DMG mounts without a Gatekeeper block.
- [ ] App launches from Applications without a Gatekeeper block.
- [ ] `spctl --assess` returns `accepted` and `Notarized Developer ID`.
- [ ] App main window appears on first launch.
- [ ] No "damaged and can't be opened" errors appear.

### Fail Criteria

- Gatekeeper blocks the DMG mount with an "unidentified developer" dialog.
- Gatekeeper blocks the app launch with an "unidentified developer" dialog.
- `spctl --assess` returns `rejected`.
- App shows "is damaged and can't be opened. You should move it to the Trash."

---

## MT-010: Real Core Audio Tap — Chromium Browser in Everything Mode (REQ-044)

**Goal**: Regression guard for UR-004. Chromium-family browsers (Chrome, Arc, Edge, Brave) emit audio from helper PIDs (e.g. `Google Chrome Helper (Renderer)`) that `NSRunningApplication(processIdentifier:)` does not surface. Confirm `AudioSourceCatalog` includes those helpers via the HAL bundle-ID source so `Everything` mode actually captures their audio.

### Setup

1. Open a Chromium-based browser (Chrome, Arc, Edge, or Brave).
2. Navigate to a recognisable audible source (e.g. a YouTube clip with clear speech, ~1 minute long). Start playback and confirm you hear audio from your Mac's speakers.
3. Open the System Audio Recorder app.
4. Confirm the source dropdown shows **Everything** as the default selection (do **not** switch to Specific app for this test — `Everything` mode is the path under test).

### Steps

1. Click **Start Recording**.
2. Confirm the level meter is non-zero while audio plays.
3. Let the recording run for **30 seconds** without pausing or switching tabs.
4. Click **Stop**.
5. Wait for the toast to show *"Saved → ~/Music/Recordings/…mp3"*.
6. Open the MP3 in QuickTime Player.

### Pass Criteria

- [ ] Level meter is non-zero throughout the 30 s recording window (proves at least one helper PID is feeding the mixer).
- [ ] Output MP3 plays back with clearly audible browser audio that matches what was playing in the browser — speech from YouTube, music, etc.
- [ ] MP3 duration is between 28 s and 32 s.
- [ ] No "silent file" regression: the file is not 0 bytes and does not play as silence (this was the UR-004 failure mode before the catalog fix).

### Fail Criteria

- Output MP3 plays as silence despite audible browser playback during recording (UR-004 regression).
- Level meter stays at −∞ dB throughout the recording.
- File is 0 bytes or fails to open.

### Notes

The fix for this scenario lives in `AudioEngine/Capture/AudioSourceCatalog.swift` — bundle IDs are sourced from Core Audio's `kAudioProcessPropertyBundleID` first, with `NSRunningApplication` as enrichment-only. If this test starts failing, run the unit test suite (`AudioSourceCatalogTests`) first to catch the regression at the protocol-contract level before chasing it at the integration level.
