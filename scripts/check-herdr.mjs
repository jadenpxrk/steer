import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, writeFile, readFile, access, rm } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import assert from 'node:assert/strict';
// Runs only disposable Herdr panes. Requires Herdr, Node, and macOS script/stty.
const root = await mkdtemp('/tmp/steer-herdr-');
const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('HERDR_')));
Object.assign(env, { XDG_CONFIG_HOME: join(root, 'config'), XDG_STATE_HOME: join(root, 'state'), HERDR_CONFIG_PATH: join(root, 'config.toml'), HERDR_SESSION: 'fixture-a', TERM: 'xterm-256color' });
await writeFile(env.HERDR_CONFIG_PATH, `[terminal]\ndefault_shell = "/bin/sh"\nshell_mode = "non_login"\nnew_cwd = "${root}"\n`);
const bin = process.env.STEER_HERDR_BIN ?? execFileSync('/bin/sh', ['-c', 'command -v herdr'], { encoding: 'utf8' }).trim();
env.PATH = dirname(bin) + ':' + env.PATH;
const source = readFileSync(new URL('../ios/Steer/Services/MuxDiscovery.swift', import.meta.url), 'utf8');
const children = [];
function run(args, session = 'fixture-a') { return execFileSync(bin, ['--session', session, ...args], { env, cwd: root, encoding: 'utf8', timeout: 6000, stdio: ['ignore', 'pipe', 'pipe'] }); }
async function until(check, label) {
  const end = Date.now() + 8000;
  while (Date.now() < end) { try { if (await check()) return; } catch {} await new Promise(r => setTimeout(r, 25)); }
  throw new Error('Timed out: ' + label);
}
const server = spawn(bin, ['server'], { env, cwd: root, stdio: 'ignore' });
children.push(server);
function stream(mode, pane, cols, rows) {
  const child = spawn(bin, ['--session', 'fixture-a', 'terminal', 'session', mode, pane, ...(mode === 'control' ? ['--takeover'] : []), '--cols', String(cols), '--rows', String(rows)], { env, cwd: root, stdio: ['pipe', 'pipe', 'pipe'] });
  children.push(child); child.stderr.resume();
  const frames = []; let pending = '';
  child.stdout.on('data', chunk => {
    pending += chunk;
    let split;
    while ((split = pending.indexOf('\n')) >= 0) {
      const line = pending.slice(0, split); pending = pending.slice(split + 1);
      try {
        const event = JSON.parse(line);
        if (event.type === 'terminal.frame') {
          frames.push(event);
        }
      } catch {}
    }
  });
  return { child, frames };
}
try {
  await until(() => { run(['api', 'snapshot']); return true; }, 'owned server API');
  run(['workspace', 'create', '--cwd', root, '--label', 'Steer synthetic sizing regression']);
  run(['tab', 'create', '--label', 'Second tab']);
  const secondServer = spawn(bin, ['--session', 'fixture-b', 'server'], { env, cwd: root, stdio: 'ignore' });
  children.push(secondServer);
  await until(() => { run(['api', 'snapshot'], 'fixture-b'); return true; }, 'second owned server');
  run(['workspace', 'create', '--cwd', root, '--label', 'Second server'], 'fixture-b');
  const sessions = JSON.parse(run(['session', 'list', '--json'])).sessions;
  assert.deepEqual(sessions.filter(s => s.running).map(s => s.name), ['fixture-a', 'fixture-b']);
  const tabs = JSON.parse(run(['tab', 'list'])).result.tabs;
  const allPanes = JSON.parse(run(['pane', 'list'])).result.panes;
  assert.equal(tabs.length, 2);
  assert.deepEqual(allPanes.map(p => p.tab_id), tabs.map(t => t.tab_id));
  assert.deepEqual(JSON.parse(run(['agent', 'list'])).result.agents, [], 'ordinary tabs must be discovered through pane list');
  const otherPane = JSON.parse(run(['pane', 'list'], 'fixture-b')).result.panes[0];
  assert.equal(otherPane.pane_id, allPanes[0].pane_id, 'pane IDs collide across named servers');
  const previewTemplate = source.match(/static func herdrPaneRead[\s\S]*?herdr\("(.*?)", session:/)[1];
  function preview(pane, session) {
    const command = "herdr --session '" + session + "' " + previewTemplate
      .replaceAll('\\(ShellQuote.posixSingle(paneID))', "'" + pane + "'")
      .replaceAll('\\(source)', 'visible');
    return execFileSync('/bin/sh', ['-c', command], { env, encoding: 'utf8', timeout: 6000 });
  }
  for (const [index, target] of allPanes.entries()) {
    run(['pane', 'run', target.pane_id, `printf '\\033[31mPREVIEW_TAB_${index}\\033[0m\\n'`]);
    await until(() => preview(target.pane_id, 'fixture-a').includes(`PREVIEW_TAB_${index}`), 'plain tab preview');
    assert.ok(preview(target.pane_id, 'fixture-a').includes('\x1b['), 'preview returns raw ANSI');
  }
  run(['pane', 'run', otherPane.pane_id, "printf 'OTHER_SERVER_ONLY\\n'"], 'fixture-b');
  await until(() => preview(otherPane.pane_id, 'fixture-b').includes('OTHER_SERVER_ONLY'), 'named server preview');
  assert.ok(!preview(otherPane.pane_id, 'fixture-b').includes('PREVIEW_TAB_0'));
  assert.ok(!preview(allPanes[0].pane_id, 'fixture-a').includes('OTHER_SERVER_ONLY'));
  const panes = JSON.parse(run(['pane', 'list']));
  const serialized = JSON.stringify(panes);
  const ids = [...serialized.matchAll(/"(?:pane_id|id)":"(w[^" ]*:p[^" ]*)"/g)].map(x => x[1]);
  assert.ok(ids.length > 0, 'fixture pane must exist');
  const pane = ids.at(-1);
  const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  // BSD script accepts a pipe, but rejects the socket Node uses for child stdin.
  const desktopCommand = 'stty cols 120 rows 40; exec ' + quote(bin) + ' --session fixture-a';
  const desktop = spawn('/bin/sh', ['-c', 'cat | /usr/bin/script -q /dev/null /bin/sh -c ' + quote(desktopCommand)],
    { env, cwd: root, stdio: ['pipe', 'pipe', 'pipe'] });
  let desktopOutput = '';
  desktop.stdout.on('data', data => { desktopOutput = (desktopOutput + data).slice(-2000); });
  desktop.on('exit', code => { if (code) console.log('desktop fixture failed', JSON.stringify(desktopOutput)); });
  desktop.stderr.on('data', data => { desktopOutput += data; });
  children.push(desktop);
  const program = [
    "const fs = require('node:fs');",
    'const root = ' + JSON.stringify(root) + ';',
    "process.stdin.setRawMode(true); process.stdin.resume();",
    "process.stdout.write('\\x1b[?1049h\\x1b[?1000h\\x1b[?1006h');",
    "function draw() {",
    " const cols = process.stdout.columns, rows = process.stdout.rows;",
    " fs.writeFileSync(root + '/size', rows + ' ' + cols);",
    " process.stdout.write('\\x1b[2J\\x1b[H\\x1b[31;1m┌' + '─'.repeat(Math.max(0, cols-2)) + '┐' +",
    "  '\\x1b[2;1H│ SYNTHETIC TUI ' + cols + 'x' + rows + '\\x1b[2;' + cols + 'H│' +",
    "  '\\x1b[' + rows + ';1H└' + '─'.repeat(Math.max(0, cols-2)) + '┘\\x1b[0m');",
    "}",
    "draw(); process.stdout.on('resize', draw);",
    "process.stdin.on('data', data => fs.appendFileSync(root + '/received', data));",
    "fs.writeFileSync(root + '/ready', 'ready');",
    "setInterval(() => { if (fs.existsSync(root + '/stop')) process.exit(0); }, 25);"
  ].join('\n');
  await writeFile(join(root, 'capture.cjs'), program);
  run(['pane', 'run', pane, quote(process.execPath) + ' ' + quote(join(root, 'capture.cjs'))]);
  await until(async () => { await access(join(root, 'ready')); return true; }, 'raw TUI capture');
  const size = async () => (await readFile(join(root, 'size'), 'utf8')).trim();
  await until(async () => Number((await size()).split(' ')[1]) > 80, 'desktop layout');
  assert.equal(desktop.exitCode, null, 'desktop client must stay connected');
  const desktopSize = await size();
  const mobile = stream('control', pane, 43, 28);
  await until(async () => (await size()) === '28 43', 'phone PTY layout');
  const textOf = frame => Buffer.from(frame.bytes, 'base64').toString().replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '');
  await until(() => mobile.frames.some(f => f.width === 43 && f.height === 28 &&
    textOf(f).includes('SYNTHETIC TUI')), 'phone ANSI frame');
  const frame = mobile.frames.findLast(f => textOf(f).includes('SYNTHETIC TUI'));
  assert.equal(frame.width, 43);
  assert.equal(frame.height, 28);
  assert.ok(Buffer.from(frame.bytes, 'base64').includes(Buffer.from('\x1b[')), 'native frame retains ANSI');
  const parts = ['héllo\n\n', '\r', '\x1b[A', '\x1b[200~paste\nme\x1b[201~', '\0', 'after'];
  const expected = Buffer.concat(parts.map(x => Buffer.from(x)));
  mobile.child.stdin.write(parts.map(text => JSON.stringify({ type: 'terminal.input', bytes: Buffer.from(text).toString('base64') })).join('\n') + '\n');
  await until(async () => (await readFile(join(root, 'received'))).length >= expected.length, 'native input bytes');
  assert.deepEqual(await readFile(join(root, 'received')), expected);
  mobile.child.stdin.write(JSON.stringify({ type: 'terminal.scroll', direction: 'up', lines: 2, source: 'wheel', column: 3, row: 2 }) + '\n');
  await until(async () => (await readFile(join(root, 'received'))).length > expected.length, 'native mouse wheel');
  const wheel = (await readFile(join(root, 'received'))).subarray(expected.length).toString();
  assert.ok(wheel.includes('\x1b[<64;4;3M'), 'touch scroll must be a wheel event, not command history');
  assert.ok(!wheel.includes('\x1b[A'));

  for (const [cols, rows] of [[43, 12], [78, 20], [43, 28]]) {
    mobile.child.stdin.write(JSON.stringify({ type: 'terminal.resize', cols, rows }) + '\n');
    await until(async () => (await size()) === rows + ' ' + cols, 'phone keyboard/orientation resize');
    await until(() => mobile.frames.some(f => f.width === cols && f.height === rows), 'resized ANSI frame');
  }
  desktop.stdin.write('\x1b');
  await new Promise(resolve => setTimeout(resolve, 150));
  assert.equal(desktop.exitCode, null, 'desktop input must reach a live client');
  assert.equal(await size(), '28 43', 'desktop input must not override phone sizing');
  mobile.child.stdin.end(JSON.stringify({ type: 'terminal.release' }) + '\n');
  await until(async () => (await size()) === desktopSize, 'release restores desktop dimensions');
  const reopened = stream('control', pane, 43, 28);
  await until(async () => (await size()) === '28 43', 'returning reacquires phone size');
  reopened.child.kill('SIGTERM');
  await until(async () => (await size()) === desktopSize, 'disconnect restores desktop dimensions');
  console.log('PASS: scoped previews; native phone-sized ANSI; exact input bytes; wheel scrolling; keyboard/orientation resizing; desktop input cannot change phone size; release and disconnect restore desktop size.');

} finally {
  await writeFile(join(root, 'stop'), 'stop');
  for (const session of ['fixture-a', 'fixture-b']) { try { run(['server', 'stop'], session); } catch {} }
  for (const child of children) {
    child.stdin?.end();
    if (child.exitCode === null) child.kill('SIGTERM');
  }
  await rm(root, { recursive: true, force: true });
}
