import { spawn } from 'node:child_process';
import { mkdir, appendFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';

export async function startClaudeTurn({ sessionID, cwd, text, transcriptPath, resume, onExit, launch = spawn }) {
  await mkdir(dirname(transcriptPath), { recursive: true, mode: 0o700 });
  await appendFile(transcriptPath, JSON.stringify({ type: 'user', uuid: randomUUID(), message: { role: 'user', content: text } }) + '\n', { mode: 0o600 });
  const child = launch('claude', ['--print', '--output-format', 'stream-json', '--verbose',
    ...(resume ? ['--resume', sessionID] : ['--session-id', sessionID])], {
    cwd, detached: true, stdio: ['pipe', 'pipe', 'pipe'],
  });
  let buffer = '';
  let writes = Promise.resolve();
  let failure;
  let killTimer;
  let closed = false;
  function signal(value) {
    if (closed || !child.pid) return;
    try { process.kill(-child.pid, value); }
    catch (error) { if (error.code !== 'ESRCH') child.kill(value); }
  }
  function stop() {
    if (closed) return;
    signal('SIGTERM');
    if (!killTimer) killTimer = setTimeout(() => signal('SIGKILL'), 5000);
  }
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    buffer += chunk;
    if (Buffer.byteLength(buffer) > 8 * 1024 * 1024) {
      failure = 'Claude output exceeded the supported size.';
      stop();
      return;
    }
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      let record;
      try { record = JSON.parse(line); } catch { continue; }
      if (record.type === 'result' && record.is_error) failure = 'Claude could not complete this turn. Check its authentication and configuration on the host.';
      if (record.type !== 'assistant' && record.type !== 'user') continue;
      writes = writes.then(() => appendFile(transcriptPath, JSON.stringify(record) + '\n', { mode: 0o600 }))
        .catch(() => { failure = 'Could not save the conversation.'; stop(); });
    }
  });
  child.stderr.on('data', () => {});
  child.stdin.on('error', () => { failure = 'Claude closed its input before accepting the prompt.'; });
  child.on('error', () => { failure = 'Could not start Claude. Install and authenticate the Claude CLI on this host.'; });
  const completion = new Promise(resolve => child.on('close', async (code, signalName) => {
    closed = true;
    clearTimeout(killTimer);
    await writes;
    try { await onExit(failure ?? (code === 0 ? null : signalName ? 'Claude was stopped.' : `Claude exited with status ${code}. Check its configuration on the host.`)); }
    catch { /* The server retains any persistence failure in the session status. */ }
    finally { resolve(); }
  }));
  await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
  child.stdin.end(text);
  return { stop, completion };
}
