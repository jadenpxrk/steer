import { timingSafeEqual, randomUUID } from 'node:crypto';
import { mkdir, writeFile, rename, rm } from 'node:fs/promises';
import { dirname } from 'node:path';

export function authorized(request, token) {
  const actual = Buffer.from(request.headers.authorization ?? '');
  const expected = Buffer.from(`Bearer ${token}`);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export async function readJSON(stream, limit = 1024 * 1024) {
  const chunks = [];
  let size = 0;
  for await (const chunk of stream) {
    size += chunk.length;
    if (size > limit) throw Object.assign(new Error('Request too large'), { status: 413 });
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw Object.assign(new Error('Invalid JSON'), { status: 400 }); }
}

export function respond(response, status, value) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  response.end(JSON.stringify(value));
}

export async function saveJSON(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
    await rename(temporary, path);
  } finally { await rm(temporary, { force: true }); }
}

export function requireValue(condition, message = 'Invalid request', status = 400) {
  if (!condition) throw Object.assign(new Error(message), { status });
}

export const validID = value => typeof value === 'string' && value.length > 0 && value.length <= 128 && !/[^a-zA-Z0-9_-]/.test(value);
export const validDeviceToken = value => typeof value === 'string' && value.length >= 32 && value.length <= 256 && !/[^a-f0-9]/.test(value);
