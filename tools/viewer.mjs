// Usage: node viewer.mjs <edge|firefox> <url> [warmupSeconds=20]   Joins a neko room headlessly and reports decoded video stats over 10 s.
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [browser, url, warmup = 20] = process.argv.slice(2);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const wrap = 'window.__pcs=[];const P=window.RTCPeerConnection;window.RTCPeerConnection=function(...a){const p=new P(...a);window.__pcs.push(p);return p};window.RTCPeerConnection.prototype=P.prototype;';
const stats = `(async () => {
  const v = document.querySelector('video'); const out = {};
  if (v) Object.assign(out, { w: v.videoWidth, h: v.videoHeight, paused: v.paused });
  for (const pc of window.__pcs || []) { const s = await pc.getStats(); s.forEach(r => {
    if (r.type === 'inbound-rtp' && r.kind === 'video') Object.assign(out, { decoded: r.framesDecoded, bytes: r.bytesReceived, jb: r.jitterBufferDelay, jbn: r.jitterBufferEmittedCount, freezes: r.freezeCount, lost: r.packetsLost, decoder: r.decoderImplementation, codecId: r.codecId });
    if (r.type === 'codec' && r.mimeType && r.mimeType.startsWith('video')) out.codec = r.mimeType;
    if (r.type === 'inbound-rtp' && r.kind === 'audio') out.audioBytes = r.bytesReceived;
  }); }
  return JSON.stringify(out); })()`;

function rpc(ws) {
  let id = 0; const waiting = new Map();
  ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && waiting.has(d.id)) { waiting.get(d.id)(d); waiting.delete(d.id); } };
  return (method, params = {}) => new Promise(r => { waiting.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
}
const open = async u => { const ws = new WebSocket(u); await new Promise((ok, bad) => { ws.onopen = ok; ws.onerror = bad; }); return ws; };

const profile = mkdtempSync(join(tmpdir(), `iris-view-${browser}-`));
let proc, evaluate, ws;
if (browser === 'edge') {
  proc = spawn('C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe', ['--headless=new', '--no-first-run', '--remote-debugging-port=9333', `--user-data-dir=${profile}`, '--autoplay-policy=no-user-gesture-required', 'about:blank'], { stdio: 'ignore' });
  let target;
  for (let i = 0; i < 40 && !target; i++) { await sleep(500); try { target = (await (await fetch('http://127.0.0.1:9333/json/list')).json()).find(t => t.type === 'page'); } catch {} }
  ws = await open(target.webSocketDebuggerUrl); const send = rpc(ws);
  await send('Page.enable');
  await send('Page.addScriptToEvaluateOnNewDocument', { source: wrap });
  await send('Page.navigate', { url });
  evaluate = async () => JSON.parse((await send('Runtime.evaluate', { expression: stats, awaitPromise: true, returnByValue: true })).result.result.value);
} else {
  writeFileSync(join(profile, 'user.js'), 'user_pref("media.autoplay.default", 0);\nuser_pref("media.autoplay.blocking_policy", 0);\n');
  proc = spawn('C:\\Program Files\\Mozilla Firefox\\firefox.exe', ['-headless', '-no-remote', '-profile', profile, '--remote-debugging-port', '9334'], { stdio: 'ignore' });
  for (let i = 0; i < 40 && !ws; i++) { await sleep(500); try { ws = await open('ws://127.0.0.1:9334/session'); } catch {} }
  const send = rpc(ws);
  await send('session.new', { capabilities: {} });
  const context = (await send('browsingContext.getTree', {})).result.contexts[0].context;
  await send('script.addPreloadScript', { functionDeclaration: `() => { ${wrap} }` });
  await send('browsingContext.navigate', { context, url, wait: 'complete' });
  evaluate = async () => JSON.parse((await send('script.evaluate', { expression: stats, target: { context }, awaitPromise: true })).result.result.value);
}

await sleep(warmup * 1000);
const a = await evaluate(); const t0 = Date.now();
await sleep(10000);
const b = await evaluate(); const secs = (Date.now() - t0) / 1000;
console.log(JSON.stringify({
  browser, codec: b.codec, decoder: b.decoder, resolution: `${b.w}x${b.h}`, paused: b.paused,
  fps: b.decoded != null ? +((b.decoded - a.decoded) / secs).toFixed(1) : null,
  mbps: b.bytes != null ? +(((b.bytes - a.bytes) * 8) / secs / 1e6).toFixed(2) : null,
  jitterBufferMs: b.jbn > a.jbn ? +(((b.jb - a.jb) / (b.jbn - a.jbn)) * 1000).toFixed(1) : null,
  freezes: (b.freezes ?? 0) - (a.freezes ?? 0), lost: (b.lost ?? 0) - (a.lost ?? 0), audio: (b.audioBytes ?? 0) > (a.audioBytes ?? 0),
}));
try { ws.close(); } catch {}
proc.kill(); await sleep(2000);
try { rmSync(profile, { recursive: true, force: true }); } catch {}
