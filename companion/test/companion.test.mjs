import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createCompanion } from '../server.mjs';
import { readRecords, conversation } from '../transcript.mjs';
import { installHooks } from '../cli.mjs';

const token = 'test-only-companion-authentication';
async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'steer-companion-'));
  const transcriptPath = join(directory, 'transcript.jsonl');
  await writeFile(transcriptPath, `${JSON.stringify({ type: 'user', uuid: 'u1', message: { content: 'Hello' } })}\n`);
  const service = await createCompanion({ directory, token, watchWindow: Infinity, ...options });
  await new Promise(resolve => service.server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${service.server.address().port}`;
  const request = (path, method = 'GET', body, signal) => fetch(url + path, { method, signal,
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    ...(body ? { body: JSON.stringify(body) } : {}) });
  const hook = (hook_event_name, extra = {}, signal) => request('/v1/hooks', 'POST', {
    hook_event_name, session_id: 'session-a', cwd: directory, transcript_path: transcriptPath, ...extra,
  }, signal);
  t.after(async () => { await service.close(); await rm(directory, { recursive: true, force: true }); });
  return { directory, transcriptPath, service, url, request, hook };
}
async function waitForApproval(request) {
  for (let i = 0; i < 100; i++) {
    const { sessions } = await (await request('/v1/sessions')).json();
    const approval = sessions[0]?.approvals[0];
    if (approval) return approval;
    await delay(5);
  }
  assert.fail('Approval did not arrive');
}

test('authentication, hook discovery, structured conversation and archive persist', async t => {
  const { url, request, hook, directory } = await fixture(t);
  assert.equal((await fetch(url + '/v1/sessions')).status, 401);
  assert.equal((await hook('SessionStart')).status, 200);
  const detail = await (await request('/v1/conversations/claude%3Asession-a')).json();
  assert.equal(detail.messages[0].text, 'Hello');
  assert.equal(detail.session.status, 'idle');
  assert.equal('transcriptPath' in detail.session, false);
  assert.equal((await request('/v1/archive', 'POST', { sessionID: 'claude:session-a', archived: true })).status, 200);
  const state = JSON.parse(await readFile(join(directory, 'state.json'), 'utf8'));
  assert.equal(state.sessions[0].archived, true);
  assert.equal((await request('/v1/conversations/..%2Fetc%2Fpasswd')).status, 404);
});

test('approval binds the exact session, resolves once, and never creates persistent permissions', async t => {
  const { request, hook } = await fixture(t);
  const waiting = hook('PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'example command' } });
  const approval = await waitForApproval(request);
  assert.equal((await request('/v1/decisions', 'POST', { id: approval.id, sessionID: 'claude:other', decision: 'allow' })).status, 409);
  assert.equal((await request('/v1/archive', 'POST', { sessionID: 'claude:session-a', archived: true })).status, 409);
  const decision = { id: approval.id, sessionID: 'claude:session-a', decision: 'allow' };
  assert.equal((await request('/v1/decisions', 'POST', decision)).status, 200);
  assert.deepEqual(await (await waiting).json(), { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'allow' } } });
  assert.equal((await request('/v1/decisions', 'POST', decision)).status, 409);
});

test('expiry and session end leave normal permission handling in control', async t => {
  const { request, hook } = await fixture(t, { approvalTimeout: 150 });
  const waiting = hook('PermissionRequest', { tool_name: 'Bash', tool_input: {} });
  const approval = await waitForApproval(request);
  assert.deepEqual(await (await waiting).json(), {});
  assert.equal((await request('/v1/decisions', 'POST', { id: approval.id, sessionID: 'claude:session-a', decision: 'allow' })).status, 409);
  const next = hook('PermissionRequest', { tool_name: 'Write', tool_input: {} });
  await waitForApproval(request);
  await hook('SessionEnd');
  assert.deepEqual(await (await next).json(), {});
});

test('concurrent permissions remain separate and deny is explicit', async t => {
  const { request, hook } = await fixture(t);
  const first = hook('PermissionRequest', { tool_name: 'Write', tool_input: { file_path: '/example' } });
  const a = await waitForApproval(request);
  const second = hook('PermissionRequest', { session_id: 'session-b', tool_name: 'Read', tool_input: {} });
  let b;
  for (let i = 0; i < 100 && !b; i++) {
    const data = await (await request('/v1/sessions')).json();
    b = data.sessions.find(x => x.id === 'claude:session-b')?.approvals[0];
    if (!b) await delay(5);
  }
  assert.ok(b);
  await request('/v1/decisions', 'POST', { id: a.id, sessionID: 'claude:session-a', decision: 'deny' });
  assert.equal((await (await first).json()).hookSpecificOutput.decision.behavior, 'deny');
  await request('/v1/decisions', 'POST', { id: b.id, sessionID: 'claude:session-b', decision: 'allow' });
  assert.equal((await (await second).json()).hookSpecificOutput.decision.behavior, 'allow');
});

test('hook disconnect cancels pending approval', async t => {
  const { request, hook } = await fixture(t);
  const controller = new AbortController();
  const waiting = hook('PermissionRequest', { tool_name: 'Bash', tool_input: {} }, controller.signal).catch(() => {});
  const approval = await waitForApproval(request);
  controller.abort();
  await waiting;
  await delay(25);
  assert.equal((await request('/v1/decisions', 'POST', { id: approval.id, sessionID: 'claude:session-a', decision: 'allow' })).status, 409);
});

test('questions require complete answers for the exact request and preserve the original questions', async t => {
  const { request, hook } = await fixture(t);
  const questions = [{ question: 'Which mode?', header: 'Mode', options: [{ label: 'A' }, { label: 'B' }], multiSelect: true }];
  const waiting = hook('PreToolUse', { tool_name: 'AskUserQuestion', tool_input: { questions } });
  const approval = await waitForApproval(request);
  const body = { id: approval.id, sessionID: 'claude:session-a', answers: { 'Which mode?': 'A, B' } };
  assert.equal((await request('/v1/decisions', 'POST', { ...body, decision: 'allow' })).status, 400);
  assert.equal((await request('/v1/answers', 'POST', { ...body, answers: {} })).status, 400);
  assert.equal((await request('/v1/answers', 'POST', { ...body, sessionID: 'claude:other' })).status, 409);
  assert.equal((await request('/v1/answers', 'POST', body)).status, 200);
  assert.deepEqual(await (await waiting).json(), { hookSpecificOutput: {
    hookEventName: 'PreToolUse', permissionDecision: 'allow', updatedInput: { questions, answers: body.answers },
  } });
  assert.equal((await request('/v1/answers', 'POST', body)).status, 409);
  assert.equal((await hook('PreToolUse', { tool_name: 'Bash', tool_input: { command: 'wrong-tool' } })).status, 400);
});

test('restart cannot replay a pending approval', async t => {
  const { request, hook, service, directory } = await fixture(t);
  const waiting = hook('PermissionRequest', { tool_name: 'Read', tool_input: {} });
  const approval = await waitForApproval(request);
  await service.close();
  assert.deepEqual(await (await waiting).json(), {});
  const restarted = await createCompanion({ directory, token });
  await new Promise(resolve => restarted.server.listen(0, '127.0.0.1', resolve));
  t.after(() => restarted.close());
  const response = await fetch(`http://127.0.0.1:${restarted.server.address().port}/v1/decisions`, {
    method: 'POST', headers: { authorization: `Bearer ${token}` },
    body: JSON.stringify({ id: approval.id, sessionID: 'claude:session-a', decision: 'allow' }),
  });
  assert.equal(response.status, 409);
});

test('pending requests remain actionable even before the transcript file exists', async t => {
  const { request, hook, transcriptPath } = await fixture(t);
  await rm(transcriptPath);
  const waiting = hook('PermissionRequest', { tool_name: 'Read', tool_input: {} });
  const approval = await waitForApproval(request);
  const detail = await (await request('/v1/conversations/claude%3Asession-a')).json();
  assert.equal(detail.session.approvals[0].id, approval.id);
  assert.ok(detail.transcriptError);
  await request('/v1/decisions', 'POST', { id: approval.id, sessionID: 'claude:session-a', decision: 'deny' });
  assert.equal((await (await waiting).json()).hookSpecificOutput.decision.behavior, 'deny');
});

test('the actual hook CLI writes only the decision, and helper failure never emits an allow', async t => {
  const { request, service, directory, transcriptPath } = await fixture(t);
  await writeFile(join(directory, 'companion.json'), JSON.stringify({ port: service.server.address().port, token }));
  const cli = fileURLToPath(new URL('../cli.mjs', import.meta.url));
  function runHook(event) {
    const process = spawn(globalThis.process.execPath, [cli, 'hook'], { env: { ...globalThis.process.env, STEER_HOME: directory }, stdio: ['pipe', 'pipe', 'pipe'] });
    const output = [];
    const errors = [];
    process.stdout.on('data', chunk => output.push(chunk));
    process.stderr.on('data', chunk => errors.push(chunk));
    process.stdin.end(JSON.stringify(event));
    return new Promise((resolve, reject) => {
      process.on('error', reject);
      process.on('close', code => resolve({ code, output: Buffer.concat(output).toString(), errors: Buffer.concat(errors).toString() }));
    });
  }
  const event = { hook_event_name: 'PermissionRequest', session_id: 'session-a', cwd: directory, transcript_path: transcriptPath, tool_name: 'Read', tool_input: {} };
  const running = runHook(event);
  const approval = await waitForApproval(request);
  await request('/v1/decisions', 'POST', { id: approval.id, sessionID: 'claude:session-a', decision: 'deny' });
  const result = await running;
  assert.equal(result.code, 0);
  assert.equal(result.errors, '');
  assert.equal(JSON.parse(result.output).hookSpecificOutput.decision.behavior, 'deny');
  await service.close();
  const unavailable = await runHook(event);
  assert.deepEqual(unavailable, { code: 0, output: '', errors: '' });
});

test('hook installation preserves other commands and is reversible and idempotent', () => {
  const original = { model: 'existing', hooks: { Stop: [{ matcher: '*', hooks: [{ type: 'command', command: 'existing-hook' }] }] } };
  const installed = installHooks(original, 'steer-command');
  assert.deepEqual(installHooks(installed, 'steer-command'), installed);
  assert.deepEqual(installHooks(installed, 'steer-command', true), original);
  assert.equal(installed.hooks.PermissionRequest[0].hooks[0].timeout, 330);
  assert.throws(() => installHooks({ hooks: [] }, 'steer-command'));
});

test('bounded transcript tails skip partial records and deduplicate Claude streamed usage', async t => {
  const { transcriptPath } = await fixture(t);
  const message = { id: 'm1', content: [{ type: 'text', text: 'Draft' }], usage: { input_tokens: 10, output_tokens: 4, cache_read_input_tokens: 2 } };
  await writeFile(transcriptPath, [JSON.stringify({ type: 'assistant', message }), 'invalid',
    JSON.stringify({ type: 'assistant', message: { ...message, content: [{ type: 'text', text: 'Final' }] } }), '{"incomplete":'].join('\n'));
  const parsed = await readRecords(transcriptPath);
  const result = conversation(parsed.records, 'claude');
  assert.equal(result.messages.length, 1);
  assert.equal(result.messages[0].text, 'Final');
  assert.equal(result.usage.input, 10);
  assert.equal(result.usage.contextUsed, 12);
  assert.equal((await readRecords(transcriptPath, 80)).truncated, true);
});

test('Codex token totals, context and rate windows use the last reported snapshot', () => {
  const result = conversation([{ type: 'event_msg', payload: { type: 'token_count', info: {
    total_token_usage: { input_tokens: 120, output_tokens: 40, cached_input_tokens: 80 },
    last_token_usage: { total_tokens: 90 }, model_context_window: 1000,
  }, rate_limits: { primary: { used_percent: 25, window_minutes: 300, resets_at: 1700000000 } } } }], 'codex');
  assert.equal(result.usage.input, 120);
  assert.equal(result.usage.contextUsed, 90);
  assert.equal(result.usage.contextWindow, 1000);
  assert.equal(result.usage.rateLimits[0].usedPercent, 25);
});

test('Codex discovery reads session metadata without confusing histories for live sessions', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'steer-codex-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await mkdir(join(directory, '2026', '09'), { recursive: true });
  await writeFile(join(directory, '2026', '09', 'rollout.jsonl'), JSON.stringify({ type: 'session_meta', payload: {
    id: 'codex-a', cwd: '/example/project', base_instructions: { text: 'test instructions '.repeat(10000) },
  } }) + '\n');
  const { request } = await fixture(t, { codexDirectory: directory });
  const { sessions } = await (await request('/v1/sessions')).json();
  assert.equal(sessions[0].id, 'codex:codex-a');
  assert.equal(sessions[0].status, 'history');
});

test('Codex structured messages include freeform tool calls and their output', () => {
  const result = conversation([
    { type: 'response_item', payload: { type: 'custom_tool_call', id: 'c1', name: 'apply_patch', input: 'patch fixture' } },
    { type: 'response_item', payload: { type: 'custom_tool_call_output', id: 'o1', output: 'success' } },
  ], 'codex');
  assert.deepEqual(result.messages.map(x => [x.role, x.text]), [['tool', 'patch fixture'], ['result', 'success']]);
});

test('native chat launches only its own Claude session and retries do not duplicate turns', async t => {
  const scripts = await mkdtemp(join(tmpdir(), 'steer-agent-test-'));
  t.after(() => rm(scripts, { recursive: true, force: true }));
  const executable = join(scripts, 'fake-claude.mjs');
  await writeFile(executable, `let text = ''; for await (const chunk of process.stdin) text += chunk;
    console.log(JSON.stringify({ type: 'assistant', message: { id: 'message-' + Date.now(), content: [{ type: 'text', text: 'Reply: ' + text }] } }));
    setTimeout(() => console.log(JSON.stringify({ type: 'result', is_error: false })), 150);`);
  const launches = [];
  const { request, hook, directory } = await fixture(t, { launchAgent: (command, args, options) => {
    launches.push({ command, args });
    return spawn(process.execPath, [executable, ...args], options);
  } });
  const requestID = randomUUID();
  const body = { requestID, cwd: directory, text: 'Literal $(touch never-created)' };
  const created = await (await request('/v1/conversations', 'POST', body)).json();
  const sessionID = `claude:${requestID}`;
  assert.equal(created.session.id, sessionID);
  assert.equal(created.session.managed, true);
  assert.equal((await request('/v1/conversations', 'POST', body)).status, 202);
  assert.equal((await request('/v1/conversations', 'POST', { ...body, text: 'different' })).status, 409);
  assert.equal(launches.length, 1);
  assert.ok(launches[0].args.includes('--session-id'));
  const next = { sessionID, requestID: randomUUID(), text: 'Follow up' };
  assert.equal((await request('/v1/messages', 'POST', next)).status, 409);
  async function ready() {
    for (let i = 0; i < 100; i++) {
      const { sessions } = await (await request('/v1/sessions')).json();
      if (sessions.find(x => x.id === sessionID)?.canSend) return;
      await delay(10);
    }
    assert.fail('Agent did not finish');
  }
  await ready();
  assert.equal((await request('/v1/messages', 'POST', next)).status, 202);
  assert.equal((await request('/v1/messages', 'POST', next)).status, 202);
  await ready();
  assert.equal(launches.length, 2);
  assert.ok(launches[1].args.includes('--resume'));
  assert.ok(launches[1].args.includes(requestID));
  const detail = await (await request(`/v1/conversations/${encodeURIComponent(sessionID)}`)).json();
  assert.equal(detail.messages.filter(x => x.role === 'assistant').length, 2);
  assert.equal(detail.messages[0].text, body.text);
  await assert.rejects(readFile(join(directory, 'never-created')), { code: 'ENOENT' });
  await hook('SessionStart');
  assert.equal((await request('/v1/messages', 'POST', { ...next, sessionID: 'claude:session-a' })).status, 409);
});

test('stop targets the companion-owned process and an unavailable Claude command reports an error', async t => {
  const { request, directory } = await fixture(t, { launchAgent: (command, args, options) => spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], options) });
  const id = randomUUID();
  assert.equal((await request('/v1/conversations', 'POST', { requestID: id, cwd: directory, text: 'Start' })).status, 202);
  assert.equal((await request('/v1/stop', 'POST', { sessionID: `claude:${id}` })).status, 202);
  for (let i = 0; i < 100; i++) {
    const { sessions } = await (await request('/v1/sessions')).json();
    if (sessions[0].canSend) {
      assert.equal(sessions[0].error, 'Claude was stopped.');
      break;
    }
    await delay(10);
    if (i === 99) assert.fail('Claude did not stop');
  }
  const broken = await fixture(t, { launchAgent: (command, args, options) => spawn('/nonexistent-steer-test-command', args, options) });
  assert.equal((await broken.request('/v1/conversations', 'POST', { requestID: randomUUID(), cwd: broken.directory, text: 'Start' })).status, 503);
});

test('without the app watching, permission requests fall through to Claude at once', async t => {
  const { hook, request } = await fixture(t, { watchWindow: 15000 });
  const started = Date.now();
  const response = await hook('PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'ls' } });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {});
  assert.ok(Date.now() - started < 1000);
  // Once the app polls, the next request waits for a decision from the phone.
  await request('/v1/sessions');
  const waiting = hook('PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'ls' } });
  const approval = await waitForApproval(request);
  assert.equal((await request('/v1/decisions', 'POST', { id: approval.id, sessionID: 'claude:session-a', decision: 'deny' })).status, 200);
  assert.equal((await (await waiting).json()).hookSpecificOutput.decision.behavior, 'deny');
});

test('a held request falls through once the app stops watching', async t => {
  const { hook, request } = await fixture(t, { watchWindow: 300 });
  await request('/v1/sessions');
  const waiting = hook('PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'ls' } });
  await waitForApproval(request);
  // The phone goes away: no more polling. Claude must not stay blocked for the full approval timeout.
  const started = Date.now();
  const response = await waiting;
  assert.deepEqual(await response.json(), {});
  assert.ok(Date.now() - started < 3000, `held for ${Date.now() - started} ms`);
});

test('reinstalling replaces hooks written by an older version that pinned a node binary', () => {
  const cli = fileURLToPath(new URL('../cli.mjs', import.meta.url));
  const old = `STEER_HOME='/x' '/old/node/v18/bin/node' '${cli}' hook`;
  const settings = { hooks: { Stop: [{ hooks: [{ type: 'command', command: old }, { type: 'command', command: 'other' }] }] } };
  const current = `STEER_HOME='/x' "$(command -v node)" '${cli}' hook`;
  const installed = installHooks(settings, current);
  assert.deepEqual(installed.hooks.Stop.flatMap(x => x.hooks.map(h => h.command)), ['other', current]);
  assert.deepEqual(installHooks(installed, current, true).hooks.Stop.flatMap(x => x.hooks.map(h => h.command)), ['other']);
});
