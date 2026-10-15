import { createHandler } from "../github-links/handler.ts";

// No remote assertion library or real network/environment permissions.
function check(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
function sorted(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sorted);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, sorted(v)]));
  }
  return value;
}
function equal(actual: unknown, expected: unknown, message = "Expected exact contractual JSON"): void {
  check(JSON.stringify(sorted(actual)) === JSON.stringify(sorted(expected)), message);
}
type Obj = Record<string, unknown>;
const ACCOUNT = "11111111-1111-4111-8111-111111111111";
const LINK = "22222222-2222-4222-8222-222222222222";
const USER_ID = "9007199254740993";
const REPO_ID = "9007199254740995";
const ORIGINAL = "https://github.com/octocat/toolkit";
const REPO = {
  id: REPO_ID, name: "toolkit", owner: { id: USER_ID, login: "octocat" },
  private: false, visibility: "public", description: "<b>Useful</b> &amp; safe",
  language: "Swift", topics: [" **tools** ", "tools", "<b>swift</b>"],
  html_url: "https://untrusted.example/ignored", download_url: "https://untrusted.example/ignored",
};
const ROW = {
  repository_id: REPO_ID, repository_name: "toolkit", title: "toolkit",
  description: "Useful & safe", main_language: "Swift", tags: ["tools", "swift"], url: ORIGINAL,
};
const PREVIEW = { ...ROW, opening_text: "Hello world & docs plain", verification_state: "verified" };
const SAVE = {
  action: "save_repository", repository_id: REPO_ID, repository_name: "toolkit",
  title: " Owner title ", description: " Edited description ", main_language: "  ",
  tags: [" own ", "own", "edited"], opening_text: " Edited opening ",
  visibility: "compatible_only", replace_existing: false,
};
const OWN_LINK = {
  link_id: LINK, source: "github", source_item_id: REPO_ID, url: ORIGINAL,
  title: "Owner title", description: "Edited description", main_language: null,
  tags: ["own", "edited"], opening_text: "Edited opening", visibility: "compatible_only",
  verification_state: "verified", display_order: 0,
};
function json(value: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json", ...headers } });
}
function upstream(value: unknown, headers: Record<string, string> = {}): Response {
  // Construct real JSON integer literals without ever creating rounded numbers.
  const text = JSON.stringify(value).replace(/"id":"([0-9]+)"/g, '"id":$1');
  return new Response(text, { headers: { "content-type": "application/json", ...headers } });
}
function base64(text: string): string {
  return btoa(Array.from(new TextEncoder().encode(text), (b) => String.fromCharCode(b)).join(""));
}
function readme(text = "# Hello **world** &amp; [docs](https://example.com) ![image](https://example.com/i)\n<script>steal()</script><style>hidden</style><b>plain</b>"): Response {
  return json({ encoding: "base64", content: base64(text), download_url: "https://raw.githubusercontent.com/never-read" });
}
function failure(code: string, details: string[] = []): unknown {
  return { error: { code, details } };
}
type Fixture = ReturnType<typeof fixture>;
type Hook = (url: URL, init: RequestInit, fixture: Fixture) => Response | undefined | Promise<Response | undefined>;
type RPCHook = (name: string, body: Obj, fixture: Fixture) => Response | undefined;
function fixture(options: {
  github?: Hook;
  rpc?: RPCHook;
  auth?: () => Response;
  env?: Record<string, string | undefined>;
} = {}) {
  const state = {
    time: 0, events: [] as string[], urls: [] as URL[], parameters: [] as { name: string; body: Obj }[],
    identity: {
      connected: true, provider_user_id: USER_ID as string | null, handle: "octocat" as string | null,
      verified_addresses: [], repository_links: [{ link_id: LINK, source_item_id: REPO_ID, url: ORIGINAL }],
    },
    repo: structuredClone(REPO),
    githubHeaders: [] as Headers[],
  };
  const env: Record<string, string | undefined> = {
    SUPABASE_URL: "https://backend.example", SUPABASE_ANON_KEY: "public-test-key",
    SUPABASE_SERVICE_ROLE_KEY: "server-test-key", ...options.env,
  };
  const injected: typeof fetch = async (input, init = {}) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    check(init.redirect === "manual", "All HTTP calls must disable automatic redirects");
    check(init.signal instanceof AbortSignal, "All HTTP calls must be abortable");
    state.urls.push(url);
    const headers = new Headers(init.headers);
    if (url.hostname === "backend.example") {
      if (url.pathname === "/auth/v1/user") {
        state.events.push("auth");
        equal(headers.get("authorization"), "Bearer caller-test-jwt", "Auth must get caller bearer");
        equal(headers.get("apikey"), "public-test-key", "Auth must get public key");
        return options.auth?.() ?? json({ id: ACCOUNT, is_anonymous: true });
      }
      check(url.pathname.startsWith("/rest/v1/rpc/"), "Only service RPCs may access the database");
      check(init.method === "POST", "RPC calls must POST");
      equal(headers.get("content-profile"), "service", "RPC schema must be service");
      equal(headers.get("apikey"), "server-test-key", "RPC uses server key");
      equal(headers.get("authorization"), "Bearer server-test-key", "RPC uses server bearer");
      const name = url.pathname.split("/").at(-1)!;
      const body = JSON.parse(init.body as string) as Obj;
      equal(body.account_id, ACCOUNT, "RPC account comes from verified Auth user");
      state.events.push(`rpc:${name}`);
      state.parameters.push({ name, body });
      const override = options.rpc?.(name, body, state as Fixture);
      if (override) return override;
      if (name === "get_github_identity") return json(state.identity);
      if (name === "record_github_fetch") return json({ allowed: true });
      if (name === "sync_github_identity") return json({ connected: true, handle: body.handle });
      if (name === "save_github_link") {
        return json({
          link_id: LINK, source: "github", source_item_id: body.repository_id,
          url: body.url, title: body.title, description: body.description,
          main_language: body.main_language, tags: body.tags, opening_text: body.opening_text,
          visibility: body.visibility, verification_state: "verified", display_order: 0,
        });
      }
      throw new Error("Unexpected service function");
    }
    equal(url.hostname, "api.github.com", "Only api.github.com may be read upstream");
    equal(url.protocol, "https:", "GitHub requires HTTPS");
    check(!url.port && !url.username && !url.password, "GitHub calls cannot have alternate ports/URL credentials");
    equal(state.events.at(-1), "rpc:record_github_fetch", "Reservation must precede every GitHub attempt");
    equal(headers.get("apikey"), null, "Backend key must not go to GitHub");
    equal(headers.get("accept-encoding"), "identity", "Received bytes must remain observable");
    state.events.push(`github:${url.pathname}`);
    state.githubHeaders.push(headers);
    const override = await options.github?.(url, init, state as Fixture);
    if (override) return override;
    if (url.pathname === `/user/${USER_ID}`) return upstream({ id: USER_ID, login: "octocat", blog: "Example.COM/a/../b/%7e?q=%41#fragment" });
    if (url.pathname === "/users/octocat/social_accounts") return json([
      { provider: "custom", url: "https://EXAMPLE.com:443/b/~?q=A#duplicate" },
      { provider: "custom", url: "https://social.example/users/octocat" },
      { provider: "custom", url: "http://unsafe.example" },
      { provider: "custom", url: "https://user:pass@unsafe.example" },
    ]);
    if (url.pathname === "/users/octocat/repos") return upstream([state.repo]);
    if (url.pathname === "/repos/octocat/toolkit") return upstream(state.repo);
    if (url.pathname === "/repos/octocat/toolkit/readme") return readme();
    throw new Error("Unexpected GitHub endpoint");
  };
  const handler = createHandler({ fetch: injected, env: (name) => env[name], now: () => state.time });
  return Object.assign(state, { handler });
}
async function call(f: Fixture, body: unknown, overrides: { method?: string; headers?: Record<string, string>; raw?: string } = {}) {
  const method = overrides.method ?? "POST";
  const response = await f.handler(new Request("https://edge.example/functions/v1/github-links", {
    method, headers: { "content-type": "application/json", Authorization: "Bearer caller-test-jwt", ...overrides.headers },
    body: ["GET", "HEAD"].includes(method) ? undefined : overrides.raw ?? JSON.stringify(body),
  }));
  equal(response.headers.get("content-type"), "application/json", "All results use JSON");
  return { status: response.status, value: await response.json() };
}
async function expectError(f: Fixture, body: unknown, status: number, code: string, details: string[] = [], overrides: Parameters<typeof call>[2] = {}) {
  const result = await call(f, body, overrides);
  equal(result.status, status, "Expected contractual HTTP error status");
  equal(result.value, failure(code, details));
}
const REQUEST = { action: "preview_repository", repository_id: REPO_ID, repository_name: "toolkit" };

Deno.test("github-links: all five actions return exact JSON with service-only writes", async () => {
  const sync = fixture();
  equal(await call(sync, { action: "sync_identity" }), { status: 200, value: { connected: true, handle: "octocat" } });
  equal(sync.parameters.find((p) => p.name === "sync_github_identity")?.body, {
    account_id: ACCOUNT, provider_user_id: USER_ID, handle: "octocat",
    verified_addresses: ["https://example.com/b/~?q=A", "https://social.example/users/octocat"],
  });
  const listing = fixture();
  equal(await call(listing, { action: "list_repositories", page: 1 }), { status: 200, value: { repositories: [ROW], next_page: null } });
  equal(listing.urls.at(-1)?.search, "?type=owner&sort=full_name&direction=asc&per_page=30&page=1");
  equal(await call(fixture(), REQUEST), { status: 200, value: { preview: PREVIEW } });
  const saving = fixture();
  equal(await call(saving, SAVE), { status: 200, value: { link: OWN_LINK } });
  equal(saving.parameters.find((p) => p.name === "save_github_link")?.body, {
    account_id: ACCOUNT, repository_id: REPO_ID, repository_owner_id: USER_ID, url: ORIGINAL,
    title: "Owner title", description: "Edited description", main_language: null,
    tags: ["own", "edited"], opening_text: "Edited opening", visibility: "compatible_only", replace_existing: false,
  });
  check(saving.events.indexOf("github:/repos/octocat/toolkit/readme") < saving.events.indexOf("rpc:save_github_link"), "Save must repeat repository/README reads first");
  const refresh = fixture();
  equal(await call(refresh, { action: "refresh_preview", link_id: LINK }), { status: 200, value: { link_id: LINK, preview: PREVIEW } });
  check(refresh.parameters.every((p) => p.name !== "save_github_link"), "Refresh preview must not write a link");
});

Deno.test("github-links: method, content type, body and unknown-key validation details", async () => {
  const f = fixture();
  await expectError(f, {}, 400, "invalid_input", ["method"], { method: "GET" });
  for (const type of ["text/plain", "application/jsonp", ""]) {
    await expectError(f, {}, 400, "invalid_input", ["body"], { headers: { "content-type": type } });
  }
  for (const raw of ["{", "null", "[]", "42", '"string"', " ".repeat(16 * 1024 + 1)]) {
    await expectError(f, {}, 400, "invalid_input", ["body"], { raw });
  }
  await expectError(f, {}, 400, "invalid_input", ["body"], { headers: { "content-length": String(16 * 1024 + 1) } });
  for (const action of [null, 1, "unknown", "toString", "__proto__"]) {
    await expectError(f, { action }, 400, "invalid_input", ["action"]);
  }
  await expectError(f, {}, 400, "invalid_input", ["action"]);
  for (const key of ["account_id", "url", "owner_id", "verification_state", "provider_user_id"]) {
    await expectError(f, { ...REQUEST, [key]: ACCOUNT }, 400, "invalid_input", [key]);
  }
  equal(f.events, [], "Invalid input must not reach backend or GitHub");
  equal(await call(f, { action: "sync_identity" }, { headers: { "content-type": "Application/JSON; charset=utf-8" } }), { status: 200, value: { connected: true, handle: "octocat" } });
});

Deno.test("github-links: field types, bounds, nullable fields and signature-ordered details", async () => {
  for (const page of [undefined, null, "1", 0, 1001, 1.5, true]) {
    await expectError(fixture(), { action: "list_repositories", page }, 400, "invalid_input", ["page"]);
  }
  for (const id of [undefined, null, 1, "0", "01", "-1", "1e3", "9223372036854775808", "12345678901234567890123456789"]) {
    await expectError(fixture(), { ...REQUEST, repository_id: id }, 400, "invalid_input", ["repository_id"]);
  }
  for (const name of [undefined, null, "", ".", "..", "a/b", "a%2fb", "a?b", "a#b", "x".repeat(101), "日本語"]) {
    await expectError(fixture(), { ...REQUEST, repository_name: name }, 400, "invalid_input", ["repository_name"]);
  }
  for (const link of [undefined, null, LINK.toUpperCase().replace("2222", "AAAA"), "not-a-uuid", 1]) {
    await expectError(fixture(), { action: "refresh_preview", link_id: link }, 400, "invalid_input", ["link_id"]);
  }
  const badValues: Record<string, unknown[]> = {
    title: [undefined, null, " ", "\u200b\u3164", "😀".repeat(101)],
    description: [undefined, null, 1, "😀".repeat(201)],
    main_language: [undefined, 1, "😀".repeat(31)],
    tags: [undefined, null, "tag", [null], [["tag"]], [" "], ["😀".repeat(31)], Array(11).fill("same")],
    opening_text: [undefined, null, false, "😀".repeat(201)],
    visibility: [undefined, null, "everyone", 1],
    replace_existing: [undefined, null, "true", 1],
  };
  for (const [field, values] of Object.entries(badValues)) {
    for (const value of values) await expectError(fixture(), { ...SAVE, [field]: value }, 400, "invalid_input", [field]);
  }
  await expectError(fixture(), { action: "save_repository" }, 400, "invalid_input", [
    "repository_id", "repository_name", "title", "description", "main_language", "tags", "opening_text", "visibility", "replace_existing",
  ]);
  const f = fixture();
  const result = await call(f, { ...SAVE, title: "\u0085😀\u3000", description: "😀".repeat(200), main_language: null, tags: [], opening_text: "", visibility: "private", replace_existing: true });
  equal(result.status, 200);
  equal(f.parameters.at(-1)?.body.title, "😀", "Trim must follow SQL rules and count code points");
  equal(f.parameters.at(-1)?.body.replace_existing, true);
});

Deno.test("github-links: missing/invalid JWT, deleted user, absent connection and backend failures", async () => {
  for (const authorization of ["", "Basic token", "Bearer", "Bearer a b"]) {
    const f = fixture();
    await expectError(f, REQUEST, 401, "not_authenticated", [], { headers: { authorization } });
    equal(f.events, []);
  }
  for (const status of [401, 403, 404]) {
    const f = fixture({ auth: () => json({ message: "invalid JWT" }, status) });
    await expectError(f, REQUEST, 401, "not_authenticated");
    equal(f.events, ["auth"]);
  }
  await expectError(fixture({ auth: () => json({ id: ACCOUNT, deleted_at: "2026-10-12" }) }), REQUEST, 401, "not_authenticated");
  await expectError(fixture({ auth: () => json({ message: "unavailable" }, 503) }), REQUEST, 400, "prerequisite_missing", ["github_reader"]);
  const absent = fixture();
  absent.identity.connected = false;
  absent.identity.provider_user_id = null;
  absent.identity.handle = null;
  await expectError(absent, REQUEST, 400, "prerequisite_missing", ["github"]);
  check(absent.githubHeaders.length === 0, "No upstream call without a live connection");
  await expectError(fixture({ rpc: () => json({ message: "database secret diagnostic" }, 500) }), REQUEST, 400, "prerequisite_missing", ["github_reader"]);
  await expectError(fixture({ env: { SUPABASE_SERVICE_ROLE_KEY: undefined } }), REQUEST, 400, "prerequisite_missing", ["github_reader"]);
});

Deno.test("github-links: stable SQL errors retain exact ordered details and HTTP mappings", async () => {
  for (const [code, status, details] of [
    ["not_authenticated", 401, []], ["not_found", 404, []], ["rate_limited", 429, []],
    ["account_not_ready", 400, []], ["declaration_required", 400, []],
    ["invalid_input", 400, ["title", "tags"]], ["prerequisite_missing", 400, ["refresh_confirmation"]],
  ] as [string, number, string[]][]) {
    const f = fixture({ rpc: (name) => name === "save_github_link" ? json({ message: code, details: details.length ? details.join(",") : null }, 400) : undefined });
    await expectError(f, SAVE, status, code, details);
  }
});

Deno.test("github-links: identity removed between preview and save cannot authorize cache or writes", async () => {
  const f = fixture();
  equal((await call(f, REQUEST)).status, 200);
  f.identity.connected = false;
  await expectError(f, SAVE, 400, "prerequisite_missing", ["github"]);
  check(f.parameters.every((p) => p.name !== "save_github_link"), "Disconnected save never writes");
  const duringRead = fixture({
    github: (url, _, state) => { if (url.pathname.endsWith("/readme")) state.identity.connected = false; return undefined; },
    rpc: (name, _, state) => name === "save_github_link" && !state.identity.connected
      ? json({ message: "not_found", details: null }, 400) : undefined,
  });
  await expectError(duringRead, SAVE, 404, "not_found");
});

Deno.test("github-links: every preview/save/refresh rechecks numeric ID, owner and public state", async () => {
  for (const action of [REQUEST, SAVE, { action: "refresh_preview", link_id: LINK }]) {
    for (const override of [
      { id: "9007199254740996" }, { owner: { id: "9007199254740994", login: "octocat" } },
      { private: true }, { visibility: "private" }, { visibility: "internal" },
    ]) {
      const f = fixture();
      Object.assign(f.repo, override);
      await expectError(f, action, 404, "not_found");
      check(f.githubHeaders.length === 1 && f.parameters.every((p) => p.name !== "save_github_link"), "Denied repo must stop before README/save");
    }
  }
  await expectError(fixture(), { action: "refresh_preview", link_id: "33333333-3333-4333-8333-333333333333" }, 404, "not_found");
});

Deno.test("github-links: renamed repositories follow bounded API redirects and save canonical verified URL", async () => {
  const renamedRow = { ...ROW, repository_name: "renamed", title: "renamed", url: "https://github.com/octocat/renamed" };
  const f = fixture({ github: (url, _, state) => {
    if (url.pathname === "/repos/octocat/toolkit") return new Response(null, { status: 301, headers: { location: "https://api.github.com:443/repos/octocat/renamed" } });
    if (url.pathname === "/repos/octocat/renamed") return upstream({ ...state.repo, name: "renamed" });
    if (url.pathname === "/repos/octocat/renamed/readme") return readme();
    return undefined;
  } });
  equal(await call(f, REQUEST), { status: 200, value: { preview: { ...PREVIEW, ...renamedRow } } });
  equal(await call(f, SAVE), { status: 200, value: { link: { ...OWN_LINK, url: renamedRow.url } } });
  equal(await call(f, { action: "refresh_preview", link_id: LINK }), { status: 200, value: { link_id: LINK, preview: { ...PREVIEW, ...renamedRow } } });
  equal(f.githubHeaders.length, 9, "Each redirect and README needs a reservation");
  for (const changed of [{ id: "8" }, { private: true }, { owner: { id: "8", login: "octocat" } }]) {
    const denied = fixture({ github: (url, _, state) => {
      if (url.pathname.endsWith("/toolkit")) return new Response(null, { status: 302, headers: { location: "/repos/octocat/renamed" } });
      return upstream({ ...state.repo, name: "renamed", ...changed });
    } });
    await expectError(denied, REQUEST, 404, "not_found");
  }
});

Deno.test("github-links: unsafe redirects and a fourth redirect are stopped before another reservation", async () => {
  for (const location of [
    "https://evil.example/repos/octocat/toolkit", "http://api.github.com/repos/octocat/toolkit",
    "https://api.github.com:444/repos/octocat/toolkit", "https://user:pass@api.github.com/repos/octocat/toolkit",
    "https://api.github.com.evil.example/repos/octocat/toolkit", "https://api.github.com/repos/octocat/toolkit#fragment",
  ]) {
    const f = fixture({ github: () => new Response(null, { status: 302, headers: { location } }) });
    await expectError(f, REQUEST, 400, "prerequisite_missing", ["github_reader"]);
    equal(f.githubHeaders.length, 1);
    equal(f.parameters.filter((p) => p.name === "record_github_fetch").length, 1);
  }
  const loop = fixture({ github: () => new Response(null, { status: 307, headers: { location: "/repos/octocat/toolkit" } }) });
  await expectError(loop, REQUEST, 400, "prerequisite_missing", ["github_reader"]);
  equal(loop.githubHeaders.length, 4, "At most three followed redirects");
  const allowed = fixture({ github: (url, _, state) => state.githubHeaders.length <= 3
    ? new Response(null, { status: 308, headers: { location: "/repos/octocat/toolkit" } }) : undefined });
  equal((await call(allowed, REQUEST)).status, 200);
  equal(allowed.githubHeaders.length, 5, "Three redirects, repository response and README");
});

Deno.test("github-links: streamed/declared oversize, compressed, invalid and unavailable upstream responses", async () => {
  let cancelled = false;
  const streamed = fixture({ github: () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(1024 * 1024)); controller.enqueue(new Uint8Array(1)); },
    cancel() { cancelled = true; },
  }), { headers: { "content-type": "application/json" } }) });
  await expectError(streamed, REQUEST, 400, "prerequisite_missing", ["github_reader"]);
  check(cancelled, "Oversized body must be cancelled while streaming");
  for (const response of [
    json({}, 200, { "content-length": String(1024 * 1024 + 1) }),
    json({}, 200, { "content-encoding": "gzip" }),
    new Response("not JSON", { headers: { "content-type": "application/json" } }),
    new Response("<html>not JSON</html>", { headers: { "content-type": "text/html" } }),
    new Response(new Uint8Array([0xff]), { headers: { "content-type": "application/json" } }),
    json({}, 500), json({}, 401),
  ]) {
    await expectError(fixture({ github: () => response }), REQUEST, 400, "prerequisite_missing", ["github_reader"]);
  }
  await expectError(fixture({ github: () => { throw new Error("sensitive network diagnostic"); } }), REQUEST, 400, "prerequisite_missing", ["github_reader"]);
  await expectError(fixture({ github: () => json({}, 404) }), REQUEST, 404, "not_found");
  await expectError(fixture({ github: () => json({}, 403) }), REQUEST, 404, "not_found");
});

Deno.test("github-links: attempt and whole-action deadlines include slow streams/backend calls", async () => {
  const slow = fixture({ github: (_, __, state) => { state.time += 5000; return upstream(state.repo); } });
  await expectError(slow, REQUEST, 400, "prerequisite_missing", ["github_reader"]);
  equal(slow.githubHeaders.length, 1);
  const deadline = fixture({
    rpc: (name, _, state) => { if (name === "record_github_fetch") state.time += 4000; return undefined; },
    github: (_, __, state) => {
      state.time += 3000;
      return new Response(null, { status: 301, headers: { location: "/repos/octocat/toolkit" } });
    },
  });
  await expectError(deadline, REQUEST, 400, "prerequisite_missing", ["github_reader"]);
  check(deadline.time >= 20_000 && deadline.githubHeaders.length === 3, "Action budget must span reservations and redirects");
  let cancelled = false;
  let aborted = false;
  const stalled = fixture({ github: (_, init) => {
    init.signal!.addEventListener("abort", () => { aborted = true; }, { once: true });
    return new Response(new ReadableStream({ cancel() { cancelled = true; } }), { headers: { "content-type": "application/json" } });
  } });
  const before = performance.now();
  await expectError(stalled, REQUEST, 400, "prerequisite_missing", ["github_reader"]);
  check(performance.now() - before < 7000 && cancelled && aborted, "Actual 5-second timeout must abort and cancel stalled stream");
});

Deno.test("github-links: upstream throttling and refused reservations stop reads and writes", async () => {
  for (const response of [
    json({}, 429), json({}, 403, { "x-ratelimit-remaining": "0" }),
    json({}, 403, { "retry-after": "60" }), json({ message: "secondary rate limit exceeded" }, 403),
  ]) await expectError(fixture({ github: () => response }), SAVE, 429, "rate_limited");
  for (const denied of [json({ allowed: false }), json({ message: "rate_limited", details: null }, 400)]) {
    const f = fixture({ rpc: (name) => name === "record_github_fetch" ? denied : undefined });
    await expectError(f, SAVE, 429, "rate_limited");
    equal(f.githubHeaders.length, 0);
  }
  const refusedRedirect = fixture({
    rpc: (name, _, state) => name === "record_github_fetch" && state.githubHeaders.length > 0
      ? json({ message: "rate_limited", details: null }, 400) : undefined,
    github: () => new Response(null, { status: 301, headers: { location: "/repos/octocat/renamed" } }),
  });
  await expectError(refusedRedirect, SAVE, 429, "rate_limited");
  equal(refusedRedirect.githubHeaders.length, 1);
});

Deno.test("github-links: Basic app authentication is used only when both values are real", async () => {
  for (const env of [
    {}, { GITHUB_APP_CLIENT_ID: "app" }, { GITHUB_APP_CLIENT_SECRET: "secret" },
    { GITHUB_APP_CLIENT_ID: "", GITHUB_APP_CLIENT_SECRET: "secret" },
    { GITHUB_APP_CLIENT_ID: "app", GITHUB_APP_CLIENT_SECRET: "" },
    { GITHUB_APP_CLIENT_ID: "placeholder-app", GITHUB_APP_CLIENT_SECRET: "secret" },
    { GITHUB_APP_CLIENT_ID: "app", GITHUB_APP_CLIENT_SECRET: "placeholder-secret" },
    { GITHUB_APP_CLIENT_ID: " ", GITHUB_APP_CLIENT_SECRET: "secret" },
  ]) {
    const f = fixture({ env });
    equal((await call(f, REQUEST)).status, 200);
    check(f.githubHeaders.every((h) => h.get("authorization") === null), "Unconfigured/placeholder calls must be unauthenticated");
  }
  const f = fixture({ env: { GITHUB_APP_CLIENT_ID: "app-test", GITHUB_APP_CLIENT_SECRET: "secret-test" } });
  equal((await call(f, { action: "sync_identity" })).status, 200);
  check(f.githubHeaders.every((h) => h.get("authorization") === `Basic ${btoa("app-test:secret-test")}`), "Only server Basic credentials may go to GitHub");
});

Deno.test("github-links: README absent, malformed base64, markup and code-point truncation", async () => {
  const absent = fixture({ github: (url) => url.pathname.endsWith("/readme") ? json({}, 404) : undefined });
  equal(await call(absent, REQUEST), { status: 200, value: { preview: { ...PREVIEW, opening_text: "" } } });
  for (const value of [
    { encoding: "none", content: "hello" }, { encoding: "base64", content: "%%%" },
    { encoding: "base64", content: "abc" }, { encoding: "base64", content: "/w==" },
    { encoding: "base64", download_url: "https://raw.githubusercontent.com/ignored" },
  ]) await expectError(fixture({ github: (url) => url.pathname.endsWith("/readme") ? json(value) : undefined }), REQUEST, 400, "prerequisite_missing", ["github_reader"]);
  const f = fixture({ github: (url) => url.pathname.endsWith("/readme")
    ? readme("<!-- comment --><script>bad</script><style>bad</style>![image](https://evil) <img src=x> **😀** ".repeat(300)) : undefined });
  f.repo.description = "<p>" + "😀".repeat(201) + "</p>";
  f.repo.language = "😀".repeat(31);
  f.repo.topics = ["😀".repeat(31), "<script>bad</script>", "one", "one", ...Array.from({ length: 20 }, (_, i) => `tag${i}`)];
  const result = await call(f, REQUEST);
  equal(result.status, 200);
  const preview = (result.value as { preview: Obj }).preview;
  equal(preview.description, "😀".repeat(200));
  equal(preview.main_language, "😀".repeat(30));
  equal(Array.from(preview.opening_text as string).length, 200);
  check(!String(preview.opening_text).includes("bad") && !String(preview.opening_text).includes("image"), "Scripts/styles/images must be omitted");
  equal(preview.tags, ["😀".repeat(30), "one", ...Array.from({ length: 8 }, (_, i) => `tag${i}`)]);
  const entities = fixture({ github: (url) => url.pathname.endsWith("/readme") ? readme("&lt;b&gt; &quot;x&quot; &#39;y&#39; &#x1F600; &copy;") : undefined });
  equal(await call(entities, REQUEST), { status: 200, value: { preview: { ...PREVIEW, opening_text: '<b> "x" \'y\' 😀 ©' } } });
  const code = fixture({ github: (url) => url.pathname.endsWith("/readme") ? readme("# Heading\n```swift\nlet my_value = 1\n```\n_underlined_ and ~~removed~~ [ref][id]\n[id]: https://example.com") : undefined });
  equal(await call(code, REQUEST), { status: 200, value: { preview: { ...PREVIEW, opening_text: "Heading let my_value = 1 underlined and removed ref" } } });
});

Deno.test("github-links: nested Markdown destinations, linked images and unknown entities stay plain text", async () => {
  const f = fixture({ github: (url) => url.pathname.endsWith("/readme") ? readme(
    "## Heading ##\n[docs](https://example.com/a(b(c))) " +
    "[![badge](https://example.com/image)](https://example.com/badge) " +
    "![alt](https://example.com/a(b)) [reference][id]\n" +
    "[id]: https://example.com\nSubtitle\n========\n" +
    "&constructor; &toString; &copy; \\![literal](https://example.com) " +
    'İ<script data-value=">">omit me</script> `*literal*`',
  ) : undefined });
  equal(await call(f, REQUEST), { status: 200, value: { preview: {
    ...PREVIEW, opening_text: "Heading docs reference Subtitle &constructor; &toString; © !literal İ *literal*",
  } } });
});

Deno.test("github-links: large unterminated markup stays within the action budget", async () => {
  const source = "<".repeat(100_000) + " *a".repeat(100_000) + "`".repeat(100_000);
  const f = fixture({ github: (url) => url.pathname.endsWith("/readme") ? readme(source) : undefined });
  const before = performance.now();
  equal(await call(f, REQUEST), { status: 200, value: { preview: { ...PREVIEW, opening_text: "<".repeat(200) } } });
  check(performance.now() - before < 10_000, "Untrusted markup must not block the action timeout with backtracking");
});

Deno.test("github-links: hostile heading lines and U+0085 runs have bounded processing time", async () => {
  // Near the wire limit for descriptions, and below it after base64 for README.
  // Also exercise a failing closing-heading match within the scan bound.
  for (const source of [
    "# " + " ".repeat(12_000) + "x",
    "# " + " ".repeat(1024 * 1024 - 4099) + "x",
    "text" + "\u0085".repeat(500_000),
  ]) {
    const response = readme(source.slice(0, 350_000));
    const f = fixture({ github: (url) => url.pathname.endsWith("/readme") ? response : undefined });
    f.repo.description = source;
    const before = performance.now();
    const result = await call(f, REQUEST);
    const elapsed = performance.now() - before;
    equal(result.status, 200);
    check(elapsed < 5_000, `Hostile fetched text took ${elapsed}ms; expected under 5000ms`);
    const preview = (result.value as { preview: Obj }).preview;
    const expected = source.startsWith("text") ? "text" : source.length < 16_384 ? "x" : "";
    equal(preview.description, expected);
    equal(preview.opening_text, expected);
  }
  const edited = fixture();
  const before = performance.now();
  equal(await call(edited, { ...SAVE, title: "Owner title" + "\u0085".repeat(7000) }), {
    status: 200, value: { link: OWN_LINK },
  });
  check(performance.now() - before < 5_000, "Edited U+0085 runs must trim in under 5000ms");
  const separators = fixture({ github: (url) => url.pathname.endsWith("/readme")
    ? readme("[unclosed\u2028".repeat(30_000)) : undefined });
  const separatorStart = performance.now();
  equal(await call(separators, REQUEST), { status: 200, value: { preview: {
    ...PREVIEW, opening_text: "[unclosed ".repeat(20),
  } } });
  check(performance.now() - separatorStart < 5_000, "Unicode line boundaries must not cause repeated suffix scans");
});

Deno.test("github-links: unclosed HTML attribute quotes never expose markup or script bodies", async () => {
  for (const quote of ['"', "'"]) {
    const source = `intro <${quote} <script>alert(1)</script> <img src=x onerror=y> tail`;
    const f = fixture({ github: (url) => url.pathname.endsWith("/readme") ? readme(source) : undefined });
    f.repo.description = source;
    const result = await call(f, REQUEST);
    equal(result.status, 200);
    const preview = (result.value as { preview: Obj }).preview;
    for (const text of [preview.description, preview.opening_text]) {
      check(!/script|alert|img|onerror|src|>/i.test(String(text)), "Quote-prefixed ordinary text must not expose tags or script bodies");
    }
    for (const closingQuote of ["", quote]) {
      const tagSource = `intro <a title=${quote} <script>alert(1)</script> <img src=x onerror=y> tail${closingQuote}`;
      const tag = fixture({ github: (url) => url.pathname.endsWith("/readme") ? readme(tagSource) : undefined });
      tag.repo.description = tagSource;
      equal(await call(tag, REQUEST), { status: 200, value: { preview: {
        ...PREVIEW, description: "intro", opening_text: "intro",
      } } });
    }
  }
});

Deno.test("github-links: unterminated tags fail closed and ordinary less-than text survives", async () => {
  for (const [source, expected] of [
    ['intro <a title="><script>alert(1)</script>"', "intro"],
    ["intro <img src=x onerror=alert(1)", "intro"],
    // The closing delimiter is beyond the 16 KiB scan bound, with or without quotes.
    ...["", '"', "'"].map((quote) => [
      `intro <a title=${quote}${"x".repeat(16_384)}${quote}> tail`, "intro",
    ]),
    ["Parses JSON in <1ms, and it does not allocate", "Parses JSON in <1ms, and it does not allocate"],
  ]) {
    const f = fixture({ github: (url) => url.pathname.endsWith("/readme") ? readme(source) : undefined });
    f.repo.description = source;
    equal(await call(f, REQUEST), { status: 200, value: { preview: {
      ...PREVIEW, description: expected, opening_text: expected,
    } } });
  }
});

Deno.test("github-links: fetched text drops NUL and unpaired surrogates while edits reject them", async () => {
  const f = fixture({ github: (url) => url.pathname.endsWith("/readme")
    ? readme("a\u0000b &#0; &#x0; 😀") : undefined });
  f.repo.description = "a\u0000b\ud800c\udfffd😀";
  f.repo.language = "\u0000Swift\ud800";
  f.repo.topics = ["\u0000tools\udfff", "😀", "\u0000"];
  equal(await call(f, REQUEST), { status: 200, value: { preview: {
    ...PREVIEW, description: "abcd😀", main_language: "Swift", tags: ["tools", "😀"],
    opening_text: "ab 😀",
  } } });
  for (const invalid of ["\u0000", "\ud800", "\udfff"]) {
    for (const field of ["title", "description", "main_language", "tags", "opening_text"]) {
      const edited = fixture();
      const value = `text${invalid}`;
      await expectError(edited, { ...SAVE, [field]: field === "tags" ? [value] : value }, 400, "invalid_input", [field]);
      equal(edited.events, [], "Invalid database text must be refused before any reader or backend call");
    }
  }
});

Deno.test("github-links: verified addresses are canonical bounded evidence and never fetched", async () => {
  const f = fixture({ github: (url) => {
    if (url.pathname === `/user/${USER_ID}`) return upstream({
      id: USER_ID, login: "octocat", blog: "https://EXAMPLE.com.:443/a/%2e%2e/b/%7e?q=%2f#discard",
      provider_token: "ignored-user-credential",
    });
    if (url.pathname.endsWith("/social_accounts")) return json([
      { url: "https://example.com/b/~?q=%2F#duplicate" },
      { url: "https://social.example/a/../user/%6fctocat" },
      { url: "https://user:pass@social.example" }, { url: "http://social.example" },
      { url: "https://social.example/%zz" }, { url: "https://social.example/" + "a".repeat(2048) },
    ]);
    return undefined;
  } });
  equal(await call(f, { action: "sync_identity" }), { status: 200, value: { connected: true, handle: "octocat" } });
  equal(f.parameters.at(-1)?.body.verified_addresses, [
    "https://example.com/b/~?q=%2F", "https://social.example/user/octocat",
  ]);
  equal(f.githubHeaders.length, 2);
  check(f.githubHeaders.every((h) => !h.has("authorization")), "Profile credentials must never authenticate reader calls");
});

Deno.test("github-links: list filtering keeps next page even when empty and caps at page 1000", async () => {
  const f = fixture({ github: (url, _, state) => url.pathname.endsWith("/repos") ? upstream([
    { ...state.repo, private: true }, { ...state.repo, owner: { id: "1", login: "someone" } },
  ], { link: `<https://api.github.com/user/${USER_ID}/repos?type=owner&sort=full_name&direction=asc&per_page=30&page=2>; rel="next", <https://api.github.com/user/${USER_ID}/repos?page=4>; rel="last"` }) : undefined });
  equal(await call(f, { action: "list_repositories", page: 1 }), { status: 200, value: { repositories: [], next_page: 2 } });
  equal(f.githubHeaders.length, 1, "Never fetch another repository page to fill filtered results");
  const last = fixture({ github: () => upstream([REPO], { link: `<https://api.github.com/user/${USER_ID}/repos?page=1001>; rel="next"` }) });
  equal(await call(last, { action: "list_repositories", page: 1000 }), { status: 200, value: { repositories: [ROW], next_page: null } });
});

Deno.test("github-links: real numeric-ID next links page through more than 30 owned repositories", async () => {
  const repos = Array.from({ length: 31 }, (_, i) => ({ ...REPO, id: String(BigInt(REPO_ID) + BigInt(i)) }));
  const f = fixture({ github: (url) => url.pathname.endsWith("/repos")
    ? upstream(url.searchParams.get("page") === "1" ? repos.slice(0, 30) : repos.slice(30),
      url.searchParams.get("page") === "1" ? {
        link: `<https://api.github.com/user/${USER_ID}/repos?per_page=99&type=all&page=2>; rel="next"`,
      } : {}) : undefined });
  equal(await call(f, { action: "list_repositories", page: 1 }), { status: 200, value: {
    repositories: repos.slice(0, 30).map((repo) => ({ ...ROW, repository_id: repo.id })), next_page: 2,
  } });
  equal(f.githubHeaders.length, 1, "An action fetches only its requested page");
  equal(await call(f, { action: "list_repositories", page: 2 }), { status: 200, value: {
    repositories: [{ ...ROW, repository_id: repos[30].id }], next_page: null,
  } });
  equal(f.urls.filter((url) => url.hostname === "api.github.com").map((url) => url.href), [
    "https://api.github.com/users/octocat/repos?type=owner&sort=full_name&direction=asc&per_page=30&page=1",
    "https://api.github.com/users/octocat/repos?type=owner&sort=full_name&direction=asc&per_page=30&page=2",
  ], "Requests are built by the server, ignoring addresses and other parameters from the header");
  const handle = fixture({ github: () => upstream([REPO], {
    link: '<https://api.github.com/users/octocat/repos?page=2>; rel="next"',
  }) });
  equal(await call(handle, { action: "list_repositories", page: 1 }), {
    status: 200, value: { repositories: [ROW], next_page: 2 },
  });
});

Deno.test("github-links: next links for other identities or unpinned addresses are refused", async () => {
  for (const address of [
    "https://api.github.com/user/9007199254740992/repos?page=2",
    "https://api.github.com/users/someone/repos?page=2",
    `http://api.github.com/user/${USER_ID}/repos?page=2`,
    `https://evil.example/user/${USER_ID}/repos?page=2`,
    `https://api.github.com:444/user/${USER_ID}/repos?page=2`,
    `https://user:pass@api.github.com/user/${USER_ID}/repos?page=2`,
    `https://api.github.com/user/${USER_ID}/repos?page=3`,
  ]) {
    const f = fixture({ github: () => upstream([REPO], { link: `<${address}>; rel="next"` }) });
    await expectError(f, { action: "list_repositories", page: 1 }, 400, "prerequisite_missing", ["github_reader"]);
    equal(f.githubHeaders.length, 1, "An invalid next link must never be fetched");
  }
});

Deno.test("github-links: uncached handle comes from numeric profile and IDs retain all digits", async () => {
  const f = fixture();
  f.identity.handle = null;
  equal(await call(f, REQUEST), { status: 200, value: { preview: PREVIEW } });
  equal(f.events.filter((e) => e.startsWith("github:")), [`github:/user/${USER_ID}`, "github:/users/octocat/social_accounts", "github:/repos/octocat/toolkit", "github:/repos/octocat/toolkit/readme"]);
  const bound = fixture({ github: (url, _, state) => url.pathname.endsWith("/toolkit") ? upstream({ ...state.repo, id: "9223372036854775807" }) : undefined });
  equal(await call(bound, { ...REQUEST, repository_id: "9223372036854775807" }), { status: 200, value: { preview: { ...PREVIEW, repository_id: "9223372036854775807" } } });
  for (const text of [
    JSON.stringify(REPO).replace(`"${REPO_ID}"`, "9007199254740995.0"),
    JSON.stringify(REPO).replace(`"${REPO_ID}"`, "9.007199254740995e15"),
    JSON.stringify(REPO).replace(`"${REPO_ID}"`, "9223372036854775808"),
  ]) await expectError(fixture({ github: () => new Response(text, { headers: { "content-type": "application/json" } }) }), REQUEST, 400, "prerequisite_missing", ["github_reader"]);
});

Deno.test("github-links: unsynced repository actions establish cache before repository fetch reservations", async () => {
  for (const body of [REQUEST, SAVE, { action: "refresh_preview", link_id: LINK }]) {
    let synced = false;
    const f = fixture({
      rpc: (name) => {
        if (name === "sync_github_identity") synced = true;
        if (name === "save_github_link") check(synced, "Save requires the established cache");
      },
      github: (url) => {
        if (url.pathname.startsWith("/repos/")) check(synced, "Sync must precede repository reads");
      },
    });
    f.identity.handle = null;
    equal((await call(f, body)).status, 200);
    equal(f.events, [
      "auth", "rpc:get_github_identity",
      "rpc:record_github_fetch", `github:/user/${USER_ID}`,
      "rpc:record_github_fetch", "github:/users/octocat/social_accounts", "rpc:sync_github_identity",
      "rpc:record_github_fetch", "github:/repos/octocat/toolkit",
      "rpc:record_github_fetch", "github:/repos/octocat/toolkit/readme",
      ...(body.action === "save_repository" ? ["rpc:save_github_link"] : []),
    ], "Every attempt has its own reservation; sync finishes before repository budget is spent");
    equal(f.parameters.find((p) => p.name === "sync_github_identity")?.body.provider_user_id, USER_ID);
  }
});

Deno.test("github-links: failed first sync spends no repository fetch budget for any repository action", async () => {
  for (const body of [REQUEST, SAVE, { action: "refresh_preview", link_id: LINK }]) {
    const f = fixture({ rpc: (name) => name === "sync_github_identity"
      ? json({ message: "not_found", details: null }, 404) : undefined });
    f.identity.handle = null;
    await expectError(f, body, 404, "not_found");
    equal(f.events, [
      "auth", "rpc:get_github_identity", "rpc:record_github_fetch", `github:/user/${USER_ID}`,
      "rpc:record_github_fetch", "github:/users/octocat/social_accounts", "rpc:sync_github_identity",
    ]);
  }
});
