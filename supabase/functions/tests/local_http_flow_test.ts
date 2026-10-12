// Opt in with both ENCOUNTERS_LOCAL_* variables and Deno's --allow-env and
// --allow-net permissions. Without environment permission the test is ignored,
// so the ordinary `deno test supabase/functions` needs no running stack.
function environment(name: string): string | undefined {
  if (
    Deno.permissions.querySync({ name: "env", variable: name }).state !==
      "granted"
  ) {
    return undefined;
  }
  return Deno.env.get(name)?.trim() || undefined;
}

const apiURL = environment("ENCOUNTERS_LOCAL_API_URL");
const publicKey = environment("ENCOUNTERS_LOCAL_PUBLIC_KEY");

function check(condition: unknown, message: string): asserts condition {
  // Never interpolate a response, credential, token, nonce or receipt in errors.
  if (!condition) throw new Error(message);
}

function object(value: unknown): Record<string, unknown> {
  check(
    value !== null && typeof value === "object" && !Array.isArray(value),
    "Expected a response object",
  );
  return value as Record<string, unknown>;
}

type Session = { access: string; userID: string };
type Window = { token: string; valid_from: number; valid_until: number };
type TokenPair = { own_token: string; peer_token: string; observed_at: number };
type Receipt = {
  id: string;
  protocol_version: number;
  role: "central" | "peripheral";
  exchange_nonce: string;
  prior_exchange_nonce?: string;
  start: TokenPair;
  checkpoint?: TokenPair;
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

function windows(value: unknown): Window[] {
  const batch = object(value);
  check(
    typeof batch.batch_id === "string" &&
      /^[0-9a-f-]{36}$/.test(batch.batch_id),
    "Expected a batch UUID",
  );
  check(
    Array.isArray(batch.windows) && batch.windows.length > 0,
    "Expected token windows",
  );
  const result: Window[] = [];
  for (const entry of batch.windows) {
    const window = object(entry);
    check(
      typeof window.token === "string" && /^[0-9a-f]{32}$/.test(window.token),
      "Expected a 16-byte lowercase hex token",
    );
    check(
      typeof window.valid_from === "number" &&
        Number.isSafeInteger(window.valid_from) &&
        window.valid_from % 900 === 0,
      "Expected an aligned whole-second window start",
    );
    check(
      typeof window.valid_until === "number" &&
        Number.isSafeInteger(window.valid_until) &&
        window.valid_until === window.valid_from + 900,
      "Expected a 900-second token window",
    );
    check(
      result.length === 0 ||
        result[result.length - 1].valid_until === window.valid_from,
      "Expected ordered consecutive windows",
    );
    result.push(window as Window);
  }
  check(
    new Set(result.map((window) => window.token)).size === result.length,
    "Expected unique tokens in a batch",
  );
  return result;
}

Deno.test({
  name: "local HTTP account, token and concurrent receipt flow",
  ignore: !apiURL || !publicKey,
  async fn() {
    check(apiURL && publicKey, "Expected both local API environment variables");
    let base: URL;
    try {
      base = new URL(apiURL.endsWith("/") ? apiURL : apiURL + "/");
    } catch {
      throw new Error("Expected a valid local API URL");
    }
    check(
      ["http:", "https:"].includes(base.protocol) &&
        ["localhost", "127.0.0.1", "[::1]"].includes(base.hostname) &&
        !base.username && !base.password && !base.search && !base.hash,
      "The HTTP flow test requires a loopback API URL",
    );

    async function request(
      path: string,
      method: string,
      parameters?: unknown,
      session?: Session,
      extraHeaders: Record<string, string> = {},
    ): Promise<{ status: number; value: unknown }> {
      let response: Response;
      try {
        response = await fetch(new URL(path, base), {
          method,
          headers: {
            apikey: publicKey!,
            "Content-Type": "application/json",
            Accept: "application/json",
            ...(session ? { Authorization: `Bearer ${session.access}` } : {}),
            ...extraHeaders,
          },
          body: parameters === undefined
            ? undefined
            : JSON.stringify(parameters),
          signal: AbortSignal.timeout(10_000),
          redirect: "error",
        });
      } catch {
        throw new Error("Local API request failed or timed out");
      }
      // Consume every body, including failures and logout, for Deno sanitizers.
      const text = await response.text();
      let value: unknown = null;
      if (text) {
        try {
          value = JSON.parse(text);
        } catch {
          throw new Error("Expected a JSON API response");
        }
      }
      return { status: response.status, value };
    }

    async function rpc(
      name: string,
      parameters: unknown,
      session: Session,
    ): Promise<unknown> {
      const response = await request(
        `rest/v1/rpc/${name}`,
        "POST",
        parameters,
        session,
      );
      check(
        response.status >= 200 && response.status < 300,
        `${name}: expected success, received HTTP ${response.status}`,
      );
      return response.value;
    }

    async function signIn(): Promise<Session> {
      const response = await request("auth/v1/signup", "POST", { data: {} });
      check(
        response.status >= 200 && response.status < 300,
        `Anonymous sign-in: expected success, received HTTP ${response.status}`,
      );
      const auth = object(response.value);
      const user = object(auth.user);
      check(
        typeof auth.access_token === "string" && auth.access_token.length > 0 &&
          typeof auth.refresh_token === "string" &&
          auth.refresh_token.length > 0 &&
          auth.token_type === "bearer",
        "Expected an Auth session",
      );
      check(
        typeof user.id === "string" && /^[0-9a-f-]{36}$/.test(user.id) &&
          user.is_anonymous === true,
        "Expected an anonymous account",
      );
      return { access: auth.access_token, userID: user.id };
    }

    async function submit(
      session: Session,
      receipts: Receipt[],
    ): Promise<string[]> {
      const response = await rpc("submit_receipts", { receipts }, session);
      check(
        Array.isArray(response) && response.length === receipts.length,
        "Expected one acknowledgement per receipt",
      );
      return response.map((entry, index) => {
        const ack = object(entry);
        check(
          Object.keys(ack).sort().join(",") === "id,status" &&
            ack.id === receipts[index].id,
          "Expected ordered acknowledgements containing only receipt ID and status",
        );
        check(
          typeof ack.status === "string" &&
            ["candidate", "resolved", "consumed", "rejected", "expired"]
              .includes(ack.status),
          "Expected a contractual receipt status",
        );
        return ack.status;
      });
    }

    const unauthenticated = await request(
      "rest/v1/rpc/get_own_profile",
      "POST",
      {},
    );
    check(
      [401, 403].includes(unauthenticated.status),
      "A call without a session must be refused",
    );
    const publicRead = await request("rest/v1/profiles?select=*", "GET");
    check(
      [401, 403, 404, 406].includes(publicRead.status),
      "A direct public table read must be refused",
    );

    const sessions: Session[] = [];
    try {
      // Fresh accounts and random identities isolate limiter and replay state on
      // a second run. No admin key or database cleanup API is needed.
      sessions.push(await signIn());
      sessions.push(await signIn());
      const [central, peripheral] = sessions;
      check(
        central.userID !== peripheral.userID,
        "Expected two different accounts",
      );
      const privateRead = await request(
        "rest/v1/profiles?select=*",
        "GET",
        undefined,
        central,
        { "Accept-Profile": "private" },
      );
      check(
        [401, 403, 404, 406].includes(privateRead.status),
        "A signed-in direct private table read must be refused",
      );

      await Promise.all(sessions.map(async (session, index) => {
        const zone = index === 0 ? "Asia/Tokyo" : "America/Los_Angeles";
        await rpc("accept_declarations", {
          age_18: true,
          terms_version: "development-draft",
          privacy_version: "development-draft",
        }, session);
        await rpc("register_time_zone", { time_zone: zone }, session);
        const profile = object(await rpc("get_own_profile", {}, session));
        check(
          profile.declarations_recorded === true &&
            profile.time_zone === zone &&
            profile.moderation_state === "active" &&
            profile.discovery_on === false,
          "Expected saved declarations and time zone with discovery off",
        );
      }));

      const interests = await rpc("list_interests", {}, central);
      check(
        Array.isArray(interests) && interests.length > 0,
        "Expected the local interest seed",
      );
      for (let index = 0; index < interests.length; index++) {
        const interest = object(interests[index]);
        check(
          typeof interest.interest_id === "string" &&
            interest.interest_id.length > 0 &&
            typeof interest.label_ja === "string" &&
            interest.label_ja.length > 0 &&
            typeof interest.label_en === "string" &&
            interest.label_en.length > 0 &&
            Number.isInteger(interest.display_order),
          "Expected bilingual interest wire fields",
        );
        if (index > 0) {
          const previous = object(interests[index - 1]);
          check(
            (previous.display_order as number) <=
              (interest.display_order as number),
            "Expected interests in display order",
          );
        }
      }

      const [centralWindows, peripheralWindows] = await Promise.all(
        sessions.map(async (session) =>
          windows(
            await rpc("issue_token_batch", { covered_until: null }, session),
          )
        ),
      );
      // Synthetic evidence claims 120 seconds; it does not keep a real radio
      // connection open. Use the first common issued window, even across a rollover.
      const start = Math.max(
        centralWindows[0].valid_from,
        peripheralWindows[0].valid_from,
      );
      function pair(side: number, observedAt: number): TokenPair {
        const batches = [centralWindows, peripheralWindows];
        const own = batches[side].find((window) =>
          window.valid_from <= observedAt && observedAt < window.valid_until
        );
        const peer = batches[1 - side].find((window) =>
          window.valid_from <= observedAt && observedAt < window.valid_until
        );
        check(
          own && peer,
          "Expected issued reciprocal tokens valid at the claimed whole second",
        );
        return {
          own_token: own.token,
          peer_token: peer.token,
          observed_at: observedAt,
        };
      }
      function receipts(
        exchange: string,
        observedAt: number,
        prior?: string,
        held = false,
      ): Receipt[] {
        return sessions.map((_, side) => ({
          id: crypto.randomUUID(),
          protocol_version: 1,
          role: side === 0 ? "central" : "peripheral",
          exchange_nonce: exchange,
          ...(prior ? { prior_exchange_nonce: prior } : {}),
          start: pair(side, observedAt),
          ...(held ? { checkpoint: pair(side, observedAt + 120) } : {}),
          observed_duration: 120,
          session_flag: false,
          is_final_evidence: true,
        }));
      }
      async function concurrent(halves: Receipt[][]): Promise<string[][]> {
        return await Promise.all(
          sessions.map((session, side) => submit(session, halves[side])),
        );
      }
      function resolved(statuses: string[][]): void {
        check(
          statuses.flat().every((status) =>
            ["candidate", "resolved"].includes(status)
          ) &&
            statuses.flat().includes("resolved"),
          "Concurrent reciprocal uploads must resolve",
        );
      }
      function consumed(statuses: string[][]): void {
        check(
          statuses.flat().every((status) => status === "consumed"),
          "Every resubmitted receipt must be terminal and consumed",
        );
      }

      const held = receipts(nonce(), start, undefined, true);
      resolved(await concurrent(held.map((receipt) => [receipt])));
      consumed(await concurrent(held.map((receipt) => [receipt])));

      const prior = nonce();
      const originals = receipts(prior, start);
      const pending = await concurrent(originals.map((receipt) => [receipt]));
      check(
        pending.flat().every((status) => status === "candidate"),
        "Original halves without checkpoints must remain candidates",
      );
      const joined = receipts(nonce(), start + 120, prior);
      resolved(await concurrent(joined.map((receipt) => [receipt])));
      consumed(
        await concurrent(
          sessions.map((_, side) => [originals[side], joined[side]]),
        ),
      );

      // Replaying the same exchanges with new receipt identities stays consumed,
      // and another retry cannot resurrect them.
      const replays = sessions.map((_, side) =>
        [held[side], originals[side], joined[side]]
          .map((receipt) => ({ ...receipt, id: crypto.randomUUID() }))
      );
      consumed(await concurrent(replays));
      consumed(await concurrent(replays));
    } finally {
      // Revoke only these test sessions. Account deletion belongs to Unit 4;
      // the isolated accounts and expiring evidence cannot obstruct another run.
      const logouts = await Promise.all(
        sessions.map((session) =>
          request("auth/v1/logout?scope=local", "POST", undefined, session)
        ),
      );
      check(
        logouts.every((response) =>
          response.status >= 200 && response.status < 300
        ),
        "Expected test sessions to sign out",
      );
    }
  },
});
