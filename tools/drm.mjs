// Usage: node drm.mjs <image>   Reports whether Widevine DRM is available inside the given neko image.
import { execFileSync } from 'node:child_process';
const sleep = ms => new Promise(r => setTimeout(r, ms));
const sh = (args) => { try { return execFileSync('docker', args, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, MSYS_NO_PATHCONV: '1' } }).trim(); } catch (e) { return `ERR ${(e.stderr || '').toString().slice(0, 200)}`; } };

const image = process.argv[2];
sh(['rm', '-f', 'iris-drm']);
sh(['run', '-d', '--name', 'iris-drm', '--shm-size', '2g', '-e', 'NEKO_MEMBER_MULTIUSER_USER_PASSWORD=x', `ghcr.io/m1k1o/neko/${image}:latest`]);
for (let i = 0; i < 60 && sh(['inspect', '-f', '{{.State.Health.Status}}', 'iris-drm']) !== 'healthy'; i++) await sleep(2000);
await sleep(75000);
const probe = `data:text/html,<title>WV=checking</title><script>navigator.requestMediaKeySystemAccess('com.widevine.alpha',[{initDataTypes:['cenc'],videoCapabilities:[{contentType:'video/mp4; codecs="avc1.42E01E"',robustness:'SW_SECURE_CRYPTO'}]}]).then(a=>a.createMediaKeys()).then(()=>document.title='WV=yes').catch(e=>document.title='WV=no '+e.name)</script>`;
const xdo = (...a) => sh(['exec', '-u', 'neko', '-e', 'DISPLAY=:99.0', 'iris-drm', 'xdotool', ...a]);
const cls = image.includes('chrome') ? 'google-chrome' : 'firefox';
xdo('search', '--onlyvisible', '--class', cls, 'windowactivate', '--sync', 'key', '--clearmodifiers', 'ctrl+t');
await sleep(1000);
const html = decodeURIComponent(probe.slice('data:text/html,'.length));
execFileSync('docker', ['exec', '-i', 'iris-drm', 'sh', '-c', 'mkdir -p /tmp/drm && cat > /tmp/drm/index.html'], { input: html });
console.log('server:', sh(['exec', '-d', 'iris-drm', 'sh', '-c', 'cd /tmp/drm && (python3 -m http.server 8765 || busybox httpd -f -p 8765)']) || 'started');
await sleep(2000);
xdo('key', '--clearmodifiers', 'ctrl+l');
xdo('type', '--delay', '5', 'http://localhost:8765/');
xdo('key', 'Return');
let title = '';
for (let i = 0; i < 24; i++) { await sleep(5000); title = xdo('search', '--name', 'WV=', 'getwindowname'); if (!title.includes('checking')) break; }
console.log(image, '=>', title);
console.log('cdm files:', sh(['exec', 'iris-drm', 'sh', '-c', 'ls -d /home/neko/.config/google-chrome/WidevineCdm/* /opt/google/chrome/WidevineCdm 2>&1 | head -3']));
sh(['rm', '-f', 'iris-drm']);
