# AndroidVM — Android 4.4 in your browser

AndroidVM starts a real Android 4.4 (KitKat) x86 system image on a temporary GitHub Actions runner. You interact with it through noVNC in your browser, with a separate live audio stream when the runner's audio backend is available.

## Start a session

1. Open the repository's **Actions** tab.
2. Select **Start Android 4.4 VM**.
3. Click **Run workflow** and choose a session length.
4. Open the **Start Android VM** job logs. The script prints the temporary TryCloudflare URL when the VM is ready.
5. Open the URL and click **Play audio** to hear the VM.

The workflow is manual-only: pushing commits does not start a VM. The standard GitHub-hosted x64 runner is used to keep the setup free for this public repository.

## Performance notes

- The guest is Android 4.4 KitKat, using the x86 system image.
- Startup checks for KVM. If KVM is available, the emulator uses hardware virtualization. If not, it falls back to software emulation and can be much slower.
- The guest display uses software rendering for compatibility with the virtual display. Audio is captured from a PulseAudio null sink and served as an MP3 stream.
- GitHub-hosted jobs can run for at most six hours. Sessions are capped at 300 minutes to leave time for setup and shutdown.

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
