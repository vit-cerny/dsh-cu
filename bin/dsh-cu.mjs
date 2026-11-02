#!/usr/bin/env node
/**
 * dsh-cu: let an agent read the screen, click, and type on Windows.
 *
 * Windows only. No runtime dependencies. One short-lived PowerShell per action,
 * so nothing stays resident between calls.
 *
 * Commands:
 *   run "<goal>"        observe, decide, act, verify (needs a brain)
 *   shot                screenshot a monitor or window
 *   ocr                 read on-screen text with screen coordinates
 *   windows             list visible windows
 *   monitors            list monitors
 *   read                read a Win32 edit control's text
 *   start "<name>"      open an app through the Start menu
 *   open "<path|url>"   open a file, folder or URL with its default handler
 *   act <verb>          one primitive: click, type, key, focus, launch, scroll
 *   brain               show the resolved brain and whether it is reachable
 */
import { spawn } from 'node:child_process';
import { readFileSync, existsSync, mkdirSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, isAbsolute, resolve } from 'node:path';
import { homedir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = dirname(HERE);
const WINPS = join(ROOT, 'lib', 'win.ps1');

// ---------------------------------------------------------------------- argv
const argv = process.argv.slice(2);
const cmd = argv[0] ?? 'help';

function flag(name, fallback) {
  const i = argv.indexOf(`--${name}`);
  if (i < 0) return fallback;
  const next = argv[i + 1];
  if (next === undefined || next.startsWith('--')) return true;
  return next;
}
function has(name) { return argv.includes(`--${name}`); }
function num(name) {
  const v = flag(name);
  return v === undefined || v === true ? undefined : Number(v);
}
function words(after) {
  const i = argv.indexOf(after);
  if (i < 0) return [];
  const out = [];
  for (let j = i + 1; j < argv.length; j++) {
    if (argv[j].startsWith('--')) break;
    out.push(argv[j]);
  }
  return out;
}

// ---------------------------------------------------------------- primitives
function ps(request) {
  const payload = Buffer.from(JSON.stringify(request), 'utf8').toString('base64');
  return new Promise((res, rej) => {
    const child = spawn('powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', WINPS, '-Request', payload],
      { windowsHide: true });
    let out = '';
    let err = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { err += d; });
    child.on('error', rej);
    child.on('close', (code) => {
      const line = out.trim().split('\n').filter(Boolean).pop() ?? '';
      let parsed = null;
      try { parsed = JSON.parse(line); } catch { /* not JSON */ }
      if (!parsed) {
        return rej(new Error(`powershell exited ${code}: ${(err || out).trim().slice(0, 600)}`));
      }
      if (parsed.ok === false) return rej(new Error(parsed.error || 'action failed'));
      res(parsed);
    });
  });
}

// -------------------------------------------------------------------- config
const CONFIG_PATHS = () => [
  has('config') ? resolve(process.cwd(), String(flag('config'))) : null,
  join(process.cwd(), 'cu.config.json'),
  join(homedir(), '.dsh-cu', 'config.json'),
  join(ROOT, 'cu.config.json'),
].filter(Boolean);

function loadConfig() {
  let file = {};
  let used = null;
  for (const p of CONFIG_PATHS()) {
    if (!existsSync(p)) continue;
    try {
      file = JSON.parse(readFileSync(p, 'utf8'));
      used = p;
      break;
    } catch (e) {
      throw new Error(`${p} is not valid JSON: ${e.message}`);
    }
  }

  const b = file.brain ?? {};
  return {
    path: used,
    brain: {
      provider: process.env.CU_PROVIDER ?? b.provider ?? 'none',
      baseURL: process.env.CU_BASE_URL ?? b.baseURL ?? '',
      apiKey: process.env.CU_API_KEY ?? b.apiKey ?? '',
      model: process.env.CU_MODEL ?? b.model ?? '',
    },
    monitor: num('monitor') ?? file.monitor ?? 0,
    mode: flag('mode') ?? file.mode ?? 'foreground',
    maxSteps: num('steps') ?? file.maxSteps ?? 10,
    dryRun: has('dry-run') || file.dryRun === true,
    allowSend: has('allow-send') || file.allowSend === true,
  };
}

// -------------------------------------------------------------------- brains
// Every provider speaks one of two shapes: OpenAI-compatible chat completions,
// or the TypeSafe Jev decision API. That covers "any model you like" without a
// provider matrix.
const PRESETS = {
  typesafe: {
    kind: 'typesafe',
    baseURL: 'https://api.typesafe.ai/v1/systemone',
    model: 'jev-latest',
    keyVar: 'TYPESAFE_API_KEY',
  },
  openai: { kind: 'chat' },
};

/**
 * "session": reuse the model DSH is already running.
 *
 * DSH keeps its last used provider and model in the session cache, its routes
 * in the profile patch, and its keys in the credential store. Read those three
 * and hand back a normal chat brain. Returns null when nothing can be found.
 */
function resolveSession() {
  const home = process.env.DSH_HOME || join(homedir(), '.dsh');
  const profile = process.env.DSH_PROFILE || 'web';
  const patch = join(home, 'profiles', profile, 'cordis.patch.yml');
  const creds = join(home, '.credentials.yaml');
  if (!existsSync(patch) || !existsSync(creds)) return null;

  // Last provider/model DSH actually used. The cost ledger records one row per
  // provider:model with a call count, which is the most reliable source; the
  // session cache is the fallback.
  let provider = null;
  let model = null;

  const ledger = join(home, 'storages', 'cost-meter', 'ledger.json');
  if (existsSync(ledger)) {
    try {
      const j = JSON.parse(readFileSync(ledger, 'utf8'));
      const days = Object.keys(j.days ?? {}).sort().reverse();
      for (const d of days) {
        const rows = Object.entries(j.days[d]?.byProviderModel ?? {});
        if (!rows.length) continue;
        // Prefer the most used pair that day; ties go to the later entry.
        rows.sort((a, b) => (b[1]?.calls ?? 0) - (a[1]?.calls ?? 0));
        const [key] = rows[0];
        const cut = key.indexOf(':');
        if (cut > 0) { provider = key.slice(0, cut); model = key.slice(cut + 1); }
        break;
      }
    } catch { /* fall through */ }
  }

  if (!provider || !model) {
    const cacheDir = join(home, 'storages', 'session_projcache', 'sessions');
    if (existsSync(cacheDir)) {
      const files = readdirSync(cacheDir)
        .filter((f) => f.endsWith('.json'))
        .map((f) => ({ f, t: statSync(join(cacheDir, f)).mtimeMs }))
        .sort((a, b) => b.t - a.t)
        .slice(0, 12);
      for (const { f } of files) {
        const m = readFileSync(join(cacheDir, f), 'utf8').match(/"provider":"([^"]+)","model":"([^"]+)"/);
        if (m) { provider = m[1]; model = m[2]; break; }
      }
    }
  }
  if (!provider || !model) return null;

  // baseURL for that provider, from the profile's llm-pi-ai routes.
  // Providers sit at any indent under `providers:`, so match on the shape of
  // the line rather than a fixed column.
  const yml = readFileSync(patch, 'utf8');
  const lines = yml.split(/\r?\n/);
  let baseURL = '';
  let keyEnv = '';
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^(\s+)([\w.-]+):\s*$/);
    if (!m || m[2] !== provider) continue;
    const indent = m[1].length;
    for (let j = i + 1; j < lines.length; j++) {
      const line = lines[j];
      if (!line.trim()) continue;
      const lead = line.match(/^(\s*)/)[1].length;
      if (lead <= indent) break;
      if (!baseURL) baseURL = (line.match(/baseURL:\s*(\S+)/) || [])[1] ?? '';
      if (!keyEnv) keyEnv = (line.match(/apiKeyEnv:\s*(\S+)/) || [])[1] ?? '';
    }
    break;
  }
  if (!baseURL || !keyEnv) return null;

  const apiKey = (readFileSync(creds, 'utf8').match(new RegExp(`${keyEnv}:\\s*(\\S+)`)) || [])[1] ?? '';
  if (!apiKey) return null;

  return { name: 'session', kind: 'chat', baseURL, apiKey, model, note: `${provider}/${model}` };
}

function resolveBrain(cfg) {
  const b = cfg.brain;
  const name = String(b.provider || 'none').toLowerCase();
  if (name === 'none' || name === 'off' || name === '') return null;

  if (name === 'session') {
    const s = resolveSession();
    if (!s) {
      throw new Error('provider "session" could not read a model from DSH. '
        + 'Set CU_BASE_URL, CU_MODEL and CU_API_KEY, or pick another provider.');
    }
    return s;
  }

  const preset = PRESETS[name];
  if (!preset) {
    throw new Error(`unknown provider "${name}". Use: none, session, typesafe, openai`);
  }

  const apiKey = b.apiKey || process.env[preset.keyVar ?? ''] || '';
  const baseURL = b.baseURL || preset.baseURL || '';
  const model = b.model || preset.model || '';

  if (preset.kind === 'chat') {
    if (!baseURL) throw new Error('provider "openai" needs baseURL (e.g. https://host/v1)');
    if (!model) throw new Error('provider "openai" needs a model id');
  }
  if (!apiKey) throw new Error(`provider "${name}" needs an API key`);

  return { name, kind: preset.kind, baseURL, apiKey, model };
}

// -------------------------------------------------------------- observation
async function observe(cfg) {
  const req = { action: 'ocr' };
  if (cfg.monitor) req.monitor = cfg.monitor;
  const ocr = await ps(req);

  const wins = await ps({ action: 'windows', ...(cfg.monitor ? { monitor: cfg.monitor } : {}) });

  return {
    monitor: cfg.monitor || 'all',
    text: (ocr.text ?? '').slice(0, 3500),
    words: (ocr.words ?? []).slice(0, 220),
    windows: (wins.windows ?? []).slice(0, 25).map((w) => ({
      title: w.title, process: w.process, monitor: w.monitor,
      x: w.x, y: w.y, width: w.width, height: w.height, minimized: w.minimized,
    })),
  };
}

// --------------------------------------------------------------- the prompt
const SYSTEM = `You control a Windows desktop. Reply with exactly one JSON object and nothing else.

Actions:
{"action":"click","x":123,"y":456}            click screen coordinates
{"action":"type","text":"hello"}              type text into the focused field
{"action":"key","keys":["enter"]}             press keys, e.g. ["ctrl","s"], ["win"]
{"action":"start","query":"notepad"}          open an app via the Start menu
{"action":"open","path":"C:\\\\path\\\\file.txt"}  open a file, folder or URL
{"action":"focus","window":"Notepad"}         bring a window forward
{"action":"scroll","delta":-480}              scroll, negative is down
{"action":"wait","ms":800}                    wait for something to settle
{"action":"done","summary":"..."}             goal reached, say what proves it
{"action":"fail","reason":"..."}              cannot be done

Rules:
- Coordinates are absolute screen pixels. Take them from the words list.
- To open an app or file, prefer "start" or "open" over clicking around menus.
- To type into a window, "focus" it first, then click the text area, then "type".
- Never press Enter to send a message unless the goal explicitly says to send it.
- Verify before claiming success. Only use "done" when the screen shows it worked.`;

function buildUser(goal, obs, history) {
  const wins = obs.windows.length
    ? obs.windows.map((w) => `  "${w.title}" (${w.process}) at ${w.x},${w.y} ${w.width}x${w.height} monitor ${w.monitor}`).join('\n')
    : '  (none)';
  const text = obs.text ? obs.text.slice(0, 1500) : '(nothing readable)';
  const coords = obs.words.length
    ? obs.words.slice(0, 120).map((w) => `  "${w.text}" ${w.x},${w.y}`).join('\n')
    : '  (none)';
  const done = history.length
    ? history.map((h, i) => `  ${i + 1}. ${JSON.stringify(h)}`).join('\n')
    : '  (none yet)';

  return `Goal: ${goal}

Windows:
${wins}

Visible text:
${text}

Words with screen coordinates:
${coords}

Actions taken so far:
${done}`;
}

function parseJson(text) {
  const m = String(text).match(/\{[\s\S]*\}/);
  if (!m) throw new Error(`model did not return JSON: ${String(text).slice(0, 200)}`);
  return JSON.parse(m[0]);
}

async function decide(brain, goal, obs, history) {
  if (brain.kind === 'chat') {
    const url = `${brain.baseURL.replace(/\/$/, '')}/chat/completions`;
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${brain.apiKey}` },
      body: JSON.stringify({
        model: brain.model,
        temperature: 0,
        max_tokens: 300,
        messages: [
          { role: 'system', content: SYSTEM },
          { role: 'user', content: buildUser(goal, obs, history) },
        ],
      }),
      signal: AbortSignal.timeout(90000),
    });
    const raw = await res.text();
    if (!res.ok) throw new Error(`model HTTP ${res.status}: ${raw.slice(0, 300)}`);
    const body = JSON.parse(raw);
    return parseJson(body.choices?.[0]?.message?.content ?? '');
  }

  // TypeSafe Jev: a decision API. Offer the observed controls as choices and
  // let it pick the next operation, the same way jev's browser agent does.
  const controls = obs.words.slice(0, 40);
  const criteria = { DONE: 'The goal is visibly satisfied.', BLOCKED: 'No supported action can progress.' };
  controls.forEach((w, i) => { criteria[String(i + 1)] = `[${i + 1}] ${w.text} at ${w.x},${w.y}`; });

  const body = {
    model: brain.model,
    state: {
      page: { url: 'desktop', title: 'Windows desktop', text: obs.text.slice(0, 1200) },
      elements: controls.map((w, i) => ({ index: i + 1, label: w.text, operations: ['CLICK'] })),
      recent_actions: history.slice(-6),
    },
    questions: {
      operation: {
        type: 'choice',
        criteria,
        instructions: { goal, rules: `Goal: ${goal}. Choose the control to click next, or DONE when the goal is already satisfied on screen.` },
      },
    },
  };

  const res = await fetch(brain.baseURL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${brain.apiKey}` },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(60000),
  });
  const raw = await res.text();
  if (!res.ok) throw new Error(`typesafe HTTP ${res.status}: ${raw.slice(0, 300)}`);
  const parsed = JSON.parse(raw);
  const choice = parsed.answers?.operation?.choice;
  if (choice === 'DONE') return { action: 'done', summary: 'model reported the goal is satisfied' };
  if (choice === 'BLOCKED') return { action: 'fail', reason: 'model reported it cannot progress' };
  const idx = Number(choice);
  const target = controls[idx - 1];
  if (!target) return { action: 'fail', reason: `model chose unknown control ${choice}` };
  return { action: 'click', x: target.x + Math.round(target.w / 2), y: target.y + Math.round(target.h / 2) };
}

// ------------------------------------------------------------------ the loop
async function act(cfg, a) {
  if (cfg.dryRun) return;

  if (a.action === 'click') {
    await ps({ action: 'click', x: Math.round(a.x), y: Math.round(a.y), ...(cfg.monitor ? { monitor: cfg.monitor } : {}) });
  } else if (a.action === 'type') {
    await ps({ action: 'type', text: String(a.text ?? '') });
  } else if (a.action === 'key') {
    await ps({ action: 'key', keys: a.keys ?? [] });
  } else if (a.action === 'start') {
    await ps({ action: 'startmenu', query: String(a.query ?? '') });
  } else if (a.action === 'open') {
    await ps({ action: 'open', path: String(a.path ?? '') });
  } else if (a.action === 'focus') {
    await ps({ action: 'focus', window: String(a.window ?? '') });
  } else if (a.action === 'scroll') {
    await ps({ action: 'scroll', delta: a.delta ?? -480 });
  } else if (a.action === 'wait') {
    await new Promise((r) => setTimeout(r, a.ms ?? 600));
  } else {
    throw new Error(`model returned an unknown action: ${a.action}`);
  }
}

async function run(cfg) {
  const goal = words('run').join(' ').trim();
  if (!goal) throw new Error('usage: dsh-cu run "<goal>"');

  const brain = resolveBrain(cfg);
  if (!brain) throw new Error('no brain configured; run "dsh-cu brain" or set provider in cu.config.json');

  const history = [];
  for (let step = 1; step <= cfg.maxSteps; step++) {
    const obs = await observe(cfg);
    const action = await decide(brain, goal, obs, history);

    if (action.action === 'done') {
      return { ok: true, status: 'done', summary: action.summary, steps: history.length, history };
    }
    if (action.action === 'fail') {
      return { ok: false, status: 'failed', reason: action.reason, steps: history.length, history };
    }

    history.push(action);
    await act(cfg, action);
    await new Promise((r) => setTimeout(r, 350));
  }
  return { ok: false, status: 'max-steps', steps: history.length, history };
}

// ------------------------------------------------------------------- output
function print(o) { console.log(JSON.stringify(o, null, 2)); }

const HELP = `dsh-cu: Windows computer use for agents

  run "<goal>"        Observe, decide, act, verify (needs a brain)
  shot                Screenshot a monitor or window
  ocr                 Read on-screen text with screen coordinates
  windows             List visible windows
  monitors            List monitors
  read                Read a Win32 edit control's text
  start "<name>"      Open an app through the Start menu
  open "<path|url>"   Open a file, folder or URL
  act <verb>          One primitive: click, type, key, focus, launch, scroll
  brain               Show the resolved brain and test it

Options
  --monitor N         Restrict everything to monitor N (1-based); omit for all
  --mode MODE         foreground (default) or background
  --window "<title>"  Target a window by title substring
  --x N --y N         Coordinates for "act click"
  --text "..."        Text for "act type"
  --keys a,b          Keys for "act key", e.g. win, enter, ctrl+s
  --config <path>     Config file
  --steps N           Max steps for "run"
  --dry-run           Plan without acting
  --allow-send        Permit Enter in chat boxes (off by default)

Examples
  dsh-cu monitors
  dsh-cu ocr --monitor 2
  dsh-cu start "notepad"
  dsh-cu open "C:\\\\Users\\\\me\\\\notes.txt"
  dsh-cu act type --window Notepad --text "hello"
  dsh-cu run "open notepad and type hello"`;

async function main() {
  const cfg = loadConfig();

  switch (cmd) {
    case 'monitors':
      return print(await ps({ action: 'monitors' }));

    case 'windows':
      return print(await ps({ action: 'windows', ...(cfg.monitor ? { monitor: cfg.monitor } : {}) }));

    case 'shot': {
      const win = flag('window');
      return print(await ps(win
        ? { action: 'screenshot', window: win }
        : { action: 'screenshot', monitor: cfg.monitor || 1 }));
    }

    case 'ocr': {
      const win = flag('window');
      return print(await ps(win
        ? { action: 'ocr', window: win }
        : { action: 'ocr', monitor: cfg.monitor || 1 }));
    }

    case 'read':
      return print(await ps({ action: 'read', window: flag('window') }));

    case 'move': {
      const x = num('x'); const y = num('y');
      if (x === undefined || y === undefined) throw new Error('move needs --x and --y');
      const req = { action: 'move', window: flag('window'), x, y };
      if (num('width')) req.width = num('width');
      if (num('height')) req.height = num('height');
      return print(await ps(req));
    }

    case 'fit':
      return print(await ps({ action: 'fit', window: flag('window'), monitor: cfg.monitor || 1 }));

    case 'start': {
      const q = words('start').join(' ');
      if (!q) throw new Error('usage: dsh-cu start "<app name>"');
      return print(await ps({ action: 'startmenu', query: q }));
    }

    case 'open': {
      const p = words('open').join(' ');
      if (!p) throw new Error('usage: dsh-cu open "<file, folder or url>"');
      return print(await ps({ action: 'open', path: p }));
    }

    case 'act': {
      const verb = words('act')[0];
      if (!verb) throw new Error('usage: dsh-cu act click|type|key|focus|launch|scroll');
      const req = { action: verb };
      if (verb === 'click') {
        const x = num('x'); const y = num('y');
        if (x === undefined || y === undefined) throw new Error('click needs --x and --y');
        req.x = x; req.y = y;
        if (cfg.monitor) req.monitor = cfg.monitor;
        if (has('double')) req.double = true;
        if (flag('button')) req.button = flag('button');
        if (flag('uia')) req.uia = flag('uia');
        if (flag('window')) req.window = flag('window');
        if (cfg.mode === 'background') req.mode = 'background';
      }
      if (verb === 'type') {
        req.text = flag('text') ?? '';
        if (flag('window')) req.window = flag('window');
        if (has('click-into')) req.clickInto = true;
      }
      if (verb === 'key') {
        req.keys = String(flag('keys') ?? '').split(',').map((s) => s.trim()).filter(Boolean);
        if (flag('window')) req.window = flag('window');
      }
      if (verb === 'focus') req.window = flag('window');
      if (verb === 'launch') req.target = flag('target');
      if (verb === 'scroll') { req.delta = num('delta'); req.x = num('x'); req.y = num('y'); }
      return print(await ps(req));
    }

    case 'brain': {
      const b = resolveBrain(cfg);
      if (!b) return print({ ok: true, provider: 'none', note: 'no brain configured; commands that do not need a model still work' });
      const reachable = b.kind === 'chat'
        ? await testChat(b)
        : await testTypesafe(b);
      return print({
        ok: reachable.ok,
        provider: b.name,
        kind: b.kind,
        baseURL: b.baseURL,
        model: b.model,
        keyPresent: Boolean(b.apiKey),
        configFile: cfg.path,
        test: reachable,
      });
    }

    case 'run':
      return print(await run(cfg));

    case 'help':
    case '--help':
    case '-h':
      return console.log(HELP);

    default:
      throw new Error(`unknown command "${cmd}". Try: dsh-cu help`);
  }
}

async function testChat(b) {
  try {
    const res = await fetch(`${b.baseURL.replace(/\/$/, '')}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${b.apiKey}` },
      body: JSON.stringify({ model: b.model, max_tokens: 8, messages: [{ role: 'user', content: 'say ok' }] }),
      signal: AbortSignal.timeout(30000),
    });
    const raw = await res.text();
    return res.ok
      ? { ok: true, status: res.status }
      : { ok: false, status: res.status, detail: raw.slice(0, 200) };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

async function testTypesafe(b) {
  try {
    const res = await fetch(b.baseURL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${b.apiKey}` },
      body: JSON.stringify({
        model: b.model,
        state: { page: { url: 'test', title: 'test', text: 'A window with an OK button.' },
          elements: [{ index: 1, label: 'OK', operations: ['CLICK'] }], recent_actions: [] },
        questions: { operation: { type: 'choice', criteria: { '1': 'the OK button', DONE: 'done' }, instructions: { goal: 'click OK' } } },
      }),
      signal: AbortSignal.timeout(30000),
    });
    const raw = await res.text();
    return res.ok
      ? { ok: true, status: res.status, choice: JSON.parse(raw).answers?.operation?.choice }
      : { ok: false, status: res.status, detail: raw.slice(0, 200) };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

main().catch((e) => {
  console.error(`dsh-cu: ${e.message}`);
  process.exit(1);
});
