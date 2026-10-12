// Run against a reset local stack with all four ENCOUNTERS_LOCAL_* variables set:
// deno test --allow-env=ENCOUNTERS_LOCAL_API_URL,ENCOUNTERS_LOCAL_PUBLIC_KEY,ENCOUNTERS_LOCAL_SERVICE_KEY,ENCOUNTERS_LOCAL_DB_URL --allow-net --allow-run=psql supabase/functions/tests/unit4_http_flow_test.ts
// The tester resets the database afterwards; this test performs no cleanup.
function environment(name: string): string | undefined {
  if (
    Deno.permissions.querySync({ name: "env", variable: name }).state !==
      "granted"
  ) return undefined;
  return Deno.env.get(name)?.trim() || undefined;
}

const apiURL = environment("ENCOUNTERS_LOCAL_API_URL");
const publicKey = environment("ENCOUNTERS_LOCAL_PUBLIC_KEY");
const serviceKey = environment("ENCOUNTERS_LOCAL_SERVICE_KEY");
const dbURL = environment("ENCOUNTERS_LOCAL_DB_URL");

function check(condition: unknown, message: string): asserts condition {
  // Never include credentials, tokens, codes, database addresses or responses.
  if (!condition) throw new Error(message);
}

function object(value: unknown): Record<string, unknown> {
  check(
    value !== null && typeof value === "object" && !Array.isArray(value),
    "The API must return a JSON object",
  );
  return value as Record<string, unknown>;
}

function sorted(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sorted);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).sort(([a], [b]) => a.localeCompare(b))
        .map(([key, entry]) => [key, sorted(entry)]),
    );
  }
  return value;
}

function equal(actual: unknown, expected: unknown, message: string): void {
  check(JSON.stringify(sorted(actual)) === JSON.stringify(sorted(expected)), message);
}

function localURL(value: string, database = false): URL {
  let url: URL;
  try {
    url = new URL(value.endsWith("/") || database ? value : value + "/");
  } catch {
    throw new Error("The flow test requires valid local URLs");
  }
  check(
    (database
      ? ["postgres:", "postgresql:"].includes(url.protocol)
      : ["http:", "https:"].includes(url.protocol)) &&
      ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname) &&
      (database || (!url.username && !url.password)) && !url.search && !url.hash,
    "The flow test must use loopback URLs without routing query parameters",
  );
  return url;
}

type Account = { access: string; userID: string };
type Session = {
  session_id: string;
  starts_at: number;
  expires_at: number;
  server_time: number;
};
type Window = { token: string; valid_from: number; valid_until: number };
type Receipt = {
  id: string;
  protocol_version: number;
  role: "central" | "peripheral";
  exchange_nonce: string;
  start: { own_token: string; peer_token: string; observed_at: number };
  observed_duration: number;
  session_flag: boolean;
  is_final_evidence: boolean;
};

function nonce(): string {
  return Array.from(
    crypto.getRandomValues(new Uint8Array(16)),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
}

function uuid(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f-]{36}$/.test(value);
}

function session(value: unknown): Session {
  const result = object(value);
  check(
    Object.keys(result).sort().join(",") ===
      "expires_at,server_time,session_id,starts_at" && uuid(result.session_id) &&
      Number.isSafeInteger(result.starts_at) &&
      Number.isSafeInteger(result.expires_at) &&
      Number.isSafeInteger(result.server_time),
    "An active session must contain only its ID and whole-second server times",
  );
  const active = result as Session;
  check(
    active.expires_at === active.starts_at + 7200 &&
      active.starts_at <= active.server_time && active.server_time < active.expires_at,
    "A started session must be active for exactly two hours",
  );
  return active;
}

function windows(value: unknown): Window[] {
  const batch = object(value);
  check(uuid(batch.batch_id), "Token issue must identify its batch with a UUID");
  check(
    Array.isArray(batch.windows) && batch.windows.length > 0,
    "A fresh account must receive token windows",
  );
  return batch.windows.map((entry) => {
    const window = object(entry);
    check(
      typeof window.token === "string" && /^[0-9a-f]{32}$/.test(window.token) &&
        typeof window.valid_from === "number" && Number.isSafeInteger(window.valid_from) &&
        window.valid_from % 900 === 0 &&
        window.valid_until === window.valid_from + 900,
      "Issued tokens must use aligned 900-second windows and 16-byte hex values",
    );
    return window as Window;
  });
}

// The only direct database write: one INSERT with psql's quoted parameters.
// Live Auth identities cannot be fabricated by sync_github_identity itself.
async function installGithubIdentities(
  database: string,
  accounts: Account[],
  providerIDs: string[],
): Promise<void> {
  localURL(database, true);
  const identities = accounts.map((account, index) => ({
    id: crypto.randomUUID(), user_id: account.userID, provider_id: providerIDs[index],
  }));
  try {
    const child = new Deno.Command("psql", {
      args: ["-X", "--no-password", "--set=ON_ERROR_STOP=1",
        `--set=identities=${JSON.stringify(identities)}`, "--file=-"],
      env: {
        PGDATABASE: database, PGCONNECT_TIMEOUT: "5",
        PGOPTIONS: "-c statement_timeout=10000",
      },
      stdin: "piped", stdout: "null", stderr: "null",
    }).spawn();
    const writer = child.stdin.getWriter();
    await writer.write(new TextEncoder().encode(`
      insert into auth.identities
        (id, user_id, provider, provider_id, identity_data, created_at, updated_at)
      select i.id, i.user_id, 'github', i.provider_id,
        pg_catalog.jsonb_build_object('sub', i.provider_id), pg_catalog.now(), pg_catalog.now()
      from pg_catalog.jsonb_to_recordset(:'identities'::jsonb)
        as i(id uuid, user_id uuid, provider_id text);
    `));
    await writer.close();
    const result = await child.status;
    check(result.success, "The parameterised Auth identity fixture must succeed");
  } catch {
    throw new Error("The local psql Auth identity fixture failed");
  }
}

Deno.test({
  name: "local HTTP linked-account sessions, QR race, favorites and saved links",
  ignore: !apiURL || !publicKey || !serviceKey || !dbURL,
  async fn() {
    check(apiURL && publicKey && serviceKey && dbURL,
      "All four local-stack environment variables must be supplied");
    const base = localURL(apiURL);
    localURL(dbURL, true);

    async function request(
      path: string,
      parameters: unknown,
      account?: Account,
      server = false,
      schema = "public",
    ): Promise<{ status: number; value: unknown }> {
      let response: Response;
      try {
        response = await fetch(new URL(path, base), {
          method: "POST",
          headers: {
            apikey: server ? serviceKey! : publicKey!,
            "Content-Type": "application/json", Accept: "application/json",
            "Content-Profile": schema,
            ...(server ? { Authorization: `Bearer ${serviceKey}` }
              : account ? { Authorization: `Bearer ${account.access}` } : {}),
          },
          body: JSON.stringify(parameters),
          signal: AbortSignal.timeout(10_000), redirect: "error",
        });
      } catch {
        throw new Error("Local API request failed or timed out");
      }
      // Consume failures too, so response bodies do not leak sanitizer resources.
      const body = await response.text();
      let value: unknown = null;
      if (body) {
        try { value = JSON.parse(body); }
        catch { throw new Error("The local API must return JSON"); }
      }
      return { status: response.status, value };
    }

    async function rpc(
      name: string, parameters: unknown, account?: Account, server = false,
    ): Promise<unknown> {
      const result = await request(`rest/v1/rpc/${name}`, parameters, account,
        server, server ? "service" : "public");
      check(result.status >= 200 && result.status < 300,
        `${name} must succeed over HTTP (received ${result.status})`);
      return result.value;
    }

    async function signIn(): Promise<Account> {
      const result = await request("auth/v1/signup", { data: {} });
      check(result.status >= 200 && result.status < 300,
        "Anonymous signup must succeed over HTTP");
      const auth = object(result.value);
      const user = object(auth.user);
      check(typeof auth.access_token === "string" && auth.access_token.length > 0 &&
        typeof auth.refresh_token === "string" && auth.refresh_token.length > 0 &&
        auth.token_type === "bearer" && uuid(user.id) && user.is_anonymous === true,
        "Signup must create a fresh anonymous account with a usable Auth session");
      return { access: auth.access_token, userID: user.id };
    }

    // The third fresh participant is the competing QR redeemer.
    const accounts = [await signIn(), await signIn(), await signIn()];
    check(new Set(accounts.map((account) => account.userID)).size === 3,
      "The session pair and competing QR redeemer must be distinct fresh accounts");
    await Promise.all(accounts.map(async (account) => {
      await rpc("accept_declarations", {
        age_18: true, terms_version: "development-draft", privacy_version: "development-draft",
      }, account);
      await rpc("register_time_zone", { time_zone: "Asia/Tokyo" }, account);
    }));
    const catalogue = await rpc("list_interests", {}, accounts[0]);
    check(Array.isArray(catalogue) && catalogue.length > 0,
      "Local seed data must provide an interest for discovery readiness");
    const interestID = object(catalogue[0]).interest_id;
    check(typeof interestID === "string" && interestID.length > 0,
      "The public catalogue must supply a valid interest identifier");
    const providerIDs = accounts.map(() =>
      (BigInt("0x" + nonce().slice(0, 15)) + 1n).toString());
    await installGithubIdentities(dbURL, accounts, providerIDs);
    const names = accounts.map((_, index) => `HTTP participant ${index + 1}`);
    const ownLinks = await Promise.all(accounts.map(async (account, index) => {
      const handle = `http-${nonce().slice(0, 16)}`;
      equal(await rpc("sync_github_identity", {
        account_id: account.userID, provider_user_id: providerIDs[index], handle,
        verified_addresses: [],
      }, undefined, true), { connected: true, handle },
      "Server sync must cache the matching live GitHub identity");
      equal(await rpc("get_github_connection", {}, account), { connected: true, handle },
        "The public connection read must see the live identity and matching cache");
      const link = object(await rpc("save_github_link", {
        account_id: account.userID, repository_id: providerIDs[index],
        repository_owner_id: providerIDs[index], url: `https://github.com/${handle}/demo`,
        title: "HTTP demo", description: "A verified test repository", main_language: "Swift",
        tags: ["demo"], opening_text: "Hello from the HTTP test",
        visibility: "everyone_eligible", replace_existing: false,
      }, undefined, true));
      check(uuid(link.link_id) && link.source === "github" && link.verification_state === "verified",
        "Server link save must create a verified GitHub link with an ID");
      await rpc("update_own_profile", {
        display_name: names[index], introduction: "A local HTTP participant",
        contact_detail: "private contact must never appear on a card",
      }, account);
      await rpc("set_own_interests", { interest_ids: [interestID] }, account);
      await rpc("set_own_purposes", { purposes: ["discovery"] }, account);
      await rpc("set_discovery", { enabled: true }, account);
      const profile = object(await rpc("get_own_profile", {}, account));
      check(profile.discovery_on === true && profile.link_count === 1 &&
        profile.declarations_recorded === true && profile.time_zone === "Asia/Tokyo" &&
        profile.moderation_state === "active",
        "Public setup must produce a ready, discovering account holding exactly one link");
      return link;
    }));

    async function feed(account: Account): Promise<Record<string, unknown>[]> {
      const result = object(await rpc("get_encounter_feed", {}, account));
      check(Object.keys(result).sort().join(",") === "cards,truncated" &&
        Array.isArray(result.cards) && result.truncated === false,
        "The small test feed must return cards without truncation or extra envelope fields");
      return result.cards.map(object);
    }

    function authorizedCard(card: Record<string, unknown>, peer: number, inFeed: boolean): void {
      const keys = ["encounter_id", "kind", "day", "display_name", "introduction",
        "interests", "purposes", "links", "favorite", "saved_link_ids"];
      if (inFeed) keys.push("shared_interest_ids");
      check(Object.keys(card).every((key) => keys.includes(key)) &&
        uuid(card.encounter_id) && typeof card.day === "string" &&
        /^\d{4}-\d{2}-\d{2}$/.test(card.day) && card.favorite === false,
        "An initial card must expose only authorized wire fields and favorite false");
      equal(card.display_name, names[peer], "The card must identify the other participant by authorized name");
      equal(card.introduction, "A local HTTP participant", "The card must contain the authorized introduction");
      equal(card.interests, [interestID], "The card must contain only the counterpart's authorized interests");
      equal(card.purposes, ["discovery"], "The card must contain the counterpart's authorized purpose");
      check(!("contact_detail" in card), "Private contact information must be absent, even when populated");
      const { link_id, source, url, title, description, main_language, tags, opening_text,
        verification_state } = ownLinks[peer];
      equal(card.links, [{ link_id, source, url, title, description, main_language, tags,
        opening_text, verification_state }],
      "Visible links must expose the verified link ID and metadata without owner or source-item identifiers");
      if (inFeed) {
        equal(card.shared_interest_ids, [interestID],
          "The feed may expose the shared intersection when interests are authorized");
      }
      if (!inFeed || "saved_link_ids" in card) {
        equal(card.saved_link_ids, [], "A fresh card must have no saved link references");
      }
    }

    equal(await rpc("get_own_session", {}, accounts[0]), null,
      "The session-start race must begin with no active session");
    const [starts, peerStart] = await Promise.all([
      Promise.all([rpc("start_session", {}, accounts[0]), rpc("start_session", {}, accounts[0])]),
      rpc("start_session", {}, accounts[1]),
    ]);
    const first = session(starts[0]);
    const racing = session(starts[1]);
    const second = session(peerStart);
    equal([racing.session_id, racing.starts_at, racing.expires_at],
      [first.session_id, first.starts_at, first.expires_at],
      "Concurrent starts from no active session must return one unchanged session ID and interval");
    equal(session(await rpc("get_own_session", {}, accounts[0])).session_id, first.session_id,
      "The active-session read must return the single ID produced by concurrent starts");

    const batches = await Promise.all(accounts.slice(0, 2).map(async (account) =>
      windows(await rpc("issue_token_batch", { covered_until: null }, account))));
    // Use server times, not the beginning of a window that predates the sessions.
    const observedAt = Math.max(first.server_time, second.server_time,
      batches[0][0].valid_from, batches[1][0].valid_from);
    const exchange = nonce();
    const receipts: Receipt[] = accounts.slice(0, 2).map((_, side) => {
      const own = batches[side].find((window) =>
        window.valid_from <= observedAt && observedAt < window.valid_until);
      const peer = batches[1 - side].find((window) =>
        window.valid_from <= observedAt && observedAt < window.valid_until);
      check(own && peer, "Session evidence must use reciprocal tokens valid at the same observation time");
      return {
        id: crypto.randomUUID(), protocol_version: 1,
        role: side === 0 ? "central" : "peripheral", exchange_nonce: exchange,
        start: { own_token: own.token, peer_token: peer.token, observed_at: observedAt },
        observed_duration: 0, session_flag: true, is_final_evidence: true,
      };
    });
    const uploads = await Promise.all(accounts.slice(0, 2).map((account, side) =>
      rpc("submit_receipts", { receipts: [receipts[side]] }, account)));
    const statuses = uploads.map((value, side) => {
      check(Array.isArray(value) && value.length === 1,
        "Each concurrent upload must acknowledge exactly its one receipt");
      const ack = object(value[0]);
      check(Object.keys(ack).sort().join(",") === "id,status" && ack.id === receipts[side].id &&
        ["candidate", "resolved"].includes(String(ack.status)),
        "Reciprocal session uploads must acknowledge only receipt ID and candidate/resolved status");
      return ack.status;
    });
    check(statuses.includes("resolved"),
      "Concurrent reciprocal receipts with both session flags must resolve immediately without duration evidence");
    const pairFeeds = await Promise.all(accounts.slice(0, 2).map(feed));
    for (let side = 0; side < 2; side++) {
      check(pairFeeds[side].length === 1 && pairFeeds[side][0].kind === "session",
        "Each participant must immediately see exactly one session card after reciprocal uploads");
      authorizedCard(pairFeeds[side][0], 1 - side, true);
      const card = object(await rpc("get_encounter_card", {
        encounter_id: pairFeeds[side][0].encounter_id,
      }, accounts[side]));
      authorizedCard(card, 1 - side, false);
      equal([card.encounter_id, card.kind, card.day],
        [pairFeeds[side][0].encounter_id, "session", pairFeeds[side][0].day],
        "Detail must refer to the same session encounter and viewer-local day as the feed");
    }
    equal(pairFeeds[0][0].encounter_id, pairFeeds[1][0].encounter_id,
      "Both viewers must see the same single confirmed session encounter");
    // stop_session updates all active rows with RETURNING: duplicate rows would
    // fail this HTTP call. A null subsequent read also proves no row was left active.
    equal(session(await rpc("stop_session", {}, accounts[0])).session_id, first.session_id,
      "Stopping after concurrent starts must affect exactly the one returned session");
    equal(await rpc("get_own_session", {}, accounts[0]), null,
      "Stopping the raced session must leave no duplicate active session behind");
    session(await rpc("start_session", {}, accounts[0]));

    const qr = object(await rpc("issue_qr_code", {}, accounts[0]));
    check(Object.keys(qr).sort().join(",") === "code,expires_at" &&
      typeof qr.code === "string" && /^[0-9a-f]{32}$/.test(qr.code) &&
      Number.isSafeInteger(qr.expires_at),
      "QR issue must return only a 16-byte hex code and whole-second expiry");
    const redemptions = await Promise.all(accounts.slice(1).map((account) =>
      request("rest/v1/rpc/redeem_qr_code", { code: qr.code }, account)));
    const winners = redemptions.filter((result) => result.status >= 200 && result.status < 300);
    const losers = redemptions.filter((result) => result.status < 200 || result.status >= 300);
    check(winners.length === 1 && losers.length === 1,
      "Two different accounts redeeming one QR concurrently must have exactly one winner");
    const winner = object(winners[0].value);
    check(Object.keys(winner).join(",") === "encounter_id" && uuid(winner.encounter_id),
      "Exactly one QR redemption must return an encounter ID");
    const failure = object(losers[0].value);
    check(failure.message === "not_found" &&
      (failure.details === null || failure.details === undefined || failure.details === ""),
      "The losing concurrent QR redemption must return indistinguishable not_found without detail");
    const winnerIndex = redemptions.indexOf(winners[0]) + 1;
    const issuerFeed = await feed(accounts[0]);
    const qrCards = issuerFeed.filter((card) => card.kind === "qr");
    check(qrCards.length === 1 && qrCards[0].encounter_id === winner.encounter_id,
      "The QR issuer must learn the single winning encounter by reading the feed");
    authorizedCard(qrCards[0], winnerIndex, true);

    const encounterID = pairFeeds[0][0].encounter_id;
    const linkID = ownLinks[1].link_id;
    equal(await rpc("set_encounter_favorite", { encounter_id: encounterID, favorite: true }, accounts[0]),
      { encounter_id: encounterID, favorite: true }, "Favorite write must affect the caller's encounter view");
    equal(await rpc("save_link", { encounter_id: encounterID, link_id: linkID }, accounts[0]),
      { encounter_id: encounterID, link_id: linkID, saved: true },
      "Saving an authorized counterpart link must return its encounter/link reference");
    const savedCard = object(await rpc("get_encounter_card", { encounter_id: encounterID }, accounts[0]));
    check(savedCard.favorite === true, "Detail must reflect the caller's saved favorite state");
    equal(savedCard.saved_link_ids, [linkID], "Detail must return exactly the caller's saved link ID");
    equal(savedCard.links, pairFeeds[0][0].links,
      "Favoriting and saving must preserve the currently authorized counterpart link metadata");
    check(Array.isArray(savedCard.links) && savedCard.links.length === 1,
      "The saved encounter detail must still expose exactly its authorized counterpart link");
    equal(await rpc("list_saved_links", {}, accounts[0]), {
      links: [{ encounter_id: encounterID, day: savedCard.day, kind: "session",
        link: savedCard.links[0] }], truncated: false,
    }, "Saved-link listing must return the one live authorized reference and current link metadata");
    const otherCard = object(await rpc("get_encounter_card", { encounter_id: encounterID }, accounts[1]));
    equal([otherCard.favorite, otherCard.saved_link_ids], [false, []],
      "Favorite and saved-link mutations must not change the other viewer's state");

    for (const account of [undefined, accounts[0]]) {
      const denied = await request("rest/v1/rpc/get_github_identity",
        { account_id: accounts[0].userID }, account, false, "service");
      check([401, 403, 404, 406].includes(denied.status),
        account ? "A user credential must be refused access to the service schema"
          : "The anonymous public key must be refused access to the service schema");
    }
    const serverDenied = await request("rest/v1/rpc/get_own_profile", {}, undefined, true, "public");
    check([401, 403, 404].includes(serverDenied.status),
      "The server key must be refused execute permission on public client functions");

    for (const account of accounts.slice(0, 2)) {
      session(await rpc("get_own_session", {}, account));
      equal(await rpc("set_discovery", { enabled: false }, account), null,
        "Turning discovery off must preserve the public function's null return");
      equal(await rpc("get_own_session", {}, account), null,
        "Discovery off must stop the account's active session in the same transaction");
      const deniedFeed = await request("rest/v1/rpc/get_encounter_feed", {}, account);
      check(deniedFeed.status >= 400 && deniedFeed.status < 500,
        "Discovery off must refuse the feed over HTTP");
      const error = object(deniedFeed.value);
      check(error.message === "prerequisite_missing" && error.details === "discovery",
        "The refused feed must name discovery as its sole missing prerequisite");
    }
  },
});
