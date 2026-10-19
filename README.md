# AndroidVM — Classic Android in your browser

AndroidVM starts a selectable Android emulator system image on a temporary GitHub Actions runner. Android 4.4 (KitKat) remains the default. The webpage shows the remote desktop edge-to-edge, without an additional dashboard.

## Start a session

1. Open the repository's **Actions** tab.
2. Select **Start Android VM** and click **Run workflow**.
3. Choose the Android version, whether to enable the Google Play Store (optional; Android 7.0 only), graphics rendering mode, browser to install (optional), device form factor (Phone or Tablet), hardware keyboard, session duration, ADB root mode, RAM, CPU cores, internal data storage, and optional SD card and capacity.
4. Open the **Start Android VM** job logs and use the temporary TryCloudflare URL printed when the VM is ready.

The workflow is manual-only. Android 4.4 KitKat and Phone mode are the defaults. Default resources are 2048 MB RAM, one CPU core, 2 GB internal storage, and no SD card.

## Android versions

The first batch offers these official Google APIs x86 system images:

- Android 2.3.3 Gingerbread (API 10)
- Android 4.0.4 Ice Cream Sandwich (API 15)
- Android 4.1 Jelly Bean (API 16)
- Android 4.3 Jelly Bean (API 18)
- Android 4.4 KitKat (API 19, default)
- Android 5.0 Lollipop (API 21)
- Android 5.1 Lollipop (API 22)
- Android 6.0 Marshmallow (API 23)
- Android 7.0 Nougat (API 24)

Android 3.2 Honeycomb (API 13) is not included yet because the official Google APIs SDK repository does not list an installable x86 system image for that API. We can investigate a legacy/community image separately rather than offering a workflow choice that cannot install.

Each version has its own system-image cache. The Android SDK tools are cached separately to avoid duplicating them for every release.

### Google Play Store option

The manual workflow has a **Google Play Store** toggle. When enabled, select **Android 7.0 (API 24)** and **Phone** mode. AndroidVM downloads the official x86 `google_apis_playstore` system image so the Play Store and Google Play services are preinstalled. The setting is off by default, and the normal Google APIs images remain unchanged.

Google's Play Store images are signed with release keys and do not support ADB root. Therefore, Google Play mode rejects **Root access = enabled** and any APKs in `systemapks/`; ordinary APK installation through `apks/` remains available. Google Play Store mode is restricted to phone mode in this workflow because the legacy API 24 Play image has compatible phone hardware profiles, not the existing Nexus 7 tablet profile. <Link url="https://developer.android.com/studio/run/managing-avds" title="Android Emulator documentation"/>.

## Display and window controls

- Selkies 2.0.0 captures the existing X11 desktop and provides the browser UI, H.264 video, audio, and mouse/keyboard input. The official Ubuntu 24.04 package is installed and its SHA-256 checksum is verified at startup.
- The first deployment uses Selkies' single-port WebSocket transport with H.264/WebCodecs, which works through the existing TryCloudflare HTTP tunnel without additional media ports or a TURN server.
- The stream targets up to 60 FPS; actual frame rate depends on CPU encoding capacity, runner load, browser decoding, and network conditions.
- The runner uses Openbox as a lightweight window manager. This restores the Android Emulator window's titlebar and its minimize, maximize, and close buttons. The launcher attempts to center the emulator window initially; you can drag it by its titlebar afterward.
- Selkies provides browser mouse/keyboard input, clipboard and touch/trackpad controls, plus stream settings. The **Hardware keyboard** workflow option controls Android's `hw.keyboard` setting in either device mode. It defaults to **enabled** so the computer keyboard can type directly into Android; disable it if you prefer to simulate a device without a physical keyboard and rely on Android's on-screen keyboard.
- The emulator runs in an isolated Xvfb display with the X11 extensions Selkies needs for capture and input.

**Try WebRTC too:** the Selkies side menu has transport switching enabled. The session starts in H.264/WebSocket mode, but you can try WebRTC from the UI; Selkies' default public TURN relay is configured in its upstream settings. WebRTC may be slower if traffic has to pass through that relay, so switch back to WebSockets if it stutters or fails. The basic TryCloudflare URL itself only exposes the web/signaling port, not arbitrary media ports.

## Audio

- Selkies captures the AndroidVM PulseAudio monitor and streams Opus audio alongside the desktop.
- The launcher checks that the monitor source actually exists, explicitly enables Selkies audio at session start, and prints the detected PulseAudio sinks/sources to the job log.
- After Android boots, the launcher raises the startup volume from the home screen and logs Android's audio/ringer state to help make incoming-call ringtone tests audible.
- Audio is disabled automatically only if PulseAudio capture cannot be configured on the runner.
- If the stream is silent, check the speaker/audio toggle in Selkies' side menu and make sure the browser tab or site is not muted. Browser audio playback may also need a click/tap in the page first.


## Phone and tablet modes

- **Phone** keeps the existing/default Android display configuration.
- **Tablet** asks the installed Android SDK for its predefined Google **Nexus 7** hardware profile, a real Android-era tablet hardware profile that supplies tablet geometry when paired with the selected system image. When available, it supplies the Nexus 7's 800×1280 pixel screen, tvdpi density, and hardware-profile settings; the launcher sets landscape orientation and leaves the profile's screen geometry and density intact. If that profile is unavailable, it tries compatible built-in tablet definitions. The selected Android system image retains its own build identity; choosing the Nexus 7 hardware profile does not turn it into a retail Nexus 7 ROM.
- Tablet mode enlarges the host X11 canvas to 1440×900 so the 1280×800 landscape display and emulator window decorations fit without cropping.

## Graphics rendering modes

The manual workflow exposes a **Graphics mode** option. The default is `swiftshader`, a software renderer that works on headless cloud runners and can provide the OpenGL ES rendering older games require. Rendering is performed by the runner, not by your own computer's GPU.

- **`auto`:** Let the emulator choose a suitable renderer.
- **`host`:** Use the runner's host graphics driver; potentially faster, but it may be unavailable or unreliable on a headless runner.
- **`software`:** Let the emulator select a suitable software rendering backend.
- **`swiftshader`:** Software rendering for GLES and Vulkan; recommended starting point for this cloud setup.
- **`lavapipe`:** Mesa-based software renderer; support depends on the emulator build and graphics features used.
- **`swangle`:** SwiftShader software rendering through ANGLE; support depends on the emulator build.
- **`off`:** Keep GPU rendering disabled, matching the previous behavior; games that require OpenGL ES may fail to launch.

The legacy `swiftshader_indirect`, `guest`, `angle_indirect`, and `swangle_indirect` modes are not offered because current Android Emulator documentation marks them deprecated. Older emulator builds may accept modes that newer versions no longer support.

## Choosing VM resources

- **Graphics mode:** `swiftshader` (default), `auto`, `host`, `software`, `lavapipe`, `swangle`, or `off`.
- **Device form factor:** Phone (default) or Tablet.
- **Hardware keyboard:** Enabled (default) or disabled.
- **RAM:** 1536, 2048, 3072, or 4096 MB.
- **CPU cores:** 1, 2, or 4. One core is the default to keep resource use low on the hosted runner. Older releases may behave differently with newer emulator tools.
- **Internal data storage:** 1, 2, 4, or 8 GB.
- **SD card:** optional, 256 MB, 512 MB, 1 GB, 2 GB, 4 GB, or 8 GB. When enabled, the launcher creates and attaches a virtual SD image.

The job checks for KVM. Without KVM, CPU emulation may be much slower. The chosen session length is capped at 300 minutes to remain within GitHub-hosted job limits.

## Installing APKs

- The **Browser to install** dropdown downloads and installs one optional x86 browser during startup: **Chrome 81.0.4044.138** (Android API 19–23), **Firefox 68.11.0** (Android API 16+), or **Opera 58.8.2878.72999** (Android API 19–20). Choose **None** to skip browser installation. The APK is downloaded onto the temporary runner, checksum-verified, and installed without committing a large APK to this repository. The launcher rejects versions outside each APK's listed Android compatibility range.
- Firefox 68, Chrome 81, and Opera 58 are legacy releases without current security updates. Use them for compatibility testing, not sensitive browsing.
- Put regular APK files in `apks/`. The launcher attempts to install them using `adb install -r` after Android boots.
- Put system APK files in `systemapks/`. The launcher temporarily obtains ADB root, remounts `/system`, copies APKs into `/system/app`, and reboots so Package Manager can scan them.
- Put any other files in `files/`—for example, videos, music, images, documents, ZIPs, or test files. After Android boots, the launcher copies them into the device's shared `Download` storage, preserving subfolders. Photos, music, and videos are also submitted to Android's media scanner so compatible media apps can discover them.
- **Root access** controls whether ADB remains root for the session. It is ADB shell root; it does not automatically grant root privileges to every app. APKs must support the Android version selected for the session.

## Optional access protection

The TryCloudflare URL is temporary, but anyone who can access it may control the VM. Avoid signing in to real accounts or entering sensitive data. For extra protection, add an Actions secret named `VM_ACCESS_PASSWORD`; the site will require HTTP Basic Authentication with username `vm` and that password.

## Troubleshooting

- **The selected Android image fails to install:** check `sdkmanager` output. Some historic images may no longer be available from Google's SDK repository.
- **The stream does not load:** check the Selkies HTTP smoke test and `selkies.log` in the job output.
- **Audio is missing:** check the PulseAudio setup message and `selkies.log`.
- **No SD card:** confirm that the SD card input is enabled in the workflow form.
- **The URL does not load:** it exists only while the workflow is running. Start a new session to receive a new URL.
- **The VM stops:** the selected duration expires, the workflow is cancelled, or GitHub's job limit is reached.

## Project layout

- `.github/workflows/start-vm.yml` — manual session and resource options.
- `scripts/start-vm.sh` — emulator, lightweight window manager, Selkies installation and tunnel launcher.
- `scripts/install-browser.sh` — downloads, verifies, and installs the selected legacy browser.
- `scripts/android-version.sh` — maps workflow choices to Android API levels, system-image packages, and AVD names.
- `files/` — arbitrary files to copy into Android's shared Downloads storage.
- `nginx/androidvm.conf.template` — authenticated reverse proxy for Selkies and its WebSocket transport.
