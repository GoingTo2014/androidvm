# AndroidVM — Android 4.4 in your browser

AndroidVM starts Android 4.4 (KitKat) Google APIs x86 on a temporary GitHub Actions runner. The webpage shows the remote desktop edge-to-edge, without an additional dashboard.

## Start a session

1. Open the repository's **Actions** tab.
2. Select **Start Android 4.4 VM** and click **Run workflow**.
3. Choose the device form factor (Phone or Tablet), session duration, ADB root mode, RAM, CPU cores, internal data storage, and optional SD card and capacity.
4. Open the **Start Android VM** job logs and use the temporary TryCloudflare URL printed when the VM is ready.

The workflow is manual-only. Phone mode is the default. Default resources are 2048 MB RAM, one CPU core, 2 GB internal storage, and no SD card.

## Display and window controls

- Selkies 2.0.0 captures the existing X11 desktop and provides the browser UI, H.264 video, audio, and mouse/keyboard input. The official Ubuntu 24.04 package is installed and its SHA-256 checksum is verified at startup.
- The first deployment uses Selkies' single-port WebSocket transport with H.264/WebCodecs, which works through the existing TryCloudflare HTTP tunnel without additional media ports or a TURN server.
- The stream targets up to 60 FPS; actual frame rate depends on CPU encoding capacity, runner load, browser decoding, and network conditions.
- The runner uses Openbox as a lightweight window manager. This restores the Android Emulator window's titlebar and its minimize, maximize, and close buttons. The launcher attempts to center the emulator window initially; you can drag it by its titlebar afterward.
- Selkies provides browser mouse/keyboard input, clipboard and touch/trackpad controls, plus stream settings.
- The emulator runs in an isolated Xvfb display with the X11 extensions Selkies needs for capture and input.

**Try WebRTC too:** the Selkies side menu has transport switching enabled. The session starts in H.264/WebSocket mode, but you can try WebRTC from the UI; Selkies' default public TURN relay is configured in its upstream settings. WebRTC may be slower if traffic has to pass through that relay, so switch back to WebSockets if it stutters or fails. The basic TryCloudflare URL itself only exposes the web/signaling port, not arbitrary media ports.

## Audio

- Selkies captures the PulseAudio output monitor and streams Opus audio alongside the desktop.
- Audio is disabled automatically only if PulseAudio cannot be configured on the runner.

## Phone and tablet modes

- **Phone** keeps the existing/default Android display configuration.
- **Tablet** uses a 1024×600 landscape display at 160 dpi. Its 600 dp shortest dimension encourages Android 4.4 and apps to use tablet layouts, while leaving room for the emulator window's titlebar on the virtual desktop.

## Choosing VM resources

- **Device form factor:** Phone (default) or Tablet.
- **RAM:** 1536, 2048, 3072, or 4096 MB.
- **CPU cores:** 1, 2, or 4. One core is the default for KitKat compatibility.
- **Internal data storage:** 1, 2, 4, or 8 GB.
- **SD card:** optional, 256 MB, 512 MB, 1 GB, 2 GB, 4 GB, or 8 GB. When enabled, the launcher creates and attaches a virtual SD image.

The job checks for KVM. Without KVM, CPU emulation may be much slower. The chosen session length is capped at 300 minutes to remain within GitHub-hosted job limits.

## Installing APKs

- Put regular APK files in `apks/`. The launcher attempts to install them using `adb install -r` after Android boots.
- Put system APK files in `systemapks/`. The launcher temporarily obtains ADB root, remounts `/system`, copies APKs into `/system/app`, and reboots so Package Manager can scan them.
- **Root access** controls whether ADB remains root for the session. It is ADB shell root; it does not automatically grant root privileges to every app. APKs must support Android 4.4 / API 19.

## Optional access protection

The TryCloudflare URL is temporary, but anyone who can access it may control the VM. Avoid signing in to real accounts or entering sensitive data. For extra protection, add an Actions secret named `VM_ACCESS_PASSWORD`; the site will require HTTP Basic Authentication with username `vm` and that password.

## Troubleshooting

- **The stream does not load:** check the Selkies HTTP smoke test and `selkies.log` in the job output.
- **Audio is missing:** check the PulseAudio setup message and `selkies.log`.
- **No SD card:** confirm that the SD card input is enabled in the workflow form.
- **The URL does not load:** it exists only while the workflow is running. Start a new session to receive a new URL.
- **The VM stops:** the selected duration expires, the workflow is cancelled, or GitHub's job limit is reached.

## Project layout

- `.github/workflows/start-vm.yml` — manual session and resource options.
- `scripts/start-vm.sh` — emulator, lightweight window manager, Selkies installation and tunnel launcher.
- `nginx/androidvm.conf.template` — authenticated reverse proxy for Selkies and its WebSocket transport.
