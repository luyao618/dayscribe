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

## Approved native panel restoration — 2026-09-16

- Restored the approved panel structure and palette: 390pt pearl surface, rounded brand/header actions, inset mode selector, split-color clock and filename, two-source card, destination, rectangular start/stop action, and recent recording section. The recording state uses the real microphone's elapsed time, filename and measured power; no demo values are injected.
- Offscreen SwiftUI renders below were visually compared with design/screenshots/panel-preview.png. They show idle audio/video states; the approved reference shows an active video recording. The native host fitting sizes are 390×631pt for audio and 390×678pt for video. NSPopover now follows preferred content size instead of a fixed 400pt height.
- System audio selection, video recording, renaming, destination changes and full history remain explicitly unavailable at this increment. Recent recording displays the latest successful microphone file from this app session and reveals that actual file in Finder. This is not yet persistent history.
- Debug build and Apple Development bundle signature verification passed. A real 5s microphone regression produced a 5.013s AAC/M4A that completely decoded; measured peak was −34.2dBFS. Local evidence: artifacts/mic-check-4j6uhz8e. No capture or writer code changed in this PR.
- The desktop CUA connector again timed out after launching the application. These images are offscreen renders of the native SwiftUI view, not desktop screenshots. Menu-bar clicks, dynamic popover resizing, keyboard navigation and nested settings interaction still require actual GUI verification.

![Native audio panel, idle offscreen render](screenshots/native-panel-audio.png)
![Native video panel, unavailable idle offscreen render](screenshots/native-panel-video.png)

## Common-timeline mixer component — 2026-09-16

- Added a queue-confined 48kHz stereo PCM mixer with a fixed two-second ring per source and a 250ms holdback for callback arrival differences. Output blocks are emitted synchronously. These bounds apply to the mixer component; complete capture-pipeline memory behavior still requires integration and long tests.
- Seven generated-PCM tests verify cross-source arrival ordering and capture-time offsets, left/right channel preservation, source changes inside a buffered block, pre-epoch trimming, gaps and final silence, per-source RMS and saturation counts, explicit rejection of late/overlapping/excessively distant data, and propagation of downstream write failures. A wraparound test verifies old samples are cleared and buffered duration stays bounded.
- The mixer sums selected sources and clamps samples to the legal PCM range, reporting the number of saturated samples. Source changes cannot disable every source or rewrite audio already emitted.
- All seven mixer cases plus the existing five AAC writer cases pass. Debug app build/signature verification passes. These are deterministic component checks, not evidence of actual mixed hardware capture, device resampling or the required 8h/2h recordings. The approved panel is unchanged in this increment.

## Streaming native PCM conversion — 2026-09-16

- Added a queue-confined AVAudioConverter adapter for continuous native PCM to interleaved 48kHz stereo. Mono maps equally to left/right; stereo retains its channel order. Converter state survives packet boundaries, and CoreMedia sample data is copied into a bounded input buffer. Each input call accepts at most one second of native audio; output has an explicit size ceiling.
- Initial independent impulse tests exposed the latency introduced by primeMethod.none (48 output frames for 16kHz, 17 for 44.1kHz). Switching to normal priming removes the shift; both impulse positions now fall within one output frame of their known source times. Temporary input starvation uses noDataNow; final endOfStream drains the filter tail.
- Eleven converter cases pass: six native-rate/layout/representation combinations (16/44.1/48/96kHz, mono/stereo, planar/interleaved, Float32/Int16), two fractional-tail/CoreMedia cases, two impulse-timing cases, and invalid-input/lifecycle handling. Streaming results match single-buffer conversion within 0.00005 sample amplitude, retain known tones and channel identity, and have the correct cumulative duration. Fractional final duration is rounded down once to the last complete 48kHz frame (less than 20.84µs), without per-packet truncation.
- All 23 component cases (13 test functions across three suites) pass, as does the native debug build/signature check. These generated fixtures do not prove actual microphone/system mixing, device switching, or long-duration capture. Native capture timestamp mapping and integration are still next.

## Actual mixed audio pipeline — 2026-09-16

- AudioRecorder now feeds selected ScreenCaptureKit system/microphone outputs through continuous native-format conversion and a common earliest-capture epoch into one M4A. Startup data is bounded (8MiB, 256 buffers, two-second timestamp span) and ordered by capture time once each selected source arrives. Writer rejection propagates before mixed PCM is reclaimed; shutdown drains converter/mixer tails before closing AAC.
- Fresh app-owned preflight confirmed both screen/audio and microphone permissions. Actual SCK source timestamps share the host clock; the first mixed test preserved the microphone's 233.99ms later start. Measured cumulative source clock skew was zero frames in these short captures; this does not establish long-duration synchronization.

| Actual source selection | Native rates | PCM timeline / ffprobe container duration | Local evidence |
|---|---|---|---|
| System + built-in microphone | 48k + 48k | 8.233979s / 8.298667s | artifacts/system-audio-check-7287lqrh |
| Built-in microphone only, acoustic fixture | 48k | 8.032s / 8.085333s | artifacts/system-audio-check-qg9wtf6q |
| Jabra BIZ 2400 II USB microphone only, acoustic fixture | 16k → 48k | 8.000s / 8.064000s | artifacts/system-audio-check-sd3ldai7 |
| System + Jabra USB microphone, interrupted after ~5s of a 30s request | 48k + 16k | 5.214375s / 5.269333s | artifacts/system-audio-check-6qipotlj |
| System only regression | 48k | 8.020s / 8.064000s | artifacts/system-audio-check-ptgy7o4n |

AAC container durations currently exceed the submitted PCM timelines by about 44–65ms. Both measurements are retained separately; precise presentation timing and codec padding must be checked when integrating synchronized video and independent audio output.

- Every listed capture produced exactly one fully decoded stereo AAC/M4A, with identifiable 880/1760Hz stimulus segments in the expected order, zero reported clipping, and successful process exit. Source-frame and native-rate reports verify the actual selected inputs. Acoustic checks disabled system capture and played the fixture through built-in speakers using AVAudioPlayer.currentDevice; this is sound recorded by physical microphones, not a fixture injected into the encoder. Default input remained the built-in microphone and default output remained Jabra after validation.
- The first Jabra acoustic attempt (artifacts/system-audio-check-vfo9nhsp) captured/converted/decoded correctly but failed tone identification because the signal was too weak. It is retained as failed calibration evidence. A repeat with fixture peak 3000/32767 instead of 1000 passed the same thresholds; the checks were not relaxed. Bluetooth and live device changes are still untested.
- Twenty-five component cases pass, including complete adapter→encoder checks for source offset/both frequencies and refusal to report success if a selected source never arrives. Debug build, bundle signature and fixture-tool compilation pass. The diagnostic panel below is an offscreen native render, not proof of desktop interaction. The normal approved panel still uses the earlier microphone path; real mixed controls are the next UI increment.

![Native audio diagnostic, offscreen idle render](screenshots/native-audio-check.png)

## Live panel integration — implementation pending final native checks

- The approved panel now uses AudioRecorder for both source toggles, measured independent levels, microphone-device help, elapsed time, filename, last saved file and asynchronous stop. Default-both source selection is persisted; disabling every source is rejected with a visible message. The old separate AVAudioRecorder path is removed, including its synchronous-quit assumption.
- Initial live tests (artifacts/source-switch-check-u5efy63s and source-switch-check-p_thn9wb) passed recorded-signal gating and last-source rejection but **failed** the native callback-stop check. Updating captureMicrophone=false still delivered nonzero microphone PCM, including with a fresh SCStreamConfiguration and explicit device UID. These are not successful independent-stop results.
- The implementation now owns separate system/microphone SCStreams sharing one host-clock mixer/encoder. Disabled source streams are explicitly stopped; converter tails are drained and retired before later restart. Final real validation of this replacement is **pending**: the subsequent attempt (artifacts/source-switch-check-zpgw307m) correctly failed before recording because the Mac was locked and all displays asleep. Public session/display inspection confirmed that state; no unlock or permission bypass was attempted.
- Twenty-seven component cases pass (17 test functions), including persisted nonempty selection and a 16kHz source stop/restart with preserved epoch and flushed resampling tail. Debug build/signature, script syntax and the native idle render pass. These checks do not prove the replacement streams' live lifecycle or native UI clicks.
- Remaining gates for this PR: scripts/check-source-switching.py with both/single initial sources and USB input; normal microphone regression; scripts/check-system-audio.py --panel --sources both --seconds 30 --interrupt-after 5 --quit-via-appkit. Keep the PR as draft until the actual source and termination checks pass. Native desktop click/keyboard acceptance also remains pending.

![Connected native panel, offscreen idle render](screenshots/native-live-panel-idle.png)

## Remaining acceptance

Live source switching and main-panel mixed capture integration, screen selection/video outputs, Bluetooth, device changes, recovery, real 8-hour audio / 2-hour video tests, and final native GUI validation remain outstanding. Explicit async mixed-audio stop is verified; final OS-driven quit/sleep and video shutdown still need dedicated checks.
