// Usage: node bench.mjs <configName> [...]   Benchmarks neko configurations; prints one JSON result per config.
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const sleep = ms => new Promise(r => setTimeout(r, ms));
const sh = (cmd, args, opts = {}) => execFileSync(cmd, args, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], ...opts }).trim();
const shSafe = (cmd, args, opts) => { try { return sh(cmd, args, opts); } catch (e) { return `ERR ${(e.stderr || e.message).toString().slice(0, 300)}`; } };

const VIDEO = 'https://test-videos.co.uk/vids/jellyfish/mp4/h264/1080/Jellyfish_1080_10s_30MB.mp4';
const page = `<!doctype html><body style="margin:0;background:#000;overflow:hidden">
<video id="v" autoplay muted loop playsinline style="width:100vw;height:100vh" src="${VIDEO}"></video>
<script>let n=0,last=performance.now();function f(t){n++;if(t-last>=1000){const q=v.getVideoPlaybackQuality();
document.title='fps='+n+' vdrop='+q.droppedVideoFrames+' vtotal='+q.totalVideoFrames+' t='+v.currentTime.toFixed(1);n=0;last=t}
requestAnimationFrame(f)}requestAnimationFrame(f)</script></body>`;

const x264 = (fps, kbps, preset) => `ximagesrc display-name={display} show-pointer=false use-damage=false ! video/x-raw,framerate=${fps}/1 ! videoconvert ! video/x-raw,format=I420 ! queue max-size-buffers=1 leaky=downstream ! x264enc threads=8 bitrate=${kbps} vbv-buf-capacity=300 key-int-max=${fps * 2} bframes=0 byte-stream=true tune=zerolatency speed-preset=${preset} ! video/x-h264,stream-format=byte-stream,profile=constrained-baseline ! appsink name=appsink`;
const nvenc = (fps, kbps) => `ximagesrc display-name={display} show-pointer=false use-damage=false ! video/x-raw,framerate=${fps}/1 ! videoconvert n-threads=4 ! video/x-raw,format=NV12 ! queue max-size-buffers=1 leaky=downstream ! nvautogpuh264enc preset=p4 tune=ultra-low-latency rate-control=cbr bitrate=${kbps} vbv-buffer-size=${kbps} gop-size=${fps * 2} b-frames=0 zero-reorder-delay=true repeat-sequence-header=true ! video/x-h264,stream-format=byte-stream,profile=constrained-baseline ! appsink name=appsink`;

const configs = {
  baseline:      { image: 'firefox', fps: 30 },
  x264_30:       { image: 'firefox', fps: 30, codec: 'h264', pipeline: x264(30, 8000, 'veryfast') },
  x264_60:       { image: 'firefox', fps: 60, codec: 'h264', pipeline: x264(60, 10000, 'veryfast') },
  nvenc_firefox: { image: 'nvidia-firefox', gpu: true, fps: 60, codec: 'h264', pipeline: nvenc(60, 10000) },
  nvenc_chrome:  { image: 'nvidia-google-chrome', gpu: true, fps: 60, codec: 'h264', pipeline: nvenc(60, 10000) },
  cpu_chrome:    { image: 'google-chrome', fps: 30, codec: 'h264', pipeline: x264(30, 8000, 'veryfast') },
};

async function cdp(wsUrl) {
  const ws = new WebSocket(wsUrl);
  await new Promise((ok, bad) => { ws.onopen = ok; ws.onerror = bad; });
  let id = 0; const waiting = new Map();
  ws.onmessage = m => { const d = JSON.parse(m.data); if (waiting.has(d.id)) { waiting.get(d.id)(d); waiting.delete(d.id); } };
  return {
    send: (method, params = {}) => new Promise(r => { waiting.set(++id, r); ws.send(JSON.stringify({ id, method, params })); }),
    close: () => ws.close(),
  };
}

const viewerStats = `(async () => {
  const v = document.querySelector('video'); const out = {};
  if (v) { const q = v.getVideoPlaybackQuality(); Object.assign(out, { w: v.videoWidth, h: v.videoHeight, shown: q.totalVideoFrames, dropped: q.droppedVideoFrames }); }
  for (const pc of window.__pcs || []) { const s = await pc.getStats(); s.forEach(r => {
    if (r.type === 'inbound-rtp' && r.kind === 'video') Object.assign(out, { decoded: r.framesDecoded, bytes: r.bytesReceived, jb: r.jitterBufferDelay, jbn: r.jitterBufferEmittedCount, dec: r.totalDecodeTime, freezes: r.freezeCount, decoder: r.decoderImplementation, lost: r.packetsLost, ifd: r.totalInterFrameDelay, ifd2: r.totalSquaredInterFrameDelay });
    if (r.type === 'candidate-pair' && r.nominated && r.state === 'succeeded') out.rtt = r.currentRoundTripTime;
  }); }
  return out; })()`;

async function run(name) {
  const c = configs[name];
  shSafe('docker', ['rm', '-f', 'iris-bench']);
  const args = ['run', '-d', '--name', 'iris-bench', '--shm-size', '2g', '-p', '127.0.0.1:8090:8080', '-p', '127.0.0.1:59010:59010/udp',
    '-e', `NEKO_DESKTOP_SCREEN=1920x1080@${c.fps}`, '-e', 'NEKO_MEMBER_MULTIUSER_USER_PASSWORD=bench', '-e', 'NEKO_MEMBER_MULTIUSER_ADMIN_PASSWORD=benchadmin',
    '-e', 'NEKO_WEBRTC_UDPMUX=59010', '-e', 'NEKO_WEBRTC_ICELITE=1', '-e', 'NEKO_WEBRTC_NAT1TO1=127.0.0.1',
    '-e', 'NEKO_WEBRTC_ICESERVERS_FRONTEND=[{"urls":["stun:192.0.2.1:3478"]}]', '-e', 'NEKO_WEBRTC_ICESERVERS_BACKEND=[{"urls":["stun:192.0.2.1:3478"]}]'];
  if (c.gpu) args.push('--gpus', 'all', '-e', 'NVIDIA_DRIVER_CAPABILITIES=all', '-e', 'GST_DEBUG=2');
  if (c.codec) args.push('-e', `NEKO_CAPTURE_VIDEO_CODEC=${c.codec}`, '-e', 'NEKO_CAPTURE_VIDEO_IDS=main', '-e', `NEKO_CAPTURE_VIDEO_PIPELINES=${JSON.stringify({ main: c.pipeline })}`);
  args.push(`ghcr.io/m1k1o/neko/${c.image}:latest`);
  const started = shSafe('docker', args, { timeout: 600000 });
  if (started.startsWith('ERR')) return { name, error: started };
  for (let i = 0; i < 60 && sh('docker', ['inspect', '-f', '{{.State.Health.Status}}', 'iris-bench']) !== 'healthy'; i++) await sleep(2000);

  const env = { ...process.env, MSYS_NO_PATHCONV: '1' };
  sh('docker', ['exec', '-i', 'iris-bench', 'sh', '-c', 'mkdir -p /tmp/b && cat > /tmp/b/bench.html'], { input: page, env });
  // Served over localhost because Chrome's policy blocks file:// pages.
  spawn('docker', ['exec', '-d', 'iris-bench', 'python3', '-m', 'http.server', '8765', '-d', '/tmp/b'], { env, stdio: 'ignore' });
  const xdo = (...a) => shSafe('docker', ['exec', '-u', 'neko', '-e', 'DISPLAY=:99.0', 'iris-bench', 'xdotool', ...a], { env });
  await sleep(12000);
  const cls = c.image.includes('chrome') ? 'google-chrome' : 'firefox';
  xdo('search', '--onlyvisible', '--class', cls, 'windowactivate', '--sync', 'key', '--clearmodifiers', 'ctrl+t');
  await sleep(1000);
  xdo('key', '--clearmodifiers', 'ctrl+l');
  xdo('type', '--delay', '10', 'http://localhost:8765/bench.html');
  xdo('key', 'Return');
  await sleep(2000);
  xdo('key', 'F11');

  const profile = mkdtempSync(join(tmpdir(), 'iris-bench-'));
  const edge = spawn('C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    ['--headless=new', '--disable-gpu', '--no-first-run', '--remote-debugging-port=9333', `--user-data-dir=${profile}`, '--autoplay-policy=no-user-gesture-required', 'about:blank'], { stdio: 'ignore' });
  let target;
  for (let i = 0; i < 30 && !target; i++) { await sleep(500); try { target = (await (await fetch('http://127.0.0.1:9333/json/list')).json()).find(t => t.type === 'page'); } catch {} }
  const tab = await cdp(target.webSocketDebuggerUrl);
  await tab.send('Page.enable');
  await tab.send('Page.addScriptToEvaluateOnNewDocument', { source: 'window.__pcs=[];const P=window.RTCPeerConnection;window.RTCPeerConnection=function(...a){const p=new P(...a);window.__pcs.push(p);return p};window.RTCPeerConnection.prototype=P.prototype;' });
  await tab.send('Page.navigate', { url: 'http://127.0.0.1:8090/?usr=viewer&pwd=bench' });
  await sleep(25000);

  const sample = async () => (await tab.send('Runtime.evaluate', { expression: viewerStats, awaitPromise: true, returnByValue: true })).result?.result?.value || {};
  const cpu = [];
  const a = await sample(); const t0 = Date.now();
  const inner = [];
  for (let i = 0; i < 5; i++) {
    await sleep(2000);
    cpu.push(parseFloat(sh('docker', ['stats', '--no-stream', '--format', '{{.CPUPerc}}', 'iris-bench'])));
    inner.push(xdo('search', '--name', 'fps=', 'getwindowname'));
  }
  const b = await sample(); const secs = (Date.now() - t0) / 1000;
  let gpu = '';
  if (c.gpu) gpu = shSafe('docker', ['exec', 'iris-bench', 'nvidia-smi', '--query-gpu=utilization.gpu,utilization.encoder', '--format=csv,noheader']);
  const log = shSafe('docker', ['logs', '--tail', '600', 'iris-bench']).split('\n').map(l => l.replace(/\x1b\[[0-9;]*m/g, ''))
    .filter(l => /ERR|error|fail|nvenc|cuda|not-negotiated|gst/i.test(l) && !/401|preflight|X event error/.test(l)).slice(-8).map(l => l.slice(0, 300));

  tab.close(); edge.kill(); await sleep(1500);
  try { rmSync(profile, { recursive: true, force: true }); } catch {}
  shSafe('docker', ['rm', '-f', 'iris-bench']);

  const innerFps = inner.map(t => +(/fps=(\d+)/.exec(t)?.[1] ?? NaN)).filter(n => !isNaN(n));
  const lastInner = inner.at(-1) || '';
  return {
    name, image: c.image,
    streamFps: b.decoded != null ? +((b.decoded - a.decoded) / secs).toFixed(1) : null,
    streamMbps: b.bytes != null ? +(((b.bytes - a.bytes) * 8) / secs / 1e6).toFixed(2) : null,
    jitterBufferMs: b.jbn > a.jbn ? +(((b.jb - a.jb) / (b.jbn - a.jbn)) * 1000).toFixed(1) : null,
    // Spread of the gaps between displayed frames: the stutter that an average fps hides.
    frameGapMs: b.decoded > a.decoded ? +(((b.ifd - a.ifd) / (b.decoded - a.decoded)) * 1000).toFixed(1) : null,
    frameGapSpreadMs: b.decoded > a.decoded ? +(Math.sqrt(Math.max(0, (b.ifd2 - a.ifd2) / (b.decoded - a.decoded) - ((b.ifd - a.ifd) / (b.decoded - a.decoded)) ** 2)) * 1000).toFixed(1) : null,
    decodeMsPerFrame: b.decoded > a.decoded ? +(((b.dec - a.dec) / (b.decoded - a.decoded)) * 1000).toFixed(2) : null,
    viewerDropped: (b.dropped ?? 0) - (a.dropped ?? 0), freezes: (b.freezes ?? 0) - (a.freezes ?? 0), lost: (b.lost ?? 0) - (a.lost ?? 0),
    resolution: `${b.w}x${b.h}`, decoder: b.decoder,
    sharedBrowserFps: innerFps, sharedBrowserVideo: lastInner.replace(/^.*?(vdrop=\S+ vtotal=\S+ t=\S+).*$/, '$1'),
    containerCpuPct: cpu, gpu, log,
  };
}

for (const name of process.argv.slice(2)) console.log(JSON.stringify(await run(name)));
