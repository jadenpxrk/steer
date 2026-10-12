import { open } from 'node:fs/promises';

// Read a bounded tail and ignore incomplete writes; transcript files can grow for days.
export async function readRecords(path, limit = 8 * 1024 * 1024) {
  const file = await open(path, 'r');
  try {
    const { size } = await file.stat();
    const start = Math.max(0, size - limit);
    const buffer = Buffer.alloc(Math.min(size, limit));
    const { bytesRead } = await file.read(buffer, 0, buffer.length, start);
    let lines = buffer.subarray(0, bytesRead).toString('utf8').split('\n');
    lines.pop();
    if (start) lines.shift();
    const records = [];
    for (const line of lines) {
      try { records.push(JSON.parse(line)); } catch { /* A damaged line must not hide later records. */ }
    }
    return { records, truncated: start > 0 };
  } finally { await file.close(); }
}

const display = value => typeof value === 'string' ? value : JSON.stringify(value ?? {}, null, 2);
const number = value => Number.isFinite(value) && value >= 0 ? value : 0;

export function conversation(records, provider, truncated = false) {
  const messages = new Map();
  const usages = new Map();
  let sequence = 0;
  let textClipped = false;
  const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, contextUsed: null, contextWindow: null, rateLimits: [] };
  function add(id, role, text, tool = null) {
    if (typeof text !== 'string' || !text) return;
    if (text.length > 32000) textClipped = true;
    messages.set(id, { id, role, text: text.slice(0, 32000), tool });
  }
  for (const record of records) {
    sequence++;
    if (!record || typeof record !== 'object') continue;
    if (provider === 'claude') {
      const message = record.message;
      if (!message || !['user', 'assistant'].includes(record.type)) continue;
      const id = message.id ?? record.uuid ?? `line-${sequence}`;
      if (message.usage) usages.set(id, message.usage);
      if (typeof message.content === 'string') add(id, record.type, message.content);
      else if (Array.isArray(message.content)) message.content.forEach((block, index) => {
        if (!block || typeof block !== 'object') return;
        const blockID = `${id}:${block.id ?? block.tool_use_id ?? index}`;
        if (block.type === 'text') add(blockID, record.type, block.text);
        if (block.type === 'tool_use') add(blockID, 'tool', display(block.input), block.name);
        if (block.type === 'tool_result') add(blockID, 'result', display(block.content), block.is_error ? 'Tool error' : 'Tool result');
      });
    } else {
      const payload = record.payload;
      if (!payload) continue;
      const id = payload.id ?? `line-${sequence}`;
      if (record.type === 'response_item') {
        if (payload.type === 'message' && ['user', 'assistant'].includes(payload.role)) {
          add(id, payload.role, (Array.isArray(payload.content) ? payload.content : []).filter(x => x && ['input_text', 'output_text'].includes(x.type)).map(x => x.text).join('\n'));
        }
        if (payload.type === 'function_call') add(`${id}:call`, 'tool', display(payload.arguments), payload.name);
        if (payload.type === 'custom_tool_call') add(`${id}:call`, 'tool', display(payload.input), payload.name);
        if (payload.type === 'function_call_output') add(`${id}:result`, 'result', display(payload.output), 'Tool result');
        if (payload.type === 'custom_tool_call_output') add(`${id}:result`, 'result', display(payload.output), payload.name ?? 'Tool result');
      }
      if (record.type === 'event_msg' && payload.type === 'token_count') {
        const info = payload.info;
        if (info) {
          usage.input = number(info.total_token_usage?.input_tokens);
          usage.output = number(info.total_token_usage?.output_tokens);
          usage.cacheRead = number(info.total_token_usage?.cached_input_tokens);
          usage.contextUsed = info.last_token_usage?.total_tokens ?? null;
          usage.contextWindow = info.model_context_window ?? null;
        }
        if (payload.rate_limits) {
          usage.rateLimits = ['primary', 'secondary'].flatMap(name => {
            const window = payload.rate_limits[name];
            return window && Number.isFinite(window.used_percent) ? [{
              name, usedPercent: window.used_percent, windowMinutes: window.window_minutes ?? null,
              resetsAt: window.resets_at ?? null,
            }] : [];
          });
        }
      }
    }
  }
  for (const value of usages.values()) {
    usage.input += number(value.input_tokens);
    usage.output += number(value.output_tokens);
    usage.cacheRead += number(value.cache_read_input_tokens);
    usage.cacheWrite += number(value.cache_creation_input_tokens);
    usage.contextUsed = number(value.input_tokens) + number(value.cache_read_input_tokens) + number(value.cache_creation_input_tokens);
  }
  return { messages: [...messages.values()].slice(-400), usage, truncated: truncated || messages.size > 400 || textClipped };
}
