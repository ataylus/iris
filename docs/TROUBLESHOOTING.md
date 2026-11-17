# Troubleshooting and maintenance

## Symptoms

| What you see | Likely cause | Fix |
|---|---|---|
| Iris window never appears | It is already open (only one runs at a time) | Look for it on the taskbar |
| "Docker Desktop is not installed" or "Tailscale is not installed" | The command is not on PATH | Install it (see the README), then open Iris again |
| Video froze after switching Saved/Fresh | The restart ended everyone's session | Refresh the page |
| Stuck on "Starting Docker" | Docker Desktop is slow to start or needs attention | Open Docker Desktop and check for a prompt |
| Stuck on "Connecting to Tailscale", then "Iris stopped" | Tailscale is signed out or its login expired | Sign in from the Tailscale tray icon, then open Iris again |
| "The network lockdown failed" | The firewall container could not apply its rules | Open Iris again. If it repeats, run `docker compose up firewall` in this folder to see the error |
| "Iris stopped" after it was working | The shared browser or Docker stopped | Close the window and open Iris again |
| "Running without the graphics card" | No NVIDIA GPU was found, or Docker refused it | See "Graphics card" below |
| Logins forgotten between parties | Fresh mode is selected | Switch the Browser setting to **Saved** |
| Saved mode reopens on a blank tab | Chrome was killed before it saved its tabs | Use **End party** rather than closing Docker. See "Saved mode" below |
| Guest: page will not load | Tailscale is off on their side, the share was not accepted, or Iris is not running | Check each in that order |
| Guest: page loads, wrong password or unknown user | They were removed, or the name's capitalisation differs | Copy a fresh link |
| Guest: "session already connected" | Their account is open on another device or tab | Close the other one |
| Page loads but the video spins forever | Browser cannot complete the video connection | Refresh once. If it persists, see "Video never connects" below |
| No sound, or a play button over the video | The browser blocked autoplay | Click the video once |
| "Linux clock is running at the wrong speed", or motion judders | A time service in a WSL distro is warping the shared kernel clock | See "WSL clock" below |
| Laggy or blocky picture | Relayed Tailscale connection, slow network, or TCP fallback | See "Lag" below |
| A streaming site refuses to play | The site blocks Linux or software DRM | Try another site, or a sync extension for that one |

### Graphics card

Iris uses the NVIDIA card when `nvidia-smi` lists one and Docker accepts `--gpus`. Otherwise it runs
the CPU encoder at 30 fps. To check by hand:

```powershell
docker run --rm --gpus all ghcr.io/m1k1o/neko/nvidia-google-chrome:latest nvidia-smi -L
```

If that fails, update the NVIDIA driver and Docker Desktop. If it works but the picture is black,
check `docker compose logs neko` for `nvautogpuh264enc` errors. Do not switch to `nvh264enc`: it
fails on driver 590 and later with "Selected preset not supported".

### Saved mode

Chrome needs a few seconds to write its open tabs on exit. The compose file allows 15 seconds.
Quitting Docker Desktop or shutting down Windows with the party running can still cut it short;
cookies usually survive, open tabs may not.

### WSL clock

Docker Desktop and every WSL distro share one Linux kernel, and Hyper-V keeps its time in step with
Windows. If a distro also runs its own time service, the two fight and the kernel clock runs at the
wrong speed. The video then comes out at about 54 fps with periodic hitches. Check (10000 is normal):

```powershell
docker run --rm alpine:3 adjtimex | Select-String tick
```

The fix that worked here, for the Ubuntu distro:

```powershell
wsl -d Ubuntu-24.04 -u root -- systemctl disable --now systemd-timesyncd
wsl --shutdown
```

Then reopen Docker Desktop. To undo: `systemctl enable --now systemd-timesyncd` inside Ubuntu.
Check any other distros for `systemd-timesyncd`, `chrony` or `ntp`.

### Video never connects

Happened once during setup: Firefox loaded the page but never showed video. The cause was the STUN
address in `docker-compose.yaml`. If you change that setting, test in Firefox and in a Chromium
browser. Edge tolerated a value that Firefox rejected.

### Lag

1. During a party, run `tailscale ping <guest-device-name>`. `via DERP` means the connection is
   relayed through Tailscale's servers, which adds delay. A direct connection shows an IP address.
2. If a guest is always on the TCP fallback, Windows Firewall on this laptop may be dropping their
   UDP. Allowing inbound UDP 59000 on the Tailscale network adapter fixes it. Not tested with a real guest.
3. On a weak guest connection, lower `bitrate` and `vbv-buffer-size` in `stack/gpu.yaml` (for example to 6000).

### Docker crashed once

During testing, Docker Desktop's backend exited on its own once
(`com.docker.backend.exe services: exit status 1`). It could not be reproduced. Iris notices within
about 30 seconds and tells you. Restarting Docker Desktop and opening Iris again recovers.

## Maintenance

- **Browser updates** happen automatically each time Iris starts.
- **Tailscale key expiry.** By default this laptop's Tailscale login expires after some months. You
  can disable expiry for the machine in the Tailscale admin console.
- **Docker Desktop, Tailscale and the NVIDIA driver** update through their own apps.
- **If the laptop is renamed or Tailscale is reinstalled**, the address changes. Iris picks it up
  automatically, but old links stop working, so copy new ones. The access rule in
  [GUESTS.md](GUESTS.md) also needs the new address.
- **Saved profile size.** The `iris_profile` volume grows with Chrome's cache. **Clear saved data** resets it.

## Useful commands

Run these in this folder.

| Command | What it does |
|---|---|
| `powershell -ExecutionPolicy Bypass -File .\Iris.ps1 -Stop` | Stops everything without the window |
| `docker compose ps -a` | Shows the two containers and their state |
| `docker compose logs --tail 50 neko` | The shared browser's recent log |
| `docker volume ls` | Lists volumes; `iris_profile` is the saved browser |
| `tailscale serve status` | What is published to the tailnet. Empty when Iris is stopped |
| `tailscale funnel status` | Should never list anything; Funnel would mean public exposure |

## Testing changes

How this setup was verified, so you can repeat it after changing anything:

1. **Lockdown.** From inside the container, private addresses must be refused and the internet reachable:
   ```bash
   docker compose exec -T neko bash -c 'for t in 1.1.1.1/443 host.docker.internal/445 192.168.1.254/80; do timeout 4 bash -c "</dev/tcp/$t" 2>/dev/null && echo "REACHABLE $t" || echo "blocked $t"; done'
   ```
2. **Video.** `node tools\viewer.mjs firefox "<invite link>"` (and `edge`) joins headlessly and
   prints decoded fps, bitrate, jitter buffer, freezes and whether audio arrives.
3. **Saved mode.** Visit a site in the shared browser, end the party, reopen, and check the page is
   back and `Default/Cookies` in the volume has rows for that site.
4. **The window.** `Iris.ps1 -Snapshot out.png` renders the window to an image without starting
   anything. A file name containing `sheet` renders it with the close confirmation showing.
5. **The buttons.** The window can be driven with Windows UI Automation: buttons are named by their
   label, plus `Copy link for <name>`, `Remove <name>`, `Saved browser` and `Fresh browser`.

6. **Removing a guest.** Join as a test guest with `viewer.mjs`, click `Remove <name>` while it
   runs: the neko log shows `session deleted` for that name and the viewer gets no video.

## Not verified

- A real guest joining from another network, and how much delay that path adds.
- Real streaming services with DRM.
- The Tailscale access rule in GUESTS.md.
