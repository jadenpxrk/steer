import { createServer } from 'node:http';
import { randomUUID, createHash } from 'node:crypto';
import { open, readFile, readdir, stat } from 'node:fs/promises';
import { join, isAbsolute } from 'node:path';
import { authorized, readJSON, respond, saveJSON, requireValue, validID } from './http.mjs';
import { readRecords, conversation } from './transcript.mjs';
import { startClaudeTurn } from './claude.mjs';

const events = new Set(['SessionStart', 'UserPromptSubmit', 'PermissionRequest', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'SessionEnd']);

// Approvals are held for the phone only while the app is polling; otherwise Claude's own prompt appears at once.
export async function createCompanion({ directory, token, codexDirectory, approvalTimeout = 300000, watchWindow = 15000, launchAgent }) {
  let saved = { sessions: [] };
  try { saved = JSON.parse(await readFile(join(directory, 'state.json'), 'utf8')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const sessions = new Map(saved.sessions.map(session => [session.id, { ...session, status: 'unknown' }]));
  const pending = new Map();
  const managed = new Map();
  let writeQueue = Promise.resolve();
  let discoveryTime = 0;
  let discovery;
  let appSeenAt = 0;
  let closing = false;
  function persist() {
    const snapshot = structuredClone({ sessions: [...sessions.values()] });
    writeQueue = writeQueue.catch(() => {}).then(() => saveJSON(join(directory, 'state.json'), snapshot));
    return writeQueue;
  }
  function publicSession(session) {
    const { transcriptPath, requestHash, ...result } = session;
    const agent = managed.get(session.id);
    return { ...result, managed: !!agent, canSend: !!agent && !agent.running, canStop: !!agent?.process,
      approvals: [...pending.values()].filter(x => x.sessionID === session.id).map(x => x.request) };
  }
  function finish(id, decision = null) {
    const item = pending.get(id);
    if (!item) return;
    pending.delete(id);
    clearTimeout(item.timer);
    const session = sessions.get(item.sessionID);
    if (session && ![...pending.values()].some(x => x.sessionID === session.id)) session.status = decision ? 'working' : 'unknown';
    const output = decision && item.request.questions ? {
      hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'allow',
        updatedInput: { ...item.input, answers: decision } },
    } : decision ? {
      hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: {
        behavior: decision, ...(decision === 'deny' ? { message: 'Denied in Steer.' } : {}),
      } },
    } : {};
    respond(item.response, 200, output);
  }
  async function sendPrompt(session, requestID, text) {
    requireValue(!closing, 'The companion is shutting down.', 503);
    const agent = managed.get(session.id);
    requireValue(agent, 'This session uses its original terminal for new prompts.', 409);
    requireValue(validID(requestID) && typeof text === 'string' && text.trim().length > 0 && text.length <= 16000);
    const hash = createHash('sha256').update(text).digest('hex');
    if (agent.requests.has(requestID)) {
      requireValue(agent.requests.get(requestID) === hash, 'This request ID was already used with different text.', 409);
      return;
    }
    requireValue(!agent.running, 'Wait for the current turn to finish or stop it first.', 409);
    requireValue([...managed.values()].filter(x => x.running).length < 8, 'Eight agent turns are already running.', 429);
    agent.running = true;
    agent.requests.set(requestID, hash);
    session.status = 'working';
    session.error = null;
    session.archived = false;
    session.updatedAt = Date.now();
    try {
      await persist();
      agent.process = await startClaudeTurn({ sessionID: session.id.slice('claude:'.length), cwd: session.cwd,
        text, transcriptPath: session.transcriptPath, resume: agent.hasRun, launch: launchAgent,
        onExit: async error => {
          agent.running = false;
          agent.process = null;
          for (const [id, item] of pending) if (item.sessionID === session.id) finish(id);
          const current = sessions.get(session.id);
          current.status = error ? 'ended' : 'done';
          current.error = error;
          current.updatedAt = Date.now();
          try { await persist(); }
          catch { current.error = 'Could not save session metadata.'; }
        },
      });
      agent.hasRun = true;
    } catch {
      agent.running = false;
      session.status = 'ended';
      session.error = 'Could not start Claude. Check its installation, authentication, and transcript file permissions on the host.';
      throw Object.assign(new Error(session.error), { status: 503 });
    }
  }
  async function discoverCodex() {
    if (!codexDirectory || Date.now() - discoveryTime < 30000) return;
    if (discovery) return discovery;
    discovery = (async () => {
      const files = [];
      async function walk(path, depth = 0) {
        if (depth > 4 || files.length >= 2000) return;
        let entries;
        try { entries = await readdir(path, { withFileTypes: true }); }
        catch (error) { if (error.code === 'ENOENT') return; throw error; }
        for (const entry of entries.sort((a, b) => b.name.localeCompare(a.name))) {
          if (files.length >= 2000) break;
          const child = join(path, entry.name);
          if (entry.isDirectory()) await walk(child, depth + 1);
          else if (entry.isFile() && entry.name.endsWith('.jsonl')) files.push(child);
        }
      }
      await walk(codexDirectory);
      for (const path of files.slice(0, 200)) {
        const metadata = await stat(path).catch(() => null);
        if (!metadata) continue;
        const existing = [...sessions.values()].find(x => x.transcriptPath === path);
        if (existing?.updatedAt === metadata.mtimeMs) continue;
        // Session metadata is at the start, not the bounded conversation tail.
        const file = await open(path, 'r');
        let record;
        try {
          const buffer = Buffer.alloc(1024 * 1024);
          const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
          record = JSON.parse(buffer.subarray(0, bytesRead).toString('utf8').split('\n')[0]);
        } catch { continue; }
        finally { await file.close(); }
        if (record.type !== 'session_meta' || !validID(record.payload?.id)) continue;
        const id = `codex:${record.payload.id}`;
        sessions.set(id, { id, provider: 'codex', title: 'Codex', cwd: record.payload.cwd ?? '',
          transcriptPath: path, status: 'history', updatedAt: metadata.mtimeMs,
          archived: sessions.get(id)?.archived ?? false });
      }
      discoveryTime = Date.now();
    })().finally(() => { discovery = null; });
    return discovery;
  }

  const server = createServer(async (request, response) => {
    try {
      requireValue(authorized(request, token), 'Unauthorized', 401);
      const path = new URL(request.url, 'http://localhost').pathname;
      if (path !== '/v1/hooks') appSeenAt = Date.now();
      if (request.method === 'GET' && path === '/v1/sessions') {
        await discoverCodex();
        respond(response, 200, { sessions: [...sessions.values()].sort((a, b) => b.updatedAt - a.updatedAt).map(publicSession) });
      } else if (request.method === 'POST' && path === '/v1/conversations') {
        const body = await readJSON(request, 128 * 1024);
        requireValue(validID(body.requestID) && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(body.requestID));
        requireValue(typeof body.cwd === 'string' && isAbsolute(body.cwd) && body.cwd.length <= 8192);
        requireValue(typeof body.text === 'string' && body.text.trim().length > 0 && body.text.length <= 16000);
        const id = `claude:${body.requestID}`;
        const requestHash = createHash('sha256').update(JSON.stringify([body.cwd, body.text])).digest('hex');
        let session = sessions.get(id);
        if (session) requireValue(session.requestHash === requestHash, 'This request ID was already used.', 409);
        else {
          const folder = await stat(body.cwd).catch(() => null);
          requireValue(folder?.isDirectory(), 'Choose an existing project directory.');
          session = { id, provider: 'claude', title: body.text.trim().slice(0, 80), cwd: body.cwd,
            transcriptPath: join(directory, 'conversations', `${body.requestID}.jsonl`), status: 'idle',
            updatedAt: Date.now(), archived: false, requestHash };
          sessions.set(id, session);
          managed.set(id, { running: false, hasRun: false, requests: new Map() });
          await sendPrompt(session, body.requestID, body.text);
        }
        respond(response, 202, { session: publicSession(session) });
      } else if (request.method === 'POST' && path === '/v1/messages') {
        const body = await readJSON(request, 128 * 1024);
        const session = sessions.get(body.sessionID);
        requireValue(session, 'Session not found', 404);
        await sendPrompt(session, body.requestID, body.text);
        respond(response, 202, {});
      } else if (request.method === 'POST' && path === '/v1/stop') {
        const body = await readJSON(request, 4096);
        const agent = managed.get(body.sessionID);
        requireValue(agent?.process, 'This session has no companion-managed turn to stop.', 409);
        agent.process.stop();
        respond(response, 202, {});
      } else if (request.method === 'POST' && path === '/v1/hooks') {
        const event = await readJSON(request);
        requireValue(!closing, 'The companion is shutting down.', 503);
        requireValue(validID(event.session_id) && events.has(event.hook_event_name));
        requireValue(typeof event.cwd === 'string' && event.cwd.length <= 8192);
        requireValue(typeof event.transcript_path === 'string' && isAbsolute(event.transcript_path));
        requireValue(event.session_title == null || (typeof event.session_title === 'string' && event.session_title.length <= 512));
        const isQuestion = event.hook_event_name === 'PreToolUse';
        if (isQuestion) {
          requireValue(event.tool_name === 'AskUserQuestion');
          const questions = event.tool_input?.questions;
          requireValue(Array.isArray(questions) && questions.length > 0 && questions.length <= 4);
          requireValue(new Set(questions.map(x => x.question)).size === questions.length);
          for (const question of questions) {
            requireValue(typeof question.question === 'string' && question.question.length > 0 && question.question.length <= 8192);
            requireValue(Array.isArray(question.options) && question.options.length <= 20);
            requireValue(question.options.every(x => typeof x.label === 'string' && x.label.length <= 2000));
            requireValue(new Set(question.options.map(x => x.label)).size === question.options.length);
          }
        }
        const asksForInput = isQuestion || event.hook_event_name === 'PermissionRequest';
        const waitsForInput = asksForInput && Date.now() - appSeenAt <= watchWindow;
        if (waitsForInput) {
          requireValue(typeof event.tool_name === 'string' && event.tool_input && typeof event.tool_input === 'object');
          requireValue(pending.size < 100, 'Too many pending requests', 429);
        }
        const id = `claude:${event.session_id}`;
        const previous = sessions.get(id);
        const session = { ...previous, id, provider: 'claude', title: event.session_title || previous?.title || 'Claude', cwd: event.cwd,
          transcriptPath: managed.has(id) ? previous.transcriptPath : event.transcript_path, status: 'working', updatedAt: Date.now(), archived: false };
        if (event.hook_event_name === 'SessionStart' || event.hook_event_name === 'SessionEnd') {
          for (const [key, item] of pending) if (item.sessionID === id) finish(key);
          session.status = event.hook_event_name === 'SessionEnd' ? 'ended' : 'idle';
        }
        if (event.hook_event_name === 'Stop') session.status = 'done';
        sessions.set(id, session);
        if (waitsForInput) {
          const approvalID = randomUUID();
          const item = { sessionID: id, response, input: event.tool_input, request: { id: approvalID, tool: event.tool_name,
            input: JSON.stringify(event.tool_input, null, 2), expiresAt: Date.now() + approvalTimeout,
            questions: isQuestion ? event.tool_input.questions.map(question => ({ question: question.question,
              options: question.options.map(x => x.label), multiSelect: question.multiSelect === true })) : null } };
          item.timer = setTimeout(() => finish(approvalID), approvalTimeout);
          pending.set(approvalID, item);
          response.on('close', () => finish(approvalID));
          session.status = 'waiting';
          await persist();
          // Response remains open until an exact, one-time decision or expiry.
        } else {
          if ([...pending.values()].some(x => x.sessionID === id)) session.status = 'waiting';
          await persist();
          respond(response, 200, {});
        }
      } else if (request.method === 'POST' && path === '/v1/decisions') {
        const body = await readJSON(request);
        const item = pending.get(body.id);
        requireValue(item && item.sessionID === body.sessionID && item.request.expiresAt > Date.now(), 'This request has expired or has an answer.', 409);
        requireValue(!item.request.questions, 'Answer the questions instead of approving the tool.');
        requireValue(body.decision === 'allow' || body.decision === 'deny');
        finish(body.id, body.decision);
        respond(response, 200, {});
      } else if (request.method === 'POST' && path === '/v1/answers') {
        const body = await readJSON(request, 256 * 1024);
        const item = pending.get(body.id);
        requireValue(item && item.sessionID === body.sessionID && item.request.expiresAt > Date.now(), 'This question has expired or has an answer.', 409);
        requireValue(item.request.questions && body.answers && typeof body.answers === 'object' && !Array.isArray(body.answers));
        const questions = item.request.questions;
        requireValue(Object.keys(body.answers).length === questions.length);
        requireValue(questions.every(x => typeof body.answers[x.question] === 'string' && body.answers[x.question].trim().length > 0 && body.answers[x.question].length <= 2000));
        finish(body.id, body.answers);
        respond(response, 200, {});
      } else if (request.method === 'POST' && path === '/v1/archive') {
        const body = await readJSON(request);
        const session = sessions.get(body.sessionID);
        requireValue(session && typeof body.archived === 'boolean');
        requireValue(session.status !== 'waiting', 'Resolve the pending request before archiving.', 409);
        session.archived = body.archived;
        await persist();
        respond(response, 200, {});
      } else if (request.method === 'GET' && path.startsWith('/v1/conversations/')) {
        const id = decodeURIComponent(path.slice('/v1/conversations/'.length));
        const session = sessions.get(id);
        requireValue(session, 'Session not found', 404);
        let transcript;
        let transcriptError = null;
        try { transcript = await readRecords(session.transcriptPath); }
        catch {
          transcript = { records: [], truncated: false };
          transcriptError = 'The conversation log is not available. You can still review pending requests below.';
        }
        respond(response, 200, { session: publicSession(session), transcriptError, ...conversation(transcript.records, session.provider, transcript.truncated) });
      } else respond(response, 404, { error: 'Not found' });
    } catch (error) {
      respond(response, error.status ?? 500, { error: error.status ? error.message : 'Companion could not complete the request. Check its configuration and transcript access.' });
    }
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  // A request held while the phone was watching goes back to Claude's own prompt once the phone stops polling.
  const releaseUnwatched = setInterval(() => {
    if (Date.now() - appSeenAt > watchWindow) for (const id of pending.keys()) finish(id);
  }, Math.min(watchWindow, 5000));
  releaseUnwatched.unref();
  server.on('close', () => {
    clearInterval(releaseUnwatched);
    for (const id of pending.keys()) finish(id);
  });
  return { server, async close() {
    closing = true;
    for (const id of pending.keys()) finish(id);
    for (const agent of managed.values()) agent.process?.stop();
    await new Promise(resolve => server.close(resolve));
    const processes = [...managed.values()].flatMap(x => x.process ? [x.process] : []);
    for (const process of processes) process.stop();
    await Promise.all(processes.map(x => x.completion));
    await writeQueue;
  } };
}
