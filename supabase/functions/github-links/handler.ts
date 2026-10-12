import { HTML_ENTITIES } from "./entities.ts";

// This module has no runtime side effects or credentials in diagnostics.
type ObjectValue = Record<string, unknown>;
type Dependencies = {
  fetch: typeof fetch;
  env: (name: string) => string | undefined;
  now: () => number;
};
const MIB = 1024 * 1024;
const TEXT_SCAN_LIMIT = 16 * 1024;
// PostgreSQL UTF-8 text cannot contain NUL or unpaired UTF-16 surrogates.
const INVALID_TEXT = /[\u0000\ud800-\udfff]/u;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HANDLE = /^[A-Za-z0-9-]{1,39}$/;
const NAME = /^[A-Za-z0-9._-]{1,100}$/;
const CODES = new Set([
  "not_authenticated", "account_not_ready", "declaration_required",
  "invalid_input", "prerequisite_missing", "rate_limited", "not_found",
]);
const FIELDS: Record<string, string[]> = {
  sync_identity: [],
  list_repositories: ["page"],
  preview_repository: ["repository_id", "repository_name"],
  save_repository: [
    "repository_id", "repository_name", "title", "description", "main_language",
    "tags", "opening_text", "visibility", "replace_existing",
  ],
  refresh_preview: ["link_id"],
};

class Failure extends Error {
  constructor(readonly code: string, readonly details: string[] = []) {
    super(code);
  }
}
function readerFailure(): Failure {
  return new Failure("prerequisite_missing", ["github_reader"]);
}
function object(value: unknown): ObjectValue {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw readerFailure();
  }
  return value as ObjectValue;
}
function decimal(value: unknown): value is string {
  return typeof value === "string" && /^[1-9][0-9]{0,18}$/.test(value) &&
    (value.length < 19 || value <= "9223372036854775807");
}
function repositoryName(value: unknown): value is string {
  return typeof value === "string" && NAME.test(value) &&
    value !== "." && value !== "..";
}
// Match private.trim_input, including its visually-empty-only normalization.
function trim(value: string): string {
  const whitespace = /[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]/;
  let start = 0;
  let end = value.length;
  while (start < end && whitespace.test(value[start])) start++;
  while (end > start && whitespace.test(value[end - 1])) end--;
  const result = value.slice(start, end);
  return /^[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200d\u2028\u2029\u202f\u205f\u3000\u2060\ufeff\u3164\u115f\u1160\uffa0]*$/.test(result)
    ? "" : result;
}
function length(value: string): number {
  return Array.from(value).length;
}
function validate(value: unknown): ObjectValue {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Failure("invalid_input", ["body"]);
  }
  const body = value as ObjectValue;
  if (typeof body.action !== "string" || !Object.hasOwn(FIELDS, body.action)) {
    throw new Failure("invalid_input", ["action"]);
  }
  const fields = FIELDS[body.action];
  const invalid: string[] = [];
  for (const field of fields) {
    const v = body[field];
    let valid = true;
    switch (field) {
      case "page": valid = Number.isInteger(v) && Number(v) >= 1 && Number(v) <= 1000; break;
      case "repository_id": valid = decimal(v); break;
      case "repository_name": valid = repositoryName(v); break;
      case "link_id": valid = typeof v === "string" && UUID.test(v); break;
      case "title":
      case "description":
      case "opening_text": {
        valid = typeof v === "string" && !INVALID_TEXT.test(v);
        if (valid) {
          const text = trim(v as string);
          valid = length(text) <= (field === "title" ? 100 : 200) &&
            (field !== "title" || text !== "");
          body[field] = text;
        }
        break;
      }
      case "main_language": {
        valid = v === null || typeof v === "string" && !INVALID_TEXT.test(v);
        if (valid && typeof v === "string") {
          const text = trim(v);
          valid = length(text) <= 30;
          body[field] = text || null;
        }
        break;
      }
      case "tags": {
        valid = Array.isArray(v) && v.length <= 10 &&
          v.every((tag) => typeof tag === "string" && !INVALID_TEXT.test(tag) && trim(tag) !== "" && length(trim(tag)) <= 30);
        if (valid) body[field] = [...new Set((v as string[]).map(trim))];
        break;
      }
      case "visibility": valid = ["everyone_eligible", "compatible_only", "private"].includes(v as string); break;
      case "replace_existing": valid = typeof v === "boolean"; break;
    }
    if (!valid) invalid.push(field);
  }
  invalid.push(...Object.keys(body).filter((key) => key !== "action" && !fields.includes(key)));
  if (invalid.length) throw new Failure("invalid_input", invalid);
  return body;
}

async function cancel(body: ReadableStream<Uint8Array> | null): Promise<void> {
  try { await body?.cancel(); } catch { /* Already closed/aborted. */ }
}
async function readText(
  body: ReadableStream<Uint8Array> | null,
  limit: number,
  signal: AbortSignal,
): Promise<string> {
  if (!body) return "";
  const reader = body.getReader();
  const abort = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener("abort", abort, { once: true });
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let size = 0;
  let text = "";
  try {
    while (true) {
      signal.throwIfAborted();
      const { done, value } = await reader.read();
      signal.throwIfAborted();
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw readerFailure();
      text += decoder.decode(value, { stream: true });
    }
    return text + decoder.decode();
  } finally {
    signal.removeEventListener("abort", abort);
    try { await reader.cancel(); } catch { /* Stream may have failed. */ }
    reader.releaseLock();
  }
}

// JSON lexical tokens: quote integer literals before JSON.parse can round them.
// Quoted strings (including escaped quotes) are consumed as complete tokens.
function githubJSON(text: string): unknown {
  return JSON.parse(text.replace(
    /"(?:[^"\\]|\\[\s\S])*"|(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/g,
    (token, numeric: string | undefined) =>
      numeric && /^-?[0-9]+$/.test(numeric) ? JSON.stringify(numeric) : token,
  ));
}

// Match balanced destinations without fetching them. A single pass also keeps
// deeply nested or unterminated, untrusted Markdown from causing backtracking.
function markdownLinks(value: string): string {
  const brackets: number[] = [];
  const parentheses: number[] = [];
  const closing = new Map<number, number>();
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "\\") { i++; continue; }
    const stack = value[i] === "[" || value[i] === "]" ? brackets : parentheses;
    if (value[i] === "[" || value[i] === "(") stack.push(i);
    if ((value[i] === "]" || value[i] === ")") && stack.length) {
      closing.set(stack.pop()!, i);
    }
  }
  const skip = new Map<number, number>();
  const result: string[] = [];
  for (let i = 0; i < value.length; i++) {
    if (skip.has(i)) { i = skip.get(i)!; continue; }
    if (value[i] === "\\") {
      result.push(value.slice(i, i + 2));
      i++;
      continue;
    }
    const image = value[i] === "!" && value[i + 1] === "[";
    const start = image ? i + 1 : i;
    const labelEnd = value[start] === "[" ? closing.get(start) : undefined;
    if (labelEnd !== undefined) {
      const destinationStart = labelEnd + 1;
      const destinationEnd = ["(", "["].includes(value[destinationStart])
        ? closing.get(destinationStart) : undefined;
      if (image) { i = destinationEnd ?? labelEnd; continue; }
      if (destinationEnd !== undefined) {
        // Scan the label itself so linked images are omitted as well.
        skip.set(labelEnd, destinationEnd);
        continue;
      }
    }
    result.push(value[i]);
  }
  return result.join("");
}

// Scan tags once, including quoted attributes. Regex searches for a closing tag
// or emphasis marker can otherwise take quadratic time on a bounded but hostile
// README and prevent the action's timeout from running.
function htmlText(value: string): string {
  // ASCII case folding preserves offsets even for Unicode such as capital İ.
  const lower = value.replace(/[A-Z]/g, (letter) => letter.toLowerCase());
  const result: string[] = [];
  function tagEnd(start: number): number {
    let quote = "";
    for (let i = start + 1; i < value.length; i++) {
      if (quote) { if (value[i] === quote) quote = ""; }
      else if (value[i] === '"' || value[i] === "'") quote = value[i];
      else if (value[i] === ">") return i;
    }
    // Fail closed for any tag left open at the bounded input's end.
    return -1;
  }
  for (let i = 0; i < value.length;) {
    const start = value.indexOf("<", i);
    if (start < 0) { result.push(value.slice(i)); break; }
    result.push(value.slice(i, start));
    if (!/[a-z/!?]/i.test(value[start + 1] ?? "")) {
      result.push("<");
      i = start + 1;
      continue;
    }
    if (value.startsWith("<!--", start)) {
      const end = value.indexOf("-->", start + 4);
      i = end < 0 ? value.length : end + 3;
      result.push(" ");
      continue;
    }
    const end = tagEnd(start);
    if (end < 0) break;
    const contents = value.slice(start + 1, end);
    const name = contents.match(/^([a-z][a-z0-9:-]*)\b/i)?.[1].toLowerCase();
    if (name === "script" || name === "style") {
      const close = `</${name}`;
      let position = lower.indexOf(close, end + 1);
      while (position >= 0 && !/[\s/>]/.test(value[position + close.length] ?? "")) {
        position = lower.indexOf(close, position + close.length);
      }
      const closingEnd = position < 0 ? -1 : tagEnd(position);
      i = closingEnd < 0 ? value.length : Math.min(closingEnd + 1, value.length);
      result.push(" ");
    } else {
      if (/^https?:\/\/[^\s<>]+$/i.test(contents)) result.push(contents);
      else if (name !== "img") result.push(" ");
      i = end + 1;
    }
  }
  return result.join("");
}

function markdownFormatting(value: string): string {
  const codeEnds = new Map<number, number>();
  const previousCode = new Map<number, number>();
  const runs = new Map<number, number>();
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "\\") { i++; continue; }
    if (value[i] !== "`") continue;
    let end = i + 1;
    while (value[end] === "`") end++;
    const size = end - i;
    runs.set(i, size);
    const previous = previousCode.get(size);
    if (previous !== undefined) codeEnds.set(previous, i);
    previousCode.set(size, i);
    i = end - 1;
  }
  const omit = new Set<number>();
  const openings = new Map<string, number>();
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "\\") { i++; continue; }
    const codeEnd = codeEnds.get(i);
    if (codeEnd !== undefined) { i = codeEnd + runs.get(i)! - 1; continue; }
    const marker = value[i];
    if (!["*", "_", "~"].includes(marker)) continue;
    let end = i + 1;
    while (value[end] === marker) end++;
    const size = end - i;
    const before = value[i - 1] ?? "";
    const after = value[end] ?? "";
    const word = (char: string) => /[\p{L}\p{N}]/u.test(char);
    const open = !!after && !/\s/u.test(after) && (marker !== "_" || !word(before));
    const close = !!before && !/\s/u.test(before) && (marker !== "_" || !word(after));
    const key = marker.repeat(size);
    const opening = openings.get(key);
    if (marker !== "~" || size === 2) {
      if (close && opening !== undefined) {
        for (let offset = 0; offset < size; offset++) { omit.add(opening + offset); omit.add(i + offset); }
        openings.delete(key);
      } else if (open) openings.set(key, i);
    }
    i = end - 1;
  }
  const result: string[] = [];
  for (let i = 0; i < value.length; i++) {
    const codeEnd = codeEnds.get(i);
    if (codeEnd !== undefined) {
      const size = runs.get(i)!;
      result.push(value.slice(i + size, codeEnd));
      i = codeEnd + size - 1;
    } else if (value[i] === "\\" && /[\\`*_{}\[\]()#+\-.!>]/.test(value[i + 1] ?? "")) {
      result.push(value[++i]);
    } else if (!omit.has(i)) result.push(value[i]);
  }
  return result.join("");
}

// Remove optional closing ATX hashes with disjoint forward/backward scans.
// Overlapping whitespace groups in a regex can backtrack cubically.
function closedHeadings(value: string): string {
  return value.split("\n").map((line) => {
    let start = 0;
    while (start < 3 && /[ \t]/.test(line[start] ?? "")) start++;
    const hashes = start;
    while (line[start] === "#") start++;
    if (start === hashes || start - hashes > 6 || !/[ \t]/.test(line[start] ?? "")) return line;
    while (/[ \t]/.test(line[start] ?? "")) start++;
    let end = line.length;
    while (end > start && /[ \t\r]/.test(line[end - 1])) end--;
    const closing = end;
    while (end > start && line[end - 1] === "#") end--;
    if (end === closing || end <= start || !/[ \t]/.test(line[end - 1])) return line;
    while (end > start && /[ \t]/.test(line[end - 1])) end--;
    return line.slice(start, end);
  }).join("\n");
}

function plain(value: string, cap: number): string {
  // Bound work before scanning markup, including giant whitespace-only inputs.
  value = value.slice(0, TEXT_SCAN_LIMIT).replace(/[\u0000\ud800-\udfff]/gu, "")
    // Keep multiline anchors and negated newline classes on the same boundaries.
    .replace(/\r\n?|[\u2028\u2029]/g, "\n");
  let text = closedHeadings(markdownLinks(htmlText(value))
    .replace(/^[ \t]*\[[^\]\n]+\]:[^\n]*$/gm, "")
    .replace(/^[ \t]*(`{3,}|~{3,})[^\n]*$/gm, ""));
  text = markdownFormatting(text
    .replace(/^[ \t]{0,3}(?:#{1,6}[ \t]+|>[ \t]*|[-+*][ \t]+|\d+[.)][ \t]+)/gm, "")
    .replace(/^[ \t]{0,3}=+[ \t]*$/gm, "")
    .replace(/^[ \t]*(?:[-*_][ \t]*){3,}$/gm, ""));
  // Decode entities after stripping: clients render the result as plain text,
  // never markup, including any decoded less-than and greater-than characters.
  text = text.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z][a-z0-9]+);/gi, (whole, entity: string) => {
    if (!entity.startsWith("#")) return Object.hasOwn(HTML_ENTITIES, entity) ? HTML_ENTITIES[entity] : whole;
    const cp = entity[1].toLowerCase() === "x"
      ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
    if (cp === 0) return "";
    return cp > 0 && cp <= 0x10ffff && !(cp >= 0xd800 && cp <= 0xdfff)
      ? String.fromCodePoint(cp) : "�";
  });
  return Array.from(trim(text.replace(/\s+/gu, " "))).slice(0, cap).join("");
}

function apiURL(value: string | URL): URL {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.hostname !== "api.github.com" ||
    (url.port !== "" && url.port !== "443") || url.username || url.password || url.hash) {
    throw readerFailure();
  }
  return url;
}
function canonicalAddress(value: unknown): string | null {
  if (typeof value !== "string" || !trim(value)) return null;
  try {
    const text = trim(value);
    const bare = !/^[a-z][a-z0-9+.-]*:/i.test(text) || /^[^/:?#]+:[0-9]+(?:[/?#]|$)/.test(text);
    const url = new URL(bare ? `https://${text}` : text);
    if (url.protocol !== "https:" || url.username || url.password || !url.hostname) return null;
    if (/%(?![0-9a-f]{2})/i.test(url.pathname + url.search)) return null;
    url.hostname = url.hostname.replace(/\.$/, "");
    url.hash = "";
    // URL handles host case, default ports, IDNA and dot segments. Canonicalize
    // escapes without turning encoded path separators into new boundaries.
    const escapes = (part: string) => part.replace(/%([0-9a-f]{2})/gi, (_, hex: string) => {
      const char = String.fromCharCode(parseInt(hex, 16));
      return /[A-Za-z0-9._~-]/.test(char) ? char : `%${hex.toUpperCase()}`;
    });
    url.pathname = escapes(url.pathname);
    url.search = escapes(url.search);
    const result = url.href;
    return length(result) <= 2048 ? result : null;
  } catch { return null; }
}
function repositoryPath(value: unknown): { owner: string; name: string } {
  if (typeof value !== "string" || value.length > 2048) throw readerFailure();
  const url = new URL(value);
  if (url.protocol !== "https:" || url.hostname !== "github.com" || url.port ||
    url.username || url.password || url.search || url.hash) throw readerFailure();
  const parts = url.pathname.split("/");
  if (parts.length !== 3) throw readerFailure();
  const owner = decodeURIComponent(parts[1]);
  const name = decodeURIComponent(parts[2]);
  if (!HANDLE.test(owner) || !repositoryName(name)) throw readerFailure();
  return { owner, name };
}
function repository(value: unknown): { row: ObjectValue; ownerID: string; public: boolean } {
  const item = object(value);
  const owner = object(item.owner);
  if (!decimal(item.id) || !decimal(owner.id) || typeof owner.login !== "string" ||
    !HANDLE.test(owner.login) || !repositoryName(item.name) ||
    typeof item.private !== "boolean" || typeof item.visibility !== "string" ||
    !(item.description === null || typeof item.description === "string") ||
    !(item.language === null || typeof item.language === "string") ||
    !Array.isArray(item.topics) || item.topics.some((tag) => typeof tag !== "string")) {
    throw readerFailure();
  }
  const title = plain(item.name, 100);
  if (!title) throw readerFailure();
  const tags = [...new Set((item.topics as string[]).map((tag) => plain(tag, 30)).filter(Boolean))].slice(0, 10);
  return {
    row: {
      repository_id: item.id, repository_name: item.name, title,
      description: plain(item.description as string ?? "", 200),
      main_language: plain(item.language as string ?? "", 30) || null, tags,
      url: `https://github.com/${encodeURIComponent(owner.login)}/${encodeURIComponent(item.name)}`,
    },
    ownerID: owner.id,
    public: item.private === false && item.visibility === "public",
  };
}

export function createHandler(deps: Dependencies): (request: Request) => Promise<Response> {
  return async (request) => {
    const start = deps.now();
    const actionController = new AbortController();
    // Race as well as abort: a stalled/custom fetch must not hold the response open.
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => { actionController.abort(); reject(readerFailure()); }, 20_000);
    });
    const actionSignal = actionController.signal;
    function remaining(): number {
      actionSignal.throwIfAborted();
      const ms = 20_000 - (deps.now() - start);
      if (ms <= 0) { actionController.abort(); throw readerFailure(); }
      return ms;
    }
    async function fetchResponse(url: URL, init: RequestInit, signal: AbortSignal): Promise<Response> {
      remaining();
      const response = await deps.fetch(url, { ...init, signal, redirect: "manual" });
      if (signal.aborted) { await cancel(response.body); throw readerFailure(); }
      try { remaining(); } catch (error) { await cancel(response.body); throw error; }
      return response;
    }
    async function work(): Promise<unknown> {
      if (request.method !== "POST") throw new Failure("invalid_input", ["method"]);
      if (request.headers.get("content-type")?.split(";", 1)[0].trim().toLowerCase() !== "application/json") {
        throw new Failure("invalid_input", ["body"]);
      }
      let body: ObjectValue;
      try {
        if (Number(request.headers.get("content-length")) > 16 * 1024) throw new Error();
        body = validate(JSON.parse(await readText(request.body, 16 * 1024, actionSignal)));
      } catch (error) {
        if (error instanceof Failure && error.code === "invalid_input") throw error;
        if (actionSignal.aborted) throw readerFailure();
        throw new Failure("invalid_input", ["body"]);
      }
      const bearer = request.headers.get("authorization");
      if (!bearer || !/^Bearer [^\s]+$/i.test(bearer)) throw new Failure("not_authenticated");
      const backend = deps.env("SUPABASE_URL");
      const anon = deps.env("SUPABASE_ANON_KEY");
      const service = deps.env("SUPABASE_SERVICE_ROLE_KEY");
      if (!backend || !anon || !service) throw readerFailure();
      const serverKey: string = service;
      const base = new URL(backend);
      if (!["http:", "https:"].includes(base.protocol) || base.username || base.password ||
        base.search || base.hash || !["", "/"].includes(base.pathname)) throw readerFailure();
      const auth = await fetchResponse(new URL("/auth/v1/user", base), {
        headers: { apikey: anon, Authorization: bearer, Accept: "application/json" },
      }, actionSignal);
      const authText = await readText(auth.body, MIB, actionSignal);
      if (auth.status === 401 || auth.status === 403 || auth.status === 404) throw new Failure("not_authenticated");
      if (!auth.ok) throw readerFailure();
      const user = object(JSON.parse(authText));
      if (typeof user.id !== "string" || !UUID.test(user.id) || user.deleted_at != null) {
        throw new Failure("not_authenticated");
      }
      const accountID = user.id;
      async function rpc(name: string, parameters: ObjectValue = {}): Promise<ObjectValue> {
        remaining();
        const response = await fetchResponse(new URL(`/rest/v1/rpc/${name}`, base), {
          method: "POST",
          headers: {
            apikey: serverKey, Authorization: `Bearer ${serverKey}`, "Content-Profile": "service",
            "Content-Type": "application/json", Accept: "application/json",
          },
          body: JSON.stringify({ account_id: accountID, ...parameters }),
        }, actionSignal);
        const result = object(JSON.parse(await readText(response.body, MIB, actionSignal)));
        remaining();
        if (!response.ok) {
          if (typeof result.message === "string" && CODES.has(result.message)) {
            if (result.details != null && typeof result.details !== "string") throw readerFailure();
            const details = typeof result.details === "string" && result.details
              ? result.details.split(",") : [];
            if (details.some((detail) => !/^[a-z][a-z0-9_]*$/.test(detail))) throw readerFailure();
            throw new Failure(result.message, details);
          }
          throw readerFailure();
        }
        return result;
      }
      const identity = await rpc("get_github_identity");
      if (identity.connected === false) throw new Failure("prerequisite_missing", ["github"]);
      if (identity.connected !== true || !decimal(identity.provider_user_id) ||
        !(identity.handle === null || typeof identity.handle === "string" && HANDLE.test(identity.handle)) ||
        !Array.isArray(identity.repository_links) || identity.repository_links.length > 10) throw readerFailure();
      const providerID = identity.provider_user_id;
      const id = deps.env("GITHUB_APP_CLIENT_ID");
      const secret = deps.env("GITHUB_APP_CLIENT_SECRET");
      const real = (value: string | undefined): value is string =>
        !!value && !!value.trim() && !value.startsWith("placeholder-");
      const headers: Record<string, string> = {
        Accept: "application/vnd.github+json", "Accept-Encoding": "identity",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "engineer-encounters-github-links",
      };
      if (real(id) && real(secret)) {
        const bytes = new TextEncoder().encode(`${id}:${secret}`);
        headers.Authorization = `Basic ${btoa(Array.from(bytes, (byte) => String.fromCharCode(byte)).join(""))}`;
      }
      async function github(path: string, absentOK = false): Promise<{ value: unknown; headers: Headers } | null> {
        let url = apiURL(`https://api.github.com${path}`);
        for (let redirects = 0; ; redirects++) {
          remaining();
          url = apiURL(url);
          // Reservation is committed before this attempt, including redirects.
          const reservation = await rpc("record_github_fetch");
          if (reservation.allowed !== true) throw new Failure("rate_limited");
          const duration = Math.min(5000, remaining());
          const attemptStart = deps.now();
          const controller = new AbortController();
          const abort = () => controller.abort();
          actionSignal.addEventListener("abort", abort, { once: true });
          let attemptTimer: ReturnType<typeof setTimeout> | undefined;
          const expired = new Promise<never>((_, reject) => {
            attemptTimer = setTimeout(() => { controller.abort(); reject(readerFailure()); }, duration);
          });
          try {
            const attempt = (async () => {
              const response = await fetchResponse(url, { headers }, controller.signal);
              // Fetch transparently decodes content encodings. Reject compression
              // and request identity so the stream bounds received AND decoded bytes.
              const encoding = response.headers.get("content-encoding");
              if (encoding && encoding.toLowerCase().trim() !== "identity" ||
                Number(response.headers.get("content-length")) > MIB) {
                await cancel(response.body); throw readerFailure();
              }
              const text = await readText(response.body, MIB, controller.signal);
              remaining();
              if (deps.now() - attemptStart >= duration) throw readerFailure();
              if ([301, 302, 303, 307, 308].includes(response.status)) {
                const location = response.headers.get("location");
                if (!location || redirects >= 3) throw readerFailure();
                return { redirect: apiURL(new URL(location, url)) };
              }
              if (response.status === 429 || response.status === 403 &&
                (response.headers.get("x-ratelimit-remaining") === "0" ||
                  response.headers.has("retry-after") || /(?:rate limit|secondary rate|abuse detection)/i.test(text))) {
                throw new Failure("rate_limited");
              }
              if (response.status === 404) {
                if (absentOK) return { result: null };
                throw new Failure("not_found");
              }
              if (response.status === 403) throw new Failure("not_found");
              if (!response.ok || !/^application\/(?:json|[a-z0-9.-]+\+json)$/i.test(response.headers.get("content-type")?.split(";", 1)[0].trim() ?? "")) {
                throw readerFailure();
              }
              return { result: { value: githubJSON(text), headers: response.headers } };
            })();
            const result = await Promise.race([attempt, expired]);
            if ("redirect" in result && result.redirect) { url = result.redirect; continue; }
            return result.result ?? null;
          } finally {
            clearTimeout(attemptTimer);
            controller.abort();
            actionSignal.removeEventListener("abort", abort);
          }
        }
      }
      async function profile(): Promise<ObjectValue> {
        const result = object((await github(`/user/${providerID}`))!.value);
        if (!decimal(result.id) || typeof result.login !== "string" || !HANDLE.test(result.login)) throw readerFailure();
        if (result.id !== providerID) throw new Failure("not_found");
        return result;
      }
      if (body.action === "sync_identity") {
        const userProfile = await profile();
        const social = (await github(`/users/${encodeURIComponent(userProfile.login as string)}/social_accounts`))!.value;
        if (!Array.isArray(social)) throw readerFailure();
        const addresses = [canonicalAddress(userProfile.blog)];
        for (const entry of social) addresses.push(canonicalAddress(object(entry).url));
        const verified = [...new Set(addresses.filter((address): address is string => address !== null))].sort().slice(0, 32);
        const synced = await rpc("sync_github_identity", {
          provider_user_id: providerID, handle: userProfile.login, verified_addresses: verified,
        });
        if (synced.connected !== true || synced.handle !== userProfile.login) throw readerFailure();
        return { connected: true, handle: synced.handle };
      }
      const handle = identity.handle ?? (await profile()).login;
      if (body.action === "list_repositories") {
        const page = body.page as number;
        const path = `/users/${encodeURIComponent(handle as string)}/repos`;
        const result = (await github(`${path}?type=owner&sort=full_name&direction=asc&per_page=30&page=${page}`))!;
        if (!Array.isArray(result.value) || result.value.length > 30) throw readerFailure();
        const repositories: ObjectValue[] = [];
        for (const value of result.value) {
          const repo = repository(value);
          if (repo.ownerID === providerID && repo.public) repositories.push(repo.row);
        }
        let next: number | null = null;
        if (page < 1000) {
          for (const part of (result.headers.get("link") ?? "").split(",")) {
            const match = part.match(/^\s*<([^>]+)>\s*;\s*rel="([^"]+)"/);
            if (!match || !match[2].split(/\s+/).includes("next")) continue;
            const linked = apiURL(match[1]);
            if ((linked.pathname !== path && linked.pathname !== `/user/${providerID}/repos`) ||
              !/^[1-9][0-9]*$/.test(linked.searchParams.get("page") ?? "") ||
              Number(linked.searchParams.get("page")) !== page + 1) throw readerFailure();
            next = page + 1;
          }
        }
        return { repositories, next_page: next };
      }
      let name = body.repository_name as string;
      let repositoryID = body.repository_id as string;
      let owner = handle as string;
      if (body.action === "refresh_preview") {
        const reference = identity.repository_links.map(object).find((ref) => ref.link_id === body.link_id);
        if (!reference) throw new Failure("not_found");
        if (!decimal(reference.source_item_id)) throw readerFailure();
        repositoryID = reference.source_item_id;
        const path = repositoryPath(reference.url);
        name = path.name;
        owner = path.owner;
      }
      const repo = repository((await github(`/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}`))!.value);
      if (repo.row.repository_id !== repositoryID || repo.ownerID !== providerID || !repo.public) {
        throw new Failure("not_found");
      }
      const canonical = repositoryPath(repo.row.url);
      const readme = await github(`/repos/${encodeURIComponent(canonical.owner)}/${encodeURIComponent(canonical.name)}/readme`, true);
      let opening = "";
      if (readme) {
        const content = object(readme.value);
        if (content.encoding !== "base64" || typeof content.content !== "string") throw readerFailure();
        const encoded = content.content.replace(/[\r\n]/g, "");
        if (encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) throw readerFailure();
        const decoded = atob(encoded);
        if (decoded.length > MIB) throw readerFailure();
        const text = new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(decoded, (char) => char.charCodeAt(0)));
        opening = plain(text, 200);
      }
      const preview = { ...repo.row, opening_text: opening, verification_state: "verified" };
      if (body.action === "preview_repository") return { preview };
      if (body.action === "refresh_preview") return { link_id: body.link_id, preview };
      // The SQL transaction rechecks the live identity/owner under its locks.
      const link = await rpc("save_github_link", {
        repository_id: repositoryID, repository_owner_id: repo.ownerID, url: repo.row.url,
        title: body.title, description: body.description, main_language: body.main_language,
        tags: body.tags, opening_text: body.opening_text, visibility: body.visibility,
        replace_existing: body.replace_existing,
      });
      const keys = ["link_id", "source", "source_item_id", "url", "title", "description", "main_language", "tags", "opening_text", "visibility", "verification_state", "display_order"];
      if (Object.keys(link).length !== keys.length || keys.some((key) => !Object.hasOwn(link, key)) ||
        typeof link.link_id !== "string" || !UUID.test(link.link_id) || link.source !== "github" ||
        link.source_item_id !== repositoryID || link.url !== repo.row.url || link.verification_state !== "verified" ||
        !Number.isInteger(link.display_order) || Number(link.display_order) < 0 ||
        ["title", "description", "main_language", "tags", "opening_text", "visibility"].some((key) => JSON.stringify(link[key]) !== JSON.stringify(body[key]))) {
        throw readerFailure();
      }
      return { link };
    }
    try {
      const result = await Promise.race([work(), timeout]);
      remaining();
      const text = JSON.stringify(result);
      if (new TextEncoder().encode(text).byteLength > MIB) throw readerFailure();
      return new Response(text, { status: 200, headers: { "Content-Type": "application/json" } });
    } catch (error) {
      const failure = error instanceof Failure ? error : readerFailure();
      const status = failure.code === "not_authenticated" ? 401 : failure.code === "not_found" ? 404 : failure.code === "rate_limited" ? 429 : 400;
      return Response.json({ error: { code: failure.code, details: failure.details } }, { status });
    } finally {
      clearTimeout(timer);
      actionController.abort();
    }
  };
}
