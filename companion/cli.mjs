#!/usr/bin/env node
import { readFile, mkdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import { createCompanion } from './server.mjs';
import { readJSON, saveJSON, requireValue, validDeviceToken } from './http.mjs';

const shellQuote = value => `'${value.replaceAll("'", "'\\''")}'`;
const cliPath = fileURLToPath(import.meta.url);
const hookEvents = ['SessionStart', 'UserPromptSubmit', 'PermissionRequest', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'SessionEnd'];

// Matches the hook with or without a pinned node binary.
const isSteerHook = (existing, command) => existing === command
  || (typeof existing === 'string' && existing.endsWith(` ${shellQuote(cliPath)} hook`));

export function installHooks(settings, command, remove = false) {
  requireValue(settings && typeof settings === 'object' && !Array.isArray(settings), 'Invalid Claude settings');
  const result = structuredClone(settings);
  result.hooks ??= {};
  requireValue(typeof result.hooks === 'object' && !Array.isArray(result.hooks), 'Invalid Claude hooks');
  for (const event of hookEvents) {
    const entries = result.hooks[event] ?? [];
    requireValue(Array.isArray(entries), `Invalid ${event} hooks`);
    result.hooks[event] = entries.map(entry => {
      requireValue(Array.isArray(entry.hooks), `Invalid ${event} hook group`);
      return { ...entry, hooks: entry.hooks.filter(hook => !isSteerHook(hook.command, command)) };
    }).filter(entry => entry.hooks.length > 0);
    if (!remove) result.hooks[event].push({ ...(event === 'PreToolUse' ? { matcher: 'AskUserQuestion' } : {}),
      hooks: [{ type: 'command', command, timeout: ['PermissionRequest', 'PreToolUse'].includes(event) ? 330 : 10 }] });
    if (!result.hooks[event].length) delete result.hooks[event];
  }
  return result;
}

export async function run(args = process.argv.slice(2)) {
  const directory = process.env.STEER_HOME || join(homedir(), '.steer');
  const configPath = join(directory, 'companion.json');
  const action = args[0];
  if (action === 'hook') {
    try {
      const event = await readJSON(process.stdin);
      const waitsForInput = event.hook_event_name === 'PermissionRequest' || event.hook_event_name === 'PreToolUse';
      const config = JSON.parse(await readFile(configPath, 'utf8'));
      requireValue(Number.isInteger(config.port) && config.port > 0 && config.port < 65536);
      const response = await fetch(`http://127.0.0.1:${config.port}/v1/hooks`, {
        method: 'POST', headers: { authorization: `Bearer ${config.token}`, 'content-type': 'application/json' },
        body: JSON.stringify(event), signal: AbortSignal.timeout(waitsForInput ? 310000 : 5000),
      });
      if (response.ok && waitsForInput) process.stdout.write(JSON.stringify(await response.json()));
    } catch { /* Unavailable helper leaves Claude's own permission flow in control. */ }
    return;
  }
  if (action === 'install' || action === 'uninstall') {
    const path = args[1] ? resolve(args[1]) : join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'settings.json');
    let settings = {};
    try { settings = JSON.parse(await readFile(path, 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    // Resolve node from PATH at hook time so Node upgrades (nvm, Homebrew) don't break the hooks.
    const node = `"$(command -v node || printf %s ${shellQuote(process.execPath)})"`;
    const command = `STEER_HOME=${shellQuote(directory)} ${node} ${shellQuote(cliPath)} hook`;
    await saveJSON(path, installHooks(settings, command, action === 'uninstall'));
    process.stdout.write(action === 'install' ? 'Steer hooks installed. Start the companion, then restart Claude Code.\n' : 'Steer hooks removed. Restart Claude Code.\n');
    return;
  }
  requireValue(action === 'serve', 'Usage: node companion/cli.mjs serve|install|uninstall [settings-file]');
  await mkdir(directory, { recursive: true, mode: 0o700 });
  let config;
  try { config = JSON.parse(await readFile(configPath, 'utf8')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  config ??= { port: 43197, token: randomBytes(32).toString('hex') };
  requireValue(Number.isInteger(config.port) && config.port > 0 && config.port < 65536 && validDeviceToken(config.token) && config.token.length === 64, 'Invalid companion configuration');
  const companion = await createCompanion({ directory, token: config.token,
    codexDirectory: join(process.env.CODEX_HOME || join(homedir(), '.codex'), 'sessions') });
  try {
    await new Promise((resolve, reject) => {
      companion.server.once('error', reject);
      companion.server.listen(config.port, '127.0.0.1', resolve);
    });
    await saveJSON(configPath, config);
  } catch (error) {
    await companion.close();
    throw error;
  }
  process.stdout.write('Steer companion listening on loopback. Connect through SSH in the app.\n');
  let stopping = false;
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => {
    if (stopping) return;
    stopping = true;
    await companion.close();
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  run().catch(() => { process.stderr.write('Steer companion failed. Check the command, file permissions, and configuration.\n'); process.exitCode = 1; });
}
