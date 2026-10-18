# AndroidVM — Android 4.4 in your browser

AndroidVM starts a real Android 4.4 (KitKat) x86 system image on a temporary GitHub Actions runner. You interact with it through noVNC in your browser, with a separate live audio stream when the runner's audio backend is available.

## Start a session

1. Open the repository's **Actions** tab.
2. Select **Start Android 4.4 VM**.
3. Click **Run workflow**, choose a session length, and set **Root access** to enabled or disabled.
4. Open the **Start Android VM** job logs. The script prints the temporary TryCloudflare URL when the VM is ready.
5. Open the URL and click **Play audio** to hear the VM.

The workflow is manual-only: pushing commits does not start a VM. The standard GitHub-hosted x64 runner is used to keep the setup free for this public repository. The Android SDK and KitKat image are cached before the long-running VM session begins, so the cache can be saved even if the emulator later fails.

## Performance notes

- The guest is Android 4.4 KitKat, using the x86 system image.
- Startup checks for KVM. If KVM is available, the emulator uses hardware virtualization. If not, it falls back to software emulation and can be much slower. The KitKat guest uses its GPU renderer disabled as a compatibility workaround; the host uses KVM for CPU acceleration.
- The guest display uses software rendering for compatibility with the virtual display. Audio is captured from a PulseAudio null sink and served as an MP3 stream.
- GitHub-hosted jobs can run for at most six hours. Sessions are capped at 300 minutes to leave time for setup and shutdown.

## Installing APKs

- Put regular APK files in `apks/`. The launcher attempts to install them with `adb install -r` after Android boots.
- Put system APK files in `systemapks/`. The launcher temporarily obtains ADB root, remounts `/system`, copies these APKs into `/system/app`, and reboots so Android's Package Manager can scan them. This requires an emulator image that supports `adb root` and a writable system partition.
- The workflow's **Root access** input controls whether ADB remains running as root during the session. When disabled, root is used temporarily only if system APKs need to be copied. This is ADB shell root; it does not automatically grant root privileges to every Android app.
- APK install failures are reported in the Actions log. APKs must be compatible with Android 4.4 / API 19.

## Optional access protection

The TryCloudflare URL is temporary, but anyone who can access the URL can control the Android session. Do not sign in to real accounts or enter sensitive data. **For extra protection**, add a repository Actions secret named **VM_ACCESS_PASSWORD**; the website will then require HTTP Basic Authentication with username **vm** and that password. Avoid publishing screenshots or logs containing the URL.

## Troubleshooting

- **The VM is very slow:** check the action log for the KVM detection message. If KVM is unavailable on the hosted runner, the emulator must use software emulation.
- **No sound:** click Play audio after the VM boots. Check the action logs for PulseAudio/FFmpeg warnings; audio output depends on the emulator and runner audio backends.
- **The tunnel URL does not load:** it only exists while the workflow is running. Restart the workflow to get a new URL.
- **The VM stops:** the session length expires, the workflow is cancelled, or GitHub's six-hour job limit is reached.

## Project layout

- .github/workflows/start-vm.yml — manually triggered VM session.
- scripts/start-vm.sh — installs the Android SDK image, starts the emulator, web display, audio stream and tunnel.
- nginx/androidvm.conf.template — single-origin reverse proxy for the UI, noVNC and audio.
- site/index.html — browser interface.
