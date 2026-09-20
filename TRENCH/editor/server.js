// TRENCH - settings panel + sound engine for the Bodycam battlefield mod.
// Serves app.html, reads/writes the mod's settings.ini, tails sound_events.txt written by
// the mod and streams it to the page (Server-Sent Events), which plays the whistles and the
// background war with WebAudio. Opens itself as an Edge app window (its own Windows frame, no
// browser chrome). No npm packages: `node server.js`.
const http = require('http');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');

const EDITOR = __dirname;
const MOD = path.join(EDITOR, '..');
const SOURCES = path.join(EDITOR, 'sources');
const SOUNDS = path.join(MOD, 'sounds');
const MARKERS = path.join(EDITOR, 'markers.json');
const SETTINGS = path.join(MOD, 'settings.ini');
const CONFIG = path.join(MOD, 'config.json');
const EVENTS = path.join(MOD, 'sound_events.txt');
const MATCH = path.join(MOD, 'match_state.txt');
const POSE = path.join(MOD, 'pose.txt');
const GAME_SETTINGS = path.join(process.env.LOCALAPPDATA || '', 'Bodycam', 'Saved', 'SaveGames', 'GlobalUserSettings.sav');
const PORT = 8765;
const URL_ = `http://localhost:${PORT}`;
const CLIP = /^(whistle|impact|fire)_\d+\.wav$/;
const TITLE = 'TRENCH';

// Same defaults as Scripts/features.lua; keys the page does not show are kept as they are.
const DEFAULTS = {
  matchMinutes: 10, myTeam: 12, enemyTeam: 12, artillery: 1, artilleryMode: 'random',
  artilleryClass: '/Game/BodycamWeapons/Core/Blueprint/Grenade/Grenade.Grenade_C',
  artilleryMinDelay: 6, artilleryMaxDelay: 15, artilleryShells: 6, artilleryShellGap: 1,
  artilleryMinDist: 12, artilleryMaxDist: 40, artilleryFlight: 7, artilleryBattery: 900,
  artilleryFlash: 2, artilleryKillRadius: 5, artilleryHitsMe: 1,
  sound: 1, soundVolume: 80, soundSync: 0, soundImpact: 0, ambience: 1,
};

// ---------------------------------------------------------------- console look
const A = { reset: '\x1b[0m', bold: '\x1b[1m', dim: '\x1b[2m', red: '\x1b[38;5;203m',
            amber: '\x1b[38;2;255;157;28m', hot: '\x1b[38;2;255;198;90m', warm: '\x1b[38;2;150;84;12m' };
const visible = s => s.replace(/\x1b\[[0-9;]*m/g, '').length;
const stamp = () => new Date().toTimeString().slice(0, 8);
const line = (icon, color, text) => console.log(`  ${A.warm}${stamp()}${A.reset}  ${color}${icon}${A.reset}  ${text}`);
const ok = t => line('+', A.amber, t), fail = t => line('!', A.red, t), info = t => line('-', A.warm, t);

// The banner is the same ink grid the page draws, squeezed into half-block rows.
const INK = { ' ': 0, '.': 1, ':': 2, '+': 3, '#': 4 };
const RAMP = [null, [96, 46, 6], [158, 82, 12], [214, 126, 20], [255, 176, 58]];
const fg = l => `\x1b[38;2;${RAMP[l][0]};${RAMP[l][1]};${RAMP[l][2]}m`;
const bg = l => `\x1b[48;2;${RAMP[l][0]};${RAMP[l][1]};${RAMP[l][2]}m`;
function logo(width = 100) {
  let rows;
  try { rows = fs.readFileSync(path.join(EDITOR, 'logo.txt'), 'utf8').split(/\r?\n/).filter(l => l.length); }
  catch { return ''; }
  const cols = Math.max(...rows.map(r => r.length));
  width = Math.min(width, cols);               // never stretch the dot grid
  // Nearest dot, not the strongest in a block: the grid is one mark per cell, and averaging
  // or maxing over neighbours is exactly what turned the wordmark to mush before.
  const at = (y, c) => {
    const r = rows[y]; if (!r) return 0;
    return INK[r[Math.min(cols - 1, Math.round((c + 0.5) * cols / width - 0.5))]] || 0;
  };
  const out = [];
  for (let y = 0; y < rows.length; y += 2) {
    let s = '  ', curFg = -1, curBg = -1;              // only emit a code when the ink changes
    const want = (f, b) => {
      let e = '';
      if (b !== curBg) { e += b ? bg(b) : '\x1b[49m'; curBg = b; }
      if (f !== curFg) { e += f ? fg(f) : '\x1b[39m'; curFg = f; }
      return e;
    };
    for (let c = 0; c < width; c++) {
      const t = at(y, c), b = at(y + 1, c);
      if (!t && !b) { s += want(0, 0) + ' '; }
      else if (t && !b) { s += want(t, 0) + '▀'; }
      else if (!t && b) { s += want(b, 0) + '▄'; }
      else { s += want(t, b) + '▀'; }
    }
    out.push(s + A.reset);
  }
  return out.join('\n');
}
function box(text) {
  const w = visible(text) + 4;
  return [`  ${A.warm}┌${'─'.repeat(w)}┐${A.reset}`,
          `  ${A.warm}│${A.reset}  ${text}  ${A.warm}│${A.reset}`,
          `  ${A.warm}└${'─'.repeat(w)}┘${A.reset}`].join('\n');
}
function banner() {
  process.stdout.write(`\x1b]0;${TITLE}\x07\x1b[2J\x1b[H\n`);
  console.log(logo() + '\n');
  console.log(box(`${A.hot}●${A.reset} ${A.bold}running${A.reset}   ${A.amber}${URL_}${A.reset}`));
  console.log(`  ${A.dim}the panel opens by itself · closing it stops this too${A.reset}\n`);
}

// ---------------------------------------------------------------- files
const read = (f, d = '') => { try { return fs.readFileSync(f, 'utf8'); } catch { return d; } };
function parseIni(text) {
  const s = { ...DEFAULTS };
  for (const l of text.split(/\r?\n/)) {
    const m = l.match(/^\s*(\w+)\s*=\s*(.*?)\s*$/);
    if (m && m[1] in DEFAULTS) s[m[1]] = typeof DEFAULTS[m[1]] === 'number' ? (Number(m[2]) || 0) : m[2];
  }
  return s;
}
const iniText = s => Object.keys(DEFAULTS).sort().map(k => `${k}=${s[k]}`).join('\n') + '\n';
function writeSettings(s) {
  const merged = { ...parseIni(read(SETTINGS)), ...s };
  fs.writeFileSync(SETTINGS, iniText(merged));
  // Player ceiling stays at 64 so in-game hotkeys can go past the panel's values.
  fs.writeFileSync(CONFIG, '{\n  "maxPlayers": 64,\n  "maxBotsPerTeam": 32\n}\n');
  lastSettings = read(SETTINGS);
  return merged;
}
// ---------------------------------------------------------------- presets
// One file per preset plus an index of "preset_N|Name" - the layout the mod already reads.
const PRESETS = path.join(MOD, 'presets');
const INDEX = path.join(PRESETS, 'index.txt');
// Which preset was last chosen, so a restart comes back to it instead of to the defaults.
const LAST = path.join(PRESETS, 'last.txt');
const lastPreset = () => read(LAST).trim();
function rememberPreset(file) {
  try { fs.mkdirSync(PRESETS, { recursive: true }); fs.writeFileSync(LAST, file); } catch {}
}
function presetList() {
  return read(INDEX).split(/\r?\n/).map(l => l.match(/^(\w+)\|(.*)$/)).filter(Boolean)
    .map(m => ({ file: m[1], name: m[2], last: m[1] === lastPreset() }));
}
function writeIndex(list) {
  fs.mkdirSync(PRESETS, { recursive: true });
  fs.writeFileSync(INDEX, list.map(p => p.file + '|' + p.name).join('\n') + '\n');
}
function savePreset(name) {
  const list = presetList(), used = new Set(list.map(p => p.file));
  let n = 1;
  while (used.has('preset_' + n)) n++;          // reuse a number a delete freed up
  const file = 'preset_' + n;
  fs.mkdirSync(PRESETS, { recursive: true });
  fs.writeFileSync(path.join(PRESETS, file + '.ini'), iniText(parseIni(read(SETTINGS))));
  list.push({ file, name });
  writeIndex(list);
  ok('saved preset ' + name);
  return list;
}
function clips() {
  return read(path.join(SOUNDS, 'sounds.ini')).split(/\r?\n/).map(l => l.match(/^(\w+)=([\d.]+)$/)).filter(Boolean)
    .map(m => ({ name: m[1], length: Number(m[2]) }));
}
function gameVolume() {
  const raw = read(GAME_SETTINGS);
  const get = k => { const m = raw.match(new RegExp(`"${k} Volume":([\\d.]+)`)); return m ? Number(m[1]) / 100 : 1; };
  const master = get('Master');
  return { fx: master * get('Effects'), amb: master * get('Ambient'), master };
}
function inMatch() {
  try { return Date.now() - fs.statSync(MATCH).mtimeMs < 12000 && read(MATCH).trim() === '1'; } catch { return false; }
}

// ---------------------------------------------------------------- live stream (SSE)
const clients = new Set();
let everConnected = false, lastSettings = read(SETTINGS), eventsPos = -1, lastState = '', lastSeen = Date.now();
const push = (type, data) => { const msg = `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`; for (const c of clients) c.write(msg); };
const state = () => ({ inMatch: inMatch(), volume: gameVolume() });
// Events the mod appends: seq|kind|delay|x|y|z|listenerX|listenerY|listenerZ|listenerYaw
setInterval(() => {
  let size = 0;
  try { size = fs.statSync(EVENTS).size; } catch { return; }
  if (eventsPos < 0 || size < eventsPos) { eventsPos = size; return; }
  if (size === eventsPos) return;
  const fd = fs.openSync(EVENTS, 'r'), buf = Buffer.alloc(size - eventsPos);
  fs.readSync(fd, buf, 0, buf.length, eventsPos); fs.closeSync(fd);
  const text = buf.toString('ascii'), last = text.lastIndexOf('\n');
  if (last < 0) return;
  eventsPos += last + 1;
  for (const l of text.slice(0, last).split('\n')) {
    const p = l.trim().split('|');
    if (p.length < 10) continue;
    const n = p.slice(2).map(Number);
    push('shell', { kind: p[1], delay: n[0], x: n[1], y: n[2], z: n[3], lx: n[4], ly: n[5], lz: n[6], yaw: n[7] });
  }
}, 40);
setInterval(() => {
  const s = JSON.stringify(state());
  if (s !== lastState) { lastState = s; push('state', JSON.parse(s)); }
  const now = read(SETTINGS);
  if (now !== lastSettings) { lastSettings = now; push('settings', parseIni(now)); }
}, 1000);
// Your position and view direction (written by the mod 10x/s) drive the 3D listener in the page.
let lastPose = '';
setInterval(() => {
  const p = read(POSE).trim();
  if (!p || p === lastPose) return;
  lastPose = p;
  const n = p.split('|').map(Number);
  if (n.length === 4 && n.every(Number.isFinite)) push('pose', { x: n[0], y: n[1], z: n[2], yaw: n[3] });
}, 50);
// Close together with the app window.
setInterval(() => {
  if (everConnected && clients.size === 0 && Date.now() - lastSeen > 20000) { info('panel closed — stopping'); process.exit(0); }
}, 2000);


// ---------------------------------------------------------------- http
function send(res, code, type, body) { res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' }); res.end(body); }
const json = (res, obj, code = 200) => send(res, code, 'application/json', JSON.stringify(obj));
const body = req => new Promise(r => { const c = []; req.on('data', d => c.push(d)); req.on('end', () => r(Buffer.concat(c).toString('utf8'))); });
const TYPES = { '.html': 'text/html; charset=utf-8', '.wav': 'audio/wav', '.mp3': 'audio/mpeg', '.txt': 'text/plain; charset=utf-8', '.svg': 'image/svg+xml', '.ico': 'image/x-icon' };

const server = http.createServer(async (req, res) => {
  const url = decodeURIComponent(req.url.split('?')[0]);
  try {
    if (req.method === 'GET' && (url === '/' || url === '/app')) return send(res, 200, TYPES['.html'], fs.readFileSync(path.join(EDITOR, 'app.html')));
    if (req.method === 'GET' && url === '/lab') return send(res, 200, TYPES['.html'], fs.readFileSync(path.join(EDITOR, 'logo-lab.html')));
    // the wordmark and the window icon, straight out of the editor folder
    if (req.method === 'GET' && /^\/[\w.-]+\.(svg|ico)$/.test(url)) {
      const file = path.join(EDITOR, path.basename(url));
      if (!fs.existsSync(file)) return send(res, 404, 'text/plain', 'missing');
      return send(res, 200, TYPES[path.extname(file)], fs.readFileSync(file));
    }
    if (req.method === 'GET' && url === '/logo.txt') return send(res, 200, TYPES['.txt'], read(path.join(EDITOR, 'logo.txt')));
    if (req.method === 'GET' && (url.startsWith('/sources/') || url.startsWith('/sounds/'))) {
      const dir = url.startsWith('/sources/') ? SOURCES : SOUNDS, file = path.join(dir, path.basename(url));
      if (!fs.existsSync(file)) return send(res, 404, 'text/plain', 'missing');
      return send(res, 200, TYPES[path.extname(file)] || 'application/octet-stream', fs.readFileSync(file));
    }
    if (req.method === 'GET' && url === '/api/stream') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive' });
      clients.add(res); everConnected = true; lastSeen = Date.now();
      res.write(`event: state\ndata: ${JSON.stringify(state())}\n\n`);
      req.on('close', () => { clients.delete(res); lastSeen = Date.now(); });
      return;
    }
    if (url === '/api/settings') {
      if (req.method === 'GET') return json(res, parseIni(read(SETTINGS)));
      return json(res, writeSettings(JSON.parse(await body(req))));
    }
    if (url === '/api/presets') {
      if (req.method === 'GET') return json(res, presetList());
      const cmd = JSON.parse(await body(req));
      let list = presetList();
      const found = list.find(p => p.file === cmd.file);
      if (cmd.action === 'save') {
        list = savePreset(String(cmd.name || '').trim().slice(0, 24) || 'unnamed');
      } else if (cmd.action === 'load' && found) {
        // Straight onto settings.ini, which is what the mod re-reads once a second.
        writeSettings(parseIni(read(path.join(PRESETS, found.file + '.ini'))));
        push('settings', parseIni(read(SETTINGS)));
        rememberPreset(found.file);
        list = presetList();                      // so the reply carries the new 'last' flag
        ok('loaded ' + found.name);
      } else if (cmd.action === 'delete' && found) {
        try { fs.unlinkSync(path.join(PRESETS, found.file + '.ini')); } catch {}
        if (lastPreset() === found.file) rememberPreset('');
        list = list.filter(p => p !== found);
        writeIndex(list);
        ok('deleted ' + found.name);
      }
      push('presets', list);
      return json(res, list);
    }
    if (req.method === 'GET' && url === '/api/clips') return json(res, clips());
    if (req.method === 'GET' && url === '/markers') return send(res, 200, 'application/json', read(MARKERS, '{}'));
    if (req.method === 'POST' && url === '/save') {
      const data = JSON.parse(await body(req));
      fs.mkdirSync(SOUNDS, { recursive: true });
      for (const f of fs.readdirSync(SOUNDS)) if (CLIP.test(f)) fs.unlinkSync(path.join(SOUNDS, f));
      const ini = [];
      for (const clip of data.clips) {
        if (!CLIP.test(clip.name + '.wav')) continue;
        fs.writeFileSync(path.join(SOUNDS, clip.name + '.wav'), Buffer.from(clip.wav, 'base64'));
        ini.push(`${clip.name}=${clip.duration.toFixed(3)}`);
      }
      fs.writeFileSync(path.join(SOUNDS, 'sounds.ini'), ini.join('\n') + '\n');
      fs.writeFileSync(MARKERS, JSON.stringify(data.markers, null, 1));
      ok(`saved ${data.clips.length} whistle${data.clips.length === 1 ? '' : 's'}`);
      push('clips', clips());
      return json(res, { ok: true, count: data.clips.length });
    }
    send(res, 404, 'text/plain', 'not found');
  } catch (e) {
    fail(String(e.message || e));
    json(res, { ok: false, error: String(e.message || e) }, 500);
  }
});

// Chromeless Edge window with its own profile, so the autoplay flag applies even if Edge is open.
function openApp(page = '/') {
  if (process.env.NO_BROWSER) return;
  const profile = path.join(process.env.LOCALAPPDATA || MOD, 'Trench', 'edge');
  exec(`start "" msedge --app=${URL_}${page} --window-size=1030,1060 --user-data-dir="${profile}" --autoplay-policy=no-user-gesture-required`,
    err => { if (err) exec(`start "" ${URL_}${page}`); });
}

server.on('error', e => {
  if (e.code === 'EADDRINUSE') { banner(); info('already running — opening the panel'); openApp(); setTimeout(() => process.exit(0), 3000); }
  else fail(String(e.message || e));
});
// A launch starts where you left off: the preset you last chose, or the defaults if you have not
// chosen one. Hand-tweaked values are still not carried over - a named preset is.
// (Runs after lastSettings exists, or the assignment inside writeSettings would throw.)
const startedWith = (() => {
  const last = presetList().find(p => p.last);
  if (last) {
    try {
      writeSettings(parseIni(read(path.join(PRESETS, last.file + '.ini'))));
      return 'restored preset ' + last.name;
    } catch {}
  }
  writeSettings(DEFAULTS);
  return 'settings reset to defaults';
})();

server.listen(PORT, '127.0.0.1', () => { banner(); info(startedWith); openApp(); info('waiting for the panel'); });
