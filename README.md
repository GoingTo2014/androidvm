# AndroidVM — Android 4.4 in your browser

AndroidVM starts Android 4.4 (KitKat) Google APIs x86 on a temporary GitHub Actions runner. The web page is a bare, full-viewport noVNC display with no extra panels.

## Start a session

1. Open the repository's **Actions** tab.
2. Select **Start Android 4.4 VM** and click **Run workflow**.
3. Choose the session duration, whether ADB root should remain enabled, the RAM and CPU core count, the internal data partition size, and whether to attach an SD card (plus its capacity).
4. Open the **Start Android VM** job logs and use the temporary TryCloudflare URL printed when the VM is ready.

The workflow is manual-only. The default configuration is 2048 MB RAM, 1 CPU core, 2 GB internal data storage, and no SD card. Options are bounded to stay reasonable for a GitHub-hosted runner.

## Audio and display

- The noVNC display fills the webpage viewport. Browser chrome is not hidden; you do not need to enter browser full-screen mode.
- The audio player is hidden and attempts to start automatically. Chrome can block audible autoplay on a site that has not yet received user interaction; when blocked, the first normal click/tap/key interaction with the emulator retries audio, so there is no separate Play button.
- Icecast and FFmpeg use smaller buffers to reduce the audio delay. Small buffers reduce backlog but can disconnect/rebuffer on slow networks.
- Startup checks for KVM. Without KVM, software emulation may be very slow. The guest GPU renderer stays disabled for compatibility.
- The Android SDK and system image are cached before the long-running session. GitHub-hosted jobs have a six-hour limit; the selectable sessions are capped at 300 minutes.

## Choosing VM resources

- **RAM:** 1536, 2048, 3072, or 4096 MB.
- **CPU cores:** 1, 2, or 4. One core is the default because it was the configuration used while diagnosing the old KitKat image's boot behavior.
- **Internal data storage:** 1, 2, 4, or 8 GB. This controls the Android data partition.
- **SD card:** optional, with a selectable capacity of 256 MB, 512 MB, 1 GB, 2 GB, 4 GB, or 8 GB. When enabled, the launcher creates a FAT32 virtual SD image and attaches it to the emulator.

## Installing APKs

- Put regular APK files in `apks/`. The launcher attempts to install them using `adb install -r` after Android boots.
- Put system APK files in `systemapks/`. The launcher temporarily obtains ADB root, remounts `/system`, copies APKs into `/system/app`, and reboots so Package Manager can scan them.
- **Root access** controls whether ADB remains root for the session. This is ADB shell root; it does not automatically grant root privileges to every app. APKs must support Android 4.4 / API 19.

## Optional access protection

The TryCloudflare URL is temporary, but anyone who can access it may control the VM. Avoid signing in to real accounts or entering sensitive data. For extra protection, add an Actions secret named `VM_ACCESS_PASSWORD`; the site will require HTTP Basic Authentication with username `vm` and that password.

## Troubleshooting

- **Audio still lags or buffers:** connection speed and browser buffering can still add latency, despite the lower server buffers.
- **No audio on page load:** audible autoplay is controlled by browser policy. Interact normally with the emulator; that should also trigger an audio retry.
- **No SD card:** confirm **Attach a virtual SD card** is set to enabled in the workflow inputs.
- **The tunnel URL does not load:** it exists only while the workflow is running. Start a new session for a new URL.
- **The VM stops:** the selected duration expires, the workflow is cancelled, or GitHub's six-hour job limit is reached.

## Project layout

- `.github/workflows/start-vm.yml` — manual session and resource options.
- `scripts/start-vm.sh` — Android, audio, noVNC and TryCloudflare launcher.
- `nginx/androidvm.conf.template` — gateway for the page, noVNC, and audio.
- `site/index.html` — minimal full-viewport Android display.
