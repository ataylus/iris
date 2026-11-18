# How Iris works

## The pieces

```
 You (browser) ---+
                  +-- Tailscale (private, encrypted) --> this laptop --> Docker --> shared Chrome --> internet
 Guest (browser) -+                                                        |
                                                                           +-- firewall: no laptop, no home network, no tailnet
```

| Piece | Role |
|---|---|
| **neko** (`ghcr.io/m1k1o/neko/nvidia-google-chrome`) | Runs Chrome inside a Docker container and streams its screen and sound over WebRTC. Viewers' clicks and keys are sent back. |
| **Tailscale** | The only way in. Publishes Iris to your tailnet and to people you have shared the laptop with. Nothing is on the public internet. |
| **firewall** (one-shot container) | Applies rules inside the shared browser's network so it can reach the internet only. |
| **Iris.ps1** | Starts and stops all of the above in the right order, switches modes, and manages guest accounts. |

## The stack files

Docker Compose merges up to three files. Iris picks them on every start:

| File | Used when | Adds |
|---|---|---|
| `docker-compose.yaml` | Always | Chrome (CPU image), CPU H.264 encoder at 30 fps, accounts, ports, firewall |
| `stack/gpu.yaml` | `nvidia-smi` finds a GPU and Docker accepts it | NVIDIA Chrome image, GPU access, NVENC encoder at 60 fps |
| `stack/saved.yaml` | Mode is `saved` | Volume `iris_profile`, Saved policy, launch flags without guest mode |

If starting with `gpu.yaml` fails, Iris retries without it, so a missing or broken GPU never stops a party.

## What happens when you open Iris

1. Starts Docker Desktop if needed and waits for it.
2. Starts Tailscale if needed, waits for it, and reads this laptop's current Tailscale address.
3. Reads the mode from `settings.json` and checks for an NVIDIA GPU.
4. If a healthy party is already running with the same address, mode and encoder (recorded in
   `.env`), reattaches. Otherwise it updates the browser image and recreates the containers.
5. Waits for the firewall container to finish. If it failed, everything is shut down. The firewall
   also reports the kernel clock speed; Iris warns if it is off, or if the Tailscale network is Public.
6. Waits for the shared browser to report healthy.
7. Publishes it with `tailscale serve`, then opens your view. While live, Iris asks Windows not
   to sleep while its window is open (closing the lid still sleeps). After **Keep it running**,
   your own sleep settings apply.
8. Keeps checking the shared browser every 15 seconds. Two failed checks in a row show an error.

Switching mode or clearing saved data sets a restart flag; the same loop then runs again from step 3.
neko keeps sessions in memory, so everyone's page has to be refreshed afterwards; the window says so.

Step 6 is quick because `docker-compose.yaml` overrides the image's health check to probe every
second while starting (the image checks every 10 seconds).

**End party** removes the Tailscale publishing and deletes the containers. The saved profile volume
is kept. Closing the window instead offers to keep the party running. With **Also quit Docker and
Tailscale** ticked (`quitApps` in `settings.json`), it then runs `docker desktop stop` and closes
Tailscale's tray app. On Windows, Tailscale stays connected only while its tray app runs (unless
"Run unattended" is on), so closing it disconnects; Iris reopens it on the next start, in parallel
with Docker.

## The two modes

| | Saved | Fresh |
|---|---|---|
| Profile | Docker volume `iris_profile` at `/home/neko/.config/google-chrome` | Inside the container, deleted with it |
| Chrome launch | Stock flags minus `--bwsi`, profile dir as above (`stack/chrome-saved-gpu.conf` / `-cpu.conf`) | Stock flags, including `--bwsi` (guest mode) |
| Policy | Stock policy plus `RestoreOnStartup: 1` and `DefaultCookiesSetting: 1` (`stack/chrome-saved-policies.json`) | Stock policy |
| Clear | `docker volume rm iris_profile` (the **Clear saved data** button) | Nothing to clear |

Three things had to be fixed for Saved mode to work, none of which the neko docs mention:

- The NVIDIA Chrome image stores its profile in `~/.config/chromium`, not the documented `~/.config/google-chrome`.
- Both Chrome images launch with `--bwsi` (browse without sign-in), a guest session that discards
  everything on exit regardless of where the profile lives.
- The image gives the container 1 second to stop, which kills Chrome before it saves open tabs.
  `stop_grace_period: 15s` fixes it. **End party** usually takes about 4 seconds and never more than 15.

## The window

`ui/Iris.xaml` is a borderless WPF window drawn entirely by Iris: no system title bar, and the
close question is a sheet inside the window. The ring is the app's mark. It fills clockwise as the
four startup steps complete and empties when the party ends. Type is Sitka Display for headlines
and Segoe UI Variable for everything else, both shipped with Windows 11. Animation is skipped when
Windows has animations turned off.

## Network paths

| Purpose | Path | Reachable from |
|---|---|---|
| Web page and control | `https://<laptop>.<tailnet>.ts.net` via `tailscale serve` to `127.0.0.1:8080` | Tailnet and shared users |
| Video, fast path | UDP 59000 bound directly on the Tailscale address | Tailnet and shared users |
| Video, fallback | TCP 59000 via `tailscale serve` to `127.0.0.1:59000` | Tailnet and shared users |

Docker publishes the web and TCP ports on loopback only, so nothing listens on Wi-Fi.

## Security model

| Threat | Defence |
|---|---|
| Strangers on the internet or your Wi-Fi reaching Iris | Nothing is published publicly. Ports are on loopback or the Tailscale address only. |
| Someone on your tailnet who is not invited | Every account has its own password. Unknown names and wrong passwords are refused. |
| A guest (or a web page in the shared browser) reaching your laptop, router or other devices | The firewall rejects all traffic to private ranges and the Tailscale range, DNS included (lookups go through Docker's resolver on loopback). Verified by probing from inside the container. |
| The lockdown silently not applying | Iris checks the firewall's result and shuts the party down if it failed. |
| A website in the shared browser attacking your real files or browser | It runs in a container with no access to your files. Privilege escalation is disabled, memory is capped at 6 GB. |
| Browsing traces left behind | Fresh mode: the container is deleted on **End party**. Saved mode keeps them on purpose, in a Docker volume only Iris mounts. |
| Third parties learning who is watching | The default Google STUN server is replaced with a dead-end address. |
| A removed guest staying or coming back | Removing a guest deletes their account and ends their session through neko's API, which disconnects them at once. Without that last step neko keeps an existing session valid until it restarts (tested). |

### Known limits

- **Chrome runs with `--no-sandbox`** in these images. Chrome's own sandbox is off, so isolation rests
  on the container, `no-new-privileges`, the memory cap and the network lockdown. Firefox kept its
  sandbox but cannot play DRM video, which was the deciding factor.
- **In Saved mode, guests can use whatever you are signed in to** in the shared browser while the
  party runs, because anyone can take control. Sign out of anything you would not hand them.
- **Passwords are stored in plain text** in `people.json`, in your user profile. The copy the shared
  browser reads is hashed.
- **Invite links contain the guest's password**, so they sit in chat history and browser history.
  Remove and re-add a guest to issue a new one.
- **The limit on shared users lives in the Tailscale policy, not in Iris.** It restricts them to
  ports 443 and 59000. If the policy is reset, or the laptop's Tailscale address changes, they can
  reach every open port again until the rule is updated. See [GUESTS.md](GUESTS.md).
- **The lockdown starts a moment after the browser.** The firewall container can only join the
  browser's network once it exists, so Chrome's first second or two (in Saved mode, reopening
  your tabs) runs before the rules apply. Nobody can drive the browser until Iris goes live.

## Why it is built this way

| Decision | Reason |
|---|---|
| Shared browser instead of a sync extension | Works on any site and gives everyone control. The cost is that picture quality depends on this laptop's upload. |
| Chrome, not Firefox | Equal performance in testing, and Chrome plays Widevine DRM video; Firefox in neko returned `NotSupportedError`. See PERFORMANCE.md. |
| H.264, not the default VP8 | The default ran at 25 fps and about 2 Mbps. Every viewer's browser decodes H.264 in hardware. |
| NVENC through `nvautogpuh264enc` | Moves encoding to the RTX 4060: 60 fps with the GPU at about 25% instead of five CPU cores. The older `nvh264enc` fails on driver 610 ("Selected preset not supported"). |
| `tune=ultra-low-latency`, no B-frames, `zero-reorder-delay` | Each frame is sent as soon as it is encoded. |
| 10 Mbps constant bitrate | Clean 1080p60 for films. The laptop's measured upload is 63 Mbps, enough for several guests. |
| Tailscale instead of port forwarding | No public exposure, no router changes, encrypted, and access is per person. |
| Web and TCP through `tailscale serve`, UDP bound directly | `tailscale serve` cannot forward UDP. UDP is the low-lag path, TCP stays as the fallback. |
| One Tailscale address in `NEKO_WEBRTC_NAT1TO1` | The server rejects two IPv4 addresses ("invalid address rewrite mapping"). So the host also uses the Tailscale URL, not localhost. |
| Dead-end STUN at `192.0.2.1` | An empty list falls back to Google's server. A loopback address makes Firefox viewers never answer the video offer. `192.0.2.1` is a reserved documentation address that goes nowhere. |
| Tailscale address read on every start | It can change if you sign out, reinstall or rename the laptop. |
| `file` member provider with one account per person | Individual links that can be revoked. The file is re-read on each login, so changes apply without a restart. Passwords in it must be SHA-256, base64 encoded. |
| Firewall as a separate one-shot container | It needs network-admin rights that the browser container should not have. |
| No auto-restart | After a reboot nothing is running or published until you open Iris. |
| Image updated on each start | An outdated browser is the larger risk compared with trusting the publisher's latest image. |

## Accounts

`people.json` is the source of truth:

```json
{
  "host":   { "name": "Host", "password": "..." },
  "guests": [ { "name": "Maya", "password": "..." } ]
}
```

The first start creates it with a random host password. On every start and every change, Iris
writes `data/members.json` from it, plus `iris.admin`: an admin that can only use the API, with a
new random password each launch, which Iris uses to disconnect a guest the moment they are removed.
The host is the only admin who can watch. Guests can watch, take control and use the clipboard.
Names are case-sensitive in links, and each account can be connected from one device at a time.
