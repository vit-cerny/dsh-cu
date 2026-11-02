// Self test: prove the primitives actually work on this machine.
// Launches Notepad, types a marker, reads it back, then checks capture,
// monitor filtering and window enumeration. Cleans up after itself.
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const CLI = join(HERE, 'bin', 'dsh-cu.mjs');

function cu(...args) {
  const out = execFileSync(process.execPath, [CLI, ...args], { encoding: 'utf8', timeout: 180000 });
  return JSON.parse(out);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const results = [];
function check(name, pass, detail) {
  results.push({ name, pass });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? ' :: ' + detail : ''}`);
}

try {
  const monitors = cu('monitors');
  check('monitors', monitors.ok && monitors.monitors.length >= 1,
    monitors.monitors.map((m) => `#${m.index} ${m.width}x${m.height}`).join(', '));

  const first = monitors.monitors[0];

  cu('act', 'launch', '--target', 'notepad.exe');

  let np = null;
  for (let i = 0; i < 20 && !np; i++) {
    await sleep(700);
    try {
      np = cu('windows').windows.find((w) => /notepad/i.test(w.title));
    } catch { /* window list can race with startup */ }
  }
  check('launch notepad', Boolean(np), np ? `"${np.title}" on monitor ${np.monitor}` : 'not found in 14s');
  if (!np) throw new Error('notepad never appeared');

  const focused = cu('act', 'focus', '--window', 'Notepad');
  check('focus window', focused.ok === true, `hwnd ${focused.hwnd}`);
  await sleep(400);

  // Click inside the window: typing without keyboard focus loses the first
  // character on a freshly activated window.
  cu('act', 'click', '--x', String(Math.round(np.x + np.width / 2)),
    '--y', String(Math.round(np.y + np.height * 0.45)));
  await sleep(400);

  const marker = 'dsh-cu-test-' + Date.now().toString().slice(-6);
  cu('act', 'type', '--text', marker);
  await sleep(700);

  const read = cu('read', '--window', 'Notepad');
  check('type and read back', read.text === marker,
    read.text === marker ? 'text round-tripped' : `read "${String(read.text).slice(0, 80)}"`);

  const shot = cu('shot', '--window', 'Notepad');
  check('window screenshot', shot.ok === true, shot.path);

  const monShot = cu('shot', '--monitor', String(first.index));
  check('monitor screenshot', monShot.ok === true && monShot.monitor === first.index,
    `monitor ${monShot.monitor}`);

  // With a monitor pinned, a coordinate on a different monitor must be refused.
  let refused = false;
  if (monitors.monitors.length >= 2) {
    const other = monitors.monitors[1];
    try {
      cu('act', 'click', '--x', String(other.x + 50), '--y', '50', '--monitor', String(first.index));
    } catch (e) {
      refused = /not the selected monitor/.test(String(e.message));
    }
    check('monitor pin refuses off-monitor click', refused);
  } else {
    console.log('SKIP  monitor pin check (single monitor)');
  }

  const keys = cu('act', 'key', '--keys', 'shift');
  check('key dispatch', keys.ok === true, keys.method);

  cu('act', 'launch', '--target', 'taskkill');
  try {
    execFileSync('taskkill', ['/IM', 'notepad.exe', '/F'], { stdio: 'ignore' });
  } catch { /* already gone */ }

  const failed = results.filter((r) => !r.pass).length;
  console.log(`\n${results.length - failed}/${results.length} checks passed`);
  process.exit(failed ? 1 : 0);
} catch (e) {
  console.error('SELF TEST ERROR:', e.message);
  process.exit(1);
}