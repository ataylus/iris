# Performance

Measured on 2026-11-17 on this laptop: Ryzen 7 7840HS (16 threads), RTX 4060 Laptop GPU
(driver 610.74), Docker Desktop on WSL2. Upload 63 Mbps, download 101 Mbps (Cloudflare speed test).

## How it was measured

`tools/bench.mjs` starts a neko container per configuration, plays a 1080p test video in the shared
browser, joins as a viewer from a windowless Edge, and samples for 10 seconds:

| Metric | Source |
|---|---|
| Stream fps, Mbps | Viewer's WebRTC stats (`framesDecoded`, `bytesReceived`) |
| Jitter buffer | Viewer's `jitterBufferDelay / jitterBufferEmittedCount`; the delay the viewer adds to smooth arrival |
| Frame gap and its spread | Viewer's `totalInterFrameDelay` and `totalSquaredInterFrameDelay`; the stutter an average fps hides |
| Audio concealed or stretched | Viewer's `concealedSamples` and inserted/removed samples, as a share of audio received |
| Shared Chrome drops | `getVideoPlaybackQuality()` in the test page, counted only while sampling |
| Freezes, lost packets | Viewer's WebRTC stats |
| Container CPU | `docker stats`, where 100% is one core |
| GPU | `nvidia-smi` inside the container (overall %, encoder %) |

Viewer-side numbers come from a headless browser on the same laptop, so they reflect the
encoder and stream, not a real internet path.

## Results

| Configuration | Stream fps | Mbps | Container CPU | GPU | Notes |
|---|---|---|---|---|---|
| Original (Firefox, VP8, neko defaults) | 22.6 | 1.9 to 6.9 | 3.1 to 5.6 cores | | Capped at 25 fps |
| Firefox, x264 30 fps, 8 Mbps | 26.9 | 7.2 | 3.5 cores | | |
| Firefox, x264 60 fps, 10 Mbps | 54.1 | 9.0 | 5.1 cores | | Too hot for a laptop |
| Firefox, NVENC 60 fps, 10 Mbps | 53.9 | 7.2 | 1.0 core | 12%, encoder 27% | |
| **Chrome, NVENC 60 fps, 10 Mbps** | **53.9** | **7.3** | **0.9 core** | **13%, encoder 27%** | **Chosen** |

All configurations: 1080p, no freezes, no lost packets. The shared browser itself rendered at a
steady 60 fps in every test.

Every configuration above stopped at 54 fps. That turned out not to be Iris at all: see "The 54 fps
clock bug" below. With it fixed, the chosen configuration delivers 60.

## Check on the running Iris, before the clock fix

Joining as a guest from a windowless Firefox while 1080p video played:

| Stream fps | Mbps | Jitter buffer | Freezes | Lost | Audio | GPU | Container CPU |
|---|---|---|---|---|---|---|---|
| 54 | 9.0 | 18 ms | 0 | 0 | Yes | 13%, encoder 27% | 1.1 cores |

Edge gave the same result.

## The 54 fps clock bug

Watching on the laptop felt slightly juddery even though every number above looked clean. Averages
hide uneven frame timing, so `viewer.mjs` and `bench.mjs` now also report `frameGapMs` and
`frameGapSpreadMs`. Tracing frames step by step on 2026-11-17:

| Where | Frames per second |
|---|---|
| Screen capture (`ximagesrc` debug log) | 60 |
| Encoder output reaching neko (`appsink` debug log) | 60 |
| Packets leaving the container (`tcpdump` RTP timestamps) | 60, by the container's clock |
| Viewer, UDP or TCP, Edge or Firefox | 54, by Windows' clock, with zero packets lost |

Everything was scaled by exactly 0.9 (asking for 30 gave 27), regardless of encoder, resolution or
browser. The kernel's `adjtimex` showed `tick: 9167` instead of 10000: the shared WSL2 kernel was
running its clock at 92% speed, and Hyper-V snapped it back every few seconds. The cause was
`systemd-timesyncd` in the Ubuntu WSL distro fighting Hyper-V's own time sync. All WSL distros and
Docker Desktop share that one kernel, so Ubuntu's service skewed the clock inside the containers too.

Disabling it (see TROUBLESHOOTING.md) fixed it:

| | Before | After |
|---|---|---|
| Stream fps | 54 | 59.9 |
| Gap between frames | 18.5 ms | 16.7 ms |
| Viewer jitter buffer | 60 to 120 ms | 39 ms |

Measured again after the fix, over the real path (Firefox viewer, through Tailscale to the live
stack, 1080p test video playing):

| Path | RTT | fps | Mbps | Frame gap | Jitter buffer | Lost | Audio concealed | Shared Chrome drops |
|---|---|---|---|---|---|---|---|---|
| UDP | 1 ms | 60 | 10.0 | 16.7 ± 1.8 ms | 12.5 ms | 0 | 0% | 0 during playback |

Changing the kernel clock source (`clocksource=hyperv_clocksource_tsc_page` in `.wslconfig`) was
tried first and did not help, so it was reverted. Iris now reads the kernel tick on every start and
warns in the window if it is off by more than 0.5%.

## Timings

Measured 2026-11-18 through the window, with the images already downloaded:

| Action | Time |
|---|---|
| Containers created to live | 7 to 13 s (the health check probes every second while starting) |
| Opening Iris while a party is already running | 3 s |
| Switching Saved/Fresh | 15 to 21 s |
| End party | 4 s |

## DRM

`tools/drm.mjs` asks each shared browser for Widevine from a secure `localhost` page:

| Browser | Widevine |
|---|---|
| Chrome (`google-chrome`) | Yes |
| Firefox (`firefox`) | No (`NotSupportedError`) |

Streaming services typically limit software Widevine (L3) on Linux to 720p, and some refuse it.
That has not been tested against real services.

## What "no lag" means here

Streaming a browser always adds some delay: capture, encode, network and decode. The settings keep
each step short (zero-latency encoder tuning, no B-frames, a one-frame queue that drops instead of
waiting, UDP first). The part Iris cannot control is the internet path between you and a guest.
Tailscale connects directly when it can and relays when it cannot; a relayed connection adds
noticeable delay. Check with `tailscale ping <guest-device>` during a party: `via DERP` means relayed.

## Rerunning

From the `tools` folder, with Iris stopped or running (the benchmark uses its own ports 8090 and 59010):

```powershell
node bench.mjs baseline nvenc_chrome      # any names from the configs list in bench.mjs
node viewer.mjs firefox "<invite link>"    # measures a live Iris as that guest
node drm.mjs google-chrome                 # Widevine check
```
