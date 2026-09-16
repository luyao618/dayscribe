# Native implementation validation

This log concerns the native application. Browser-prototype checks in design/QA.md do not prove capture functionality.

## Native application shell — 2026-09-16

- Environment: Apple Silicon, macOS 26.6.2, Xcode 26.6, Swift 6.3.3.
- SwiftPM debug compilation passed; generated bundle executable is Mach-O arm64.
- App Info.plist passed plutil validation; bundle identifier is com.luyao618.Scriber.
- Local ad-hoc app signature passed codesign --verify --strict.
- App launched through Launch Services and running Scriber process was observed.
- Build script refuses to overwrite an already-running Scriber bundle; guard verified.
- Native view rendered using SwiftUI ImageRenderer and visually inspected. This is an offscreen render of the application view, not a desktop screenshot or proof of menu bar interaction.
- Automated native GUI connector timed out and then was unavailable in the current tool inventory. Actual menu bar/mode-switch confirmation was requested from the user and remains pending.

![Native shell view, offscreen render](screenshots/native-shell.png)

## Microphone recording — 2026-09-16

- Real capture used the system-default MacBook Pro built-in microphone. The attached Jabra USB headset was the default output; its microphone and Bluetooth routes have not yet been validated.
- A requested 5-second capture produced a 48 kHz, mono AAC/M4A with a 5.013333-second container duration, decoding without errors. Measured peak was -48 dBFS. This was ambient input, not an identifiable calibration signal.
- A separate requested 30-second capture completed normally; AVAsset presentation duration was 29.972 seconds and measured peak was -21.4 dBFS.
- Graceful-quit testing initially exposed a termination deadlock. Stack evidence showed AppKit waiting inside a main-actor task while completion was queued to the same actor. The file itself was already closed and playable.
- The microphone-specific quit path now uses AVAudioRecorder.stop's documented synchronous file-close guarantee. A corrected check requested 120 seconds but sent SIGTERM after about 2 seconds: the process exited, the result reported interrupted, and its 2.069333-second file decoded successfully. This is not counted as a 120-second recording.
- Final normal-capture regression on the developer-signed build also passed an actual 5-second recording and complete decode. Local evidence is retained in ignored artifacts/microphone-check-* and artifacts/microphone-quit-check-* directories; audio is not committed.
- Reproducible scripts/check-microphone.py checks passed: --seconds 5 produced 5.013s AAC and normal process exit; --seconds 30 --interrupt-after 2 produced 2.155s AAC, interrupted status and process exit. Both files completely decoded. Evidence is retained in ignored artifacts/mic-check-6s6x5iq6 and artifacts/mic-check-kylhpe4x.
- Build signing now prefers the sole existing Apple Development identity for consistent update identity. No new certificate, credential, or trust setting is created.
- The native meter is drawn from actual measured dBFS using SwiftUI segments. Screenshot below is an offscreen idle-view render, not hardware/screen-capture evidence.

![Native microphone panel, offscreen render](screenshots/native-microphone.png)

## PCM writer component — 2026-09-16

swift test passes three cases: generated PCM fixture encoded to AAC and fully decoded with expected frame count/duration/RMS/peak; a repeated old timestamp is rejected while the already-written valid prefix remains playable; an empty capture cannot report success. These are codec/component tests, not evidence of actual system-audio capture.

## System audio source — 2026-09-16

- Initial real capture was denied by macOS TCC: zero frames and no media output. The diagnostic reported failure, not success. Later app-owned public permission preflight reported both screen and microphone authorized; no TCC database or permission setting was changed by the implementation.
- Actual ScreenCaptureKit capture passed through the current Jabra USB system output: requested 8s, media timeline 8.02s / 384960 frames, stereo AAC completely decoded. Two externally played stimulus frequencies (880Hz and 1760Hz) were detected with strong energy relative to a 3127Hz control frequency. Trailing silence was retained.
- A separate 30s-request check stopped via SIGTERM after about 5s: 5.16s / 247680 frames retained, result correctly marked interrupted, process exited and file decoded completely. The measured tone centroids were 1.282s and 3.281s, confirming the two stimulus segments' order and approximate two-second separation.
- Evidence remains local in artifacts/system-audio-check-tty2hz1l and artifacts/system-audio-check-1twzdhgq. The WAV is only the playback stimulus; the analyzed M4A came from the actual macOS capture callback.
- Codec cases additionally cover stereo planar and interleaved PCM. All five cases pass. Diagnostic UI rendering is offscreen evidence only.
- Microphone regressions after the system-source integration passed: normal 5s capture (5.013s container) and 30s-request/2s interruption (2.112s container), both with process exit and complete decode. Evidence is in ignored artifacts/mic-check-j703d3rw and artifacts/mic-check-xj5uzvxb.

![System audio diagnostic panel, offscreen render](screenshots/native-system-check.png)

## Remaining acceptance

Mixed capture and source switching, a calibrated microphone signal, screen selection/video outputs, Bluetooth and wired microphone routes, device changes, recovery, real 8-hour audio / 2-hour video tests, and final native GUI validation remain outstanding. Explicit async system-audio stop is verified; final OS-driven quit/sleep and video/mixing shutdown still need dedicated checks.
