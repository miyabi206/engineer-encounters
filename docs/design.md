# Design — Engineer Encounters

**Version:** 0.4\
**Status:** Draft architecture; drafting defaults and unverified items labelled\
**Date:** 2026-10-11\
**Related:** `decisions.md` v0.4, `specification.md` v0.4, `ui.md` v0.2\
**Platforms:** iOS first, Android later\
**Languages:** Japanese, English

Engineer Encounters (Japanese: **すれちがいエンジニア**) retains **Engineer StreetPass** only as its internal codename and repository name. Public screens, notifications and store text use the public names.

`decisions.md` is authoritative, followed by `specification.md`. **DEFAULT** identifies a proposed implementation choice or a drafting default inherited from those documents, including built values that may still change. **FACT** and **UNVERIFIED** retain their evidence markings. **FACT:** Units 1 (Toolchain) and 2 (Bluetooth engine) are implemented and merged to main in pull requests 2, 4 and 5. This document distinguishes their built behaviour, the owner's 2026-10-11 device results and decisions, and the remaining implementation plan. The three presence decisions made that day are binding but not yet implemented.

## Architecture decisions

- Build a native iOS app with SwiftUI and Core Bluetooth. Android follows later using the same backend and protocol.
- Promise the One open rung after its device gate. Locked and Awake remain unproven and are described as “may also work”. All five rungs operate together, without mode switching or fixed hardware.
- Confirm Bluetooth encounters from both phones' receipts. Ambient encounters require two minutes; only two active sessions permit immediate confirmation. QR is the manual alternative.
- Reveal ambient encounters at the daily report. Session and QR encounters reveal immediately. Never issue someone-is-nearby prompts.
- Use durable release accounts, external links and server-enforced, current visibility. Matching orders encounters and gates compatible-only fields; it does not hide incompatible encounters.
- Store encounter dates, never location or durable encounter times. Include block, report, favorites, saved links and immediate in-app account deletion in v1.
- Operate v1 as a free, ad-free product with no purchases, built by one owner part-time on an individual Apple developer account. Release in Japan first, with Japanese UI first, an 18+ declaration at sign-up and an 18+ App Store minimum age.

The scope is `specification.md`, **Scope of v1**. Screen definitions belong in `ui.md`, **Navigation**, **The 26 screens** and **Surfaces outside the app**.

## Stack, tools and workflow

### Languages and runtime

| Area | Technology and responsibility |
|---|---|
| iOS | Swift 6.4, SwiftUI, minimum iOS 26.0; built with Xcode 27.0. |
| Radio | Core Bluetooth; every phone is a central and a peripheral. |
| Local storage | SwiftData; pending receipts behind a replaceable queue interface. SQLite is the fallback if background writes misbehave. |
| Token storage | CryptoKit and Keychain. |
| Session surfaces | Live Activity and a one-tap widget or Control Center control. |
| Manual encounter | Camera QR scanning. |
| Backend | TypeScript Supabase Edge Functions; SQL PostgreSQL schema, access rules and server functions. |
| Managed services | Supabase free-plan Auth, PostgreSQL, Edge Functions and Cron. |
| Notifications | APNs for the daily report. |
| Public website | Plain HTML privacy policy, terms and support pages, available as URLs. |

Core Bluetooth is the selected framework for background discovery between strangers without pairing and for a later Android implementation. The simulator has no Bluetooth; it tests the interface and encounter logic through a fake.

Supabase Auth provides native Sign in with Apple and links GitHub to an already signed-in account. GitHub is verification, never an alternative sign-in. Release sign-up records the 18+ declaration and acceptance of the terms and privacy policy.

**FACT:** Supabase may pause a free-plan project with low activity over a 7-day period; paid projects are not paused. A quiet week after release can take the service offline until the owner restores it manually. **FACT:** Supabase labels manual identity linking and Cron as beta. These are operational dependencies, not reliability guarantees.

### Build kinds

| Build kind | Distribution | Included features |
|---|---|---|
| Development | Run or cable-installed from the owner's Mac. | Temporary anonymous sign-in, immediate ambient demo switch, diagnostics. |
| Internal | TestFlight only to the owner's own devices. | Demo switch and diagnostics; Sign in with Apple, no anonymous sign-in. |
| Release | App Store; TestFlight for the 20-person event, made with the release configuration against the production backend. | Sign in with Apple; anonymous sign-in, the demo switch and diagnostics are all compiled out. |

The table is the distribution and feature contract for v1; authentication and reveal are not implemented yet. **FACT:** XcodeGen defines `Development`, `Internal` and `Release`. Unit 2 compiles `ios/App/Development` only into Development and `ios/App/Diagnostics` only into Development and Internal. Per-configuration `EXCLUDED_SOURCE_FILE_NAMES` is anchored at `$(SRCROOT)/App`, with conditional compilation at declarations and call sites. Development defines `DEVELOPMENT_BUILD`, Internal defines `INTERNAL_BUILD`, and Release defines neither. The localized development and diagnostics string tables follow the same exclusions.

**FACT:** `ios/Tests/check-release-artifact.sh` builds all three configurations and checks marker names and bundled Japanese/English string tables. Local test tokens and the S01 → S22 entry are Development-only. Internal includes diagnostics support but has no route to S22 until the Settings list exists. The demo switch persists a setting; it has no reveal consumer yet and never changes exchange or evidence logic.

**DEFAULT:** the friends test uses development builds pointed at a hosted non-production Supabase project, because the phones leave the owner's Mac. Anonymous sign-in is enabled only on that non-production project and disabled on production, in addition to being compiled out of the release build. Local Supabase is for automated checks and the owner's own development. Internal testing also uses a hosted non-production backend. **DEFAULT:** only local and hosted non-production environments expose the demo reveal endpoint. **UNVERIFIED:** whether the Supabase free plan allows the second, hosted non-production project. The production backend has no such endpoint, and a client-supplied build label never grants access. The switch changes ambient reveal and notification timing, never the two-minute or both-receipts rules. Device tests use the same switch; free-account tests show results in-app without push.

### Repository

The top-level directories are binding. **FACT:** the iOS packages, thin app, scripts and tests below exist after Unit 2; `EncounterDomainTestSupport` is a separate library product inside the domain package. **DEFAULT:** `SessionActivity` and `site` remain planned paths.

```text
.
├── ios/
│   ├── project.yml                 # XcodeGen input
│   ├── EngineerEncounters.xcodeproj # generated, never edited by hand
│   ├── App/                        # thin composition and SwiftUI entry point
│   │   ├── Composition/            # AppComposition, EncounterRuntime, participation
│   │   ├── Development/            # Development-only entry and local test issuer
│   │   └── Diagnostics/            # Development/Internal S22 and trial logs
│   ├── Scripts/                    # typecheck-app.sh
│   ├── SessionActivity/            # planned Live Activity and one-tap control
│   ├── Packages/
│   │   ├── EncounterDomain/         # EncounterDomain + EncounterDomainTestSupport
│   │   ├── EncounterBluetooth/
│   │   ├── EncounterStorage/
│   │   ├── EncounterBackend/
│   │   └── EncounterUI/
│   └── Tests/                      # app integration and release checks
├── supabase/
│   ├── migrations/
│   ├── functions/
│   └── tests/database/
├── site/                           # planned bilingual legal and support HTML
└── docs/                           # decisions, requirements, design and UI
```

### Terminal checks and owner's tools

**FACT:** Unit 1 established terminal entry points for packages, simulator builds, backend functions and the local database. Run the commands separately for each unit; empty areas still have smoke checks. The three simulator configurations check the build gates. **DEFAULT:** use the iPhone 17 simulator, which exists on the owner's Mac. **FACT:** the EngineerEncounters scheme tests the app-hosted tests and the EncounterBluetooth and EncounterUI package tests. EncounterBluetooth also declares macOS, so its package tests run directly on the Mac.

```sh
swift test --package-path ios/Packages/EncounterDomain
swift test --package-path ios/Packages/EncounterBluetooth
swift test --package-path ios/Packages/EncounterStorage
swift test --package-path ios/Packages/EncounterBackend
sh ios/Scripts/typecheck-app.sh Development
sh ios/Scripts/typecheck-app.sh Internal
sh ios/Scripts/typecheck-app.sh Release
sh ios/Tests/check-release-artifact.sh
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/EngineerEncounters.xcodeproj -scheme EngineerEncounters -configuration Development -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios/EngineerEncounters.xcodeproj -scheme EngineerEncounters -configuration Internal -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios/EngineerEncounters.xcodeproj -scheme EngineerEncounters -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios/EngineerEncounters.xcodeproj -scheme EngineerEncounters -configuration Development -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO test
deno test supabase/functions
supabase test db
```

**DEFAULT:** start Docker and use `supabase start` and `supabase db reset` to prepare the local database before its checks. Grant backend tests only their declared local permissions. These are implementation entry points, not checks run by this documentation update. **FACT:** the documented unsigned simulator test skips the real Keychain round-trip when it returns `errSecMissingEntitlement`. It does not verify locked-device file protection: the storage package's protection assertion is iOS-only and needs a device run; locked access must also be checked on a device.

The owner's Mac has macOS 27.0.1, Xcode 27.0 with the iOS 27.0 SDK and simulator, Swift 6.4, Homebrew, Supabase CLI, Docker, Node and Codex CLI. **FACT:** XcodeGen and Deno are installed. Add the VS Code Swift extension if still needed.

**FACT:** plain `swift test` fails in the implementing agent's sandbox on the module-cache path. This form passes there; replace `<Package>` with the package name:

```sh
env XDG_CACHE_HOME=$PWD/.build/sandbox/xdg CLANG_MODULE_CACHE_PATH=$PWD/.build/sandbox/clang SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.build/sandbox/manifest swift test --disable-sandbox --package-path ios/Packages/<Package> --cache-path $PWD/.build/sandbox/swiftpm-cache --config-path $PWD/.build/sandbox/swiftpm-config --security-path $PWD/.build/sandbox/swiftpm-security --manifest-cache local
```

The same cache and sandbox options with `swift build --triple arm64-apple-ios26.0-simulator --sdk <iPhoneSimulator SDK path>` compile iOS-only package code there. **FACT:** `ios/Scripts/typecheck-app.sh` accepts Development, Internal or Release and type-checks the app without `xcodebuild`; Development also type-checks the hosted tests. XcodeGen, `xcodebuild`, app-hosted test execution, `ios/Tests/check-release-artifact.sh` and every Supabase command do not run in that sandbox. The tester role runs those checks outside it.

### VS Code and cross-harness

The owner develops in VS Code with cross-harness. One agent plans and reviews; another implements a bounded unit. Each unit becomes one commit on a work branch, and the owner merges. Preserve existing work, keep secrets out of task files and logs, and do not launch another harness from a delegated executor.

Agents write Swift, TypeScript, SQL, tests and XcodeGen configuration and run terminal checks. **FACT:** the implementing role uses the sandbox-compatible Swift commands and type-check script; the tester role runs Xcode generation/builds, hosted tests, artifact checks and Supabase checks outside the sandbox. The owner uses Xcode or their own hands for Apple ID code signing, cable installs, every real-device Bluetooth trial, battery measurements and App Store submission screens. Agents can prepare the diagnostics and written test sheet; they cannot replace radio trials with simulator results.

## System architecture

```mermaid
flowchart TD
    UI[SwiftUI app and session surfaces]
    BLE[Core Bluetooth adapter]
    LOGIC[Encounter logic and token provider]
    LOCAL[(SwiftData receipt queue)]
    KEYS[Keychain]
    AUTH[Supabase Auth: Apple and linked GitHub]
    API[Authenticated Edge Functions]
    SQL[Restricted authorization and resolution functions]
    DB[(PostgreSQL)]
    READERS[GitHub / Qiita / Zenn / other-page readers]
    SOURCES[Original public sources]
    CRON[Supabase Cron]
    APNS[APNs]
    WEB[Plain HTML legal and support site]

    UI --> LOGIC
    LOGIC <--> BLE
    LOGIC --> LOCAL
    LOGIC --> KEYS
    UI --> AUTH
    UI --> API
    LOCAL --> API
    API --> SQL
    SQL --> DB
    API --> READERS
    READERS --> SOURCES
    UI -->|open original link| SOURCES
    CRON -->|daily report and retention| API
    API --> APNS
    APNS --> UI
    UI --> WEB
```

Radio discovery and local receipt persistence do not wait for the network. Upload and resolution happen later. The app never reads another user's database rows directly; server functions produce authorized cards. Link readers keep bounded preview metadata, while external platforms remain the hosts of the original works.

## iOS app structure

**FACT:** Units 1 and 2 established the following packages and interfaces; rows identify the areas still planned.

| Package | Responsibility |
|---|---|
| `EncounterDomain` | Deterministic synchronous `EncounterEngineCore`, actor runtime `EncounterEngine`, two-minute rule, token-window selection, receipt models, clocks and command/event interfaces; no Core Bluetooth imports. |
| `EncounterDomainTestSupport` | Separate library product: `FakeBluetoothTransport`, paired-phones rig, manual clock, queue contract and test confirmation check. The app never links it. |
| `EncounterBluetooth` | `CBCentralManager` and `CBPeripheralManager`, GATT framing, connection limits and restoration. |
| `EncounterStorage` | `SwiftDataReceiptQueue` model actor and `KeychainTokenBatchStore`; no encounter authorization. |
| `EncounterBackend` | Placeholder and smoke check now; authenticated uploads, card APIs, link readers, sessions, QR and push registration remain planned. |
| `EncounterUI` | Localized `WelcomeView` now; onboarding, Discover, Profile, Settings and shared states remain planned with standard iOS components, teal accent, light/dark modes and Dynamic Type. |

**FACT:** Unit 2 changed `BluetoothTransport` from the planned completed-exchange interface to radio primitives. Commands are `startDiscovery`, `stopDiscovery`, `connect`, `read`, `write`, `disconnect`, `answerRead` and `answerWrite`. Its ordered event stream emits `availabilityChanged`, `peerObserved`, `connected`, `connectFailed`, `frameRead`, `readFailed`, `writeAcknowledged`, `writeFailed`, `disconnected`, `incomingRead`, `incomingWrite` and `restored`. Values use provisional local peer handles rather than framework objects. The encounter engine owns the entire exchange; the core returns ordered effects and deadlines, and the actor serializes radio, token and storage I/O.

**FACT:** `FakeBluetoothTransport`, `PairedPhonesRig`, `ManualEncounterClock` and `TestEncounterConfirmation` live in `EncounterDomainTestSupport`, linked by tests only. The fake exercises the real engine protocol logic, including disconnections, reordered events, token rotation and one-sided results. The confirmation check requires reciprocal receipts and cannot confirm from one fake phone. Unit 2 changed the planned device confirmation harness to a test-only check. There is no on-device two-receipt confirmation harness. S22 shows only that device's two-minute evidence with an exchange digest, the first 8 hexadecimal characters of SHA-256 of the exchange nonce; the owner compares both screens.

**FACT:** `ReceiptQueue` exposes durable enqueue/update, pending reads, terminal acknowledgement, expiry removal and clearing. `SwiftDataReceiptQueue` is the built adapter; `InMemoryReceiptQueue` serves tests. Writes succeed only after storage succeeds. Candidate acceptance is nonterminal: retain the receipt for checkpoint updates and later status checks until confirmation, definitive rejection or expiry. Terminal acknowledgement removes it idempotently and retains a bounded identity tombstone. **DEFAULT:** SQLite remains a replaceable fallback; the upload worker is not built yet.

**FACT:** `AppComposition` owns `EncounterRuntime` and a persisted local participation switch, default off. No Bluetooth manager is created before that switch is on and durable storage is ready. `App.init` recreates the runtime when the persisted switch is on, including background relaunch for state restoration; foregrounding refreshes it. Until sessions exist the session flag source always returns false. Development issues local test tokens through `LocalTestTokenIssuer`, a 12-hour batch of quarter-hour-aligned 15-minute windows stored in Keychain. Internal and Release have no issuer and, without a valid batch, stay paused for lack of a token until Unit 3 supplies server tokens. This local participation switch enables no-account radio trials; server profile prerequisites remain required for product discovery.

Sessions, still planned, have a two-hour expiry or an explicit stop, a Live Activity, and a one-tap start control. **DEFAULT:** use a Control Center control backed by the same session-start use case as the button. Server acknowledgement starts a new session; offline users can finish an already-started session but cannot claim a new server session. A local stop immediately clears the local session flag and queues the server stop.

**DEFAULT:** the labelled sample encounter is a dismissible on-device fixture, never a server encounter. Other people's cards are held only in memory and re-fetched on opening or foregrounding; clear them on sign-out, access changes or loss of a fresh authorization response. Favorites and saved links store references, not permanent profile snapshots.

## Bluetooth transport

### Service and characteristic contract

**FACT:** Unit 2 uses one fixed application service UUID. Every participating phone with available radio and a valid token advertises it and scans explicitly for it. Tokens never appear in advertisements. The central connects, reads the peripheral's token and writes its own token, so one connection supplies both phones with the other's token.

**FACT:** these UUIDs and the version-1 layout are defined in `EncounterProtocol` and `ExchangeFrame`.

| Item | UUID | Operation |
|---|---|---|
| Application service | `7AEF0001-6B8D-4B71-9C13-95DCE08A26F0` | Advertised and explicitly scanned. |
| Peripheral token | `7AEF0002-6B8D-4B71-9C13-95DCE08A26F0` | Read and notify properties; reads carry the current token and exchange nonce. No value is ever notified. |
| Central token | `7AEF0003-6B8D-4B71-9C13-95DCE08A26F0` | Write own current token with response, echoing the nonce. |

**FACT:** each frame contains a version byte, a phase byte, a 16-byte random token and a 16-byte random exchange nonce: 34 bytes, or 50 with the optional 16-byte prior nonce allowed only for second exchange evidence. The phases distinguish initial exchange, held connection checkpoint and second exchange evidence. The peripheral creates the nonce; it is bound to this exchange, not an account. The 64-byte bound is checked before decoding; unknown versions, malformed lengths, invalid phases and inappropriate prior nonces are rejected, and the engine checks nonce freshness and phase continuity. Read fragments refer to one immutable snapshot valid only until its token expires; write fragments are assembled within one callback and never carried into another. **DEFAULT:** these protocol values are the starting constants for later interoperability.

**FACT:** Unit 2 added the notify property to observe the subscription lifecycle, without sending notifications. After characteristic discovery the central subscribes before reporting readiness. The peripheral treats subscription as connected and unsubscription as disconnected: Core Bluetooth supplies it no other central connect/disconnect signal and no way to force a central off. Logical peripheral close releases local state only. Pull request 5 changed central teardown to unsubscribe before cancelling the link, waiting at most 1 second. An offset-0 read from a still-subscribed central with no open logical link admits a new logical connection, subject to the same admission bounds; continuation reads cannot create one.

**FACT:** after the 2026-10-11 security review, the adapter has an event-backlog admission limit of 256: at that limit observations are dropped and new subscriptions/read admissions are refused, while events for admitted work and command outcomes are always delivered. The backlog can therefore exceed 256 to finish admitted work. At most 16 peripheral-role logical links are open; each admits one outstanding read and write. Write callbacks accept at most 8 nonempty fragments. Observations emit at most once per peer every 2 seconds and use a 256-peer registry; central links and cancellations also share a 256-entry bound. **DEFAULT:** these resource limits may be tuned after trials.

No account ID, name, GitHub handle, email, link or permanent device identifier crosses Bluetooth. Tokens identify participants temporarily; nonces and phase bytes only coordinate the exchange. Session state and duration are reported by each phone to the server, not advertised.

**FACT:** `TokenProvider` selects a valid token from an ordered batch of non-overlapping, exactly 15-minute windows, prunes expired windows on selection and never extends validity. Development's local issuer uses cryptographically random tokens and 12-hour coverage; `KeychainTokenBatchStore` stores the batch after first unlock, this device only. Without a valid token the engine pauses participation. **DEFAULT:** Unit 3 will issue server batches with the same windows and coverage and replenish them online. The server keeps token digests and ownership, never relies on a client-supplied account mapping, and rejects tokens outside their windows. CryptoKit currently supplies the diagnostic nonce hash, not a separate batch-integrity check.

### Exchange, presence and teardown

**FACT:** the peripheral durably saves the central's write before answering success; the central saves after the write acknowledgement. An interrupted read, failed write or missing acknowledgement is not a completed exchange. The engine rechecks its own token at the central write acknowledgement and after either role's save; a token roll rejects completion and rolls back/removes the saved evidence, with a retriable presence step where possible. Upload remains planned: an eligible one-sided receipt can only be a candidate and never reveal a card alone.

**FACT:** both presence approaches are built. The code default is still the held connection (接続を維持). After at least 120 seconds on each phone's monotonic clock, a fresh read/write of current tokens under the same exchange nonce updates that phone's one receipt with a checkpoint token pair and observed duration. A timer alone never supplies two-minute evidence. Tokens at the first exchange and checkpoint may differ; both pairs are retained for validation against their own windows.

**FACT:** the second exchange (2回目の交換) closes the first central link and completes another exchange with the same provisional peer at least 120 seconds later. Unit 2 changed the planned receipt shape: it creates a second receipt with its own exchange nonce, `priorExchangeNonce` equal to the first exchange's nonce, and observed duration measured monotonically between the exchanges. The first receipt is kept and marked final; the second has no held connection checkpoint. Unit 3 resolution must accept both built shapes, resolve the token pairs to the same two accounts and require reciprocal receipts for both exchanges. A local handle alone is insufficient and unrelated short contacts are never combined.

**FACT:** owner decision, 2026-10-11; not yet implemented — make the second exchange the default, keeping the held connection selectable in S22 until iPhone-with-iPhone trials in the 160-trial matrix confirm the choice. Both approaches passed rungs 3 and 4 on the iPhone 15 and iPad (10th generation), but a held connection occupies one of the engine's four connection slots for two minutes per peer. The second exchange is the only approach with a possible route for locked phones. Accepted trade-off: it proves two completed exchanges at least 120 seconds apart, not continuous presence; leaving and returning within the 5-minute attempt still counts. Rung 3 remains the public promise; rungs 1 and 2 remain unproven and never promised. Neither approach assumes a suspended app receives a timer callback.

**FACT:** connect attempts have a 10-second timeout and read/write/save steps a 5-second timeout. A pre-exchange peripheral attempt also has a 20-second total bound. Presence expires 5 minutes after the first completed exchange. Evidence completion, terminal failure, expiry, stopping participation, radio/token loss and Reset close attempts; a refused checkpoint or second exchange step can retry inside the original bound. A broken held connection supplies no qualifying elapsed evidence. The engine admits one outgoing attempt per provisional peer and four active or closing connections total, including incoming links and pending connects, with a 10-second duplicate backoff. Sign-out integration and server deduplication of reciprocal connections remain planned. **DEFAULT:** these timeout and concurrency values may still change.

**FACT:** the engine bounds pending peers to 256, expiring them 30 seconds after their last observation, and observed peers to 256. Its consumed-nonce ledger holds at most 4,096 entries, expiring after 48 monotonic hours and evicting the oldest entry at capacity. The returning-central refusal table holds at most 256 handles. Currently a returning central is refused for 5 seconds after the end of an attempt without evidence; evidence completion does not set that refusal.

**FACT:** owner decision, 2026-10-11; not yet implemented — after two-minute evidence, start no new exchange with that peer for 15 minutes (one token window); Reset clears the pause. The current engine only has its 10-second backoff, so a pair repeats about every 131 seconds, storing receipts and using the radio without end. A longer pause cannot be enforced because the app keeps no lasting peer identifier.

**FACT:** owner decision, 2026-10-11; not yet implemented — count the 5-second refusal from the start of that central's previous attempt, rather than its end. This still limits an attacker to one attempt per 5 seconds per handle and accepts an honest returning peer immediately when its previous attempt lasted longer. The diff needs a security review. Implement all three decisions before the 160-trial matrix; the repeat traffic and current refusal distort its measurements.

A local session flag permits retaining short evidence for early upload; it cannot decide the encounter kind. **FACT:** the engine captures the initial flag and keeps collecting ambient evidence; the app supplies false until sessions exist. Upload and server status handling remain planned. If only one user is in a session, both phones still need two minutes. A new session does not retroactively turn an earlier short ambient contact into a session encounter.

**FACT:** ambient attempts ending without two-minute evidence are discarded; a session-flagged receipt is retained and marked final, as is the first receipt of a qualifying second exchange pair. An uploaded one-sided receipt remains a candidate until its counterpart arrives or the 48-hour deadline expires, even if it might qualify as a session. Once both receipts arrive, the server must discard final short evidence if it cannot establish two active sessions and has no qualifying ambient evidence. Do not discard an incomplete pair merely because the other phone is offline.

## Encounter states

| State | Meaning | Next step or failure |
|---|---|---|
| Observed | Core Bluetooth discovery callback, with a provisional local handle. | Connect; discard on timeout. No proof and no visible card. |
| Exchanged | Tokens swapped in both directions and a receipt persisted. | Collect required presence evidence and upload when online. |
| Candidate | At least one receipt uploaded; not yet confirmed. | Wait for its counterpart and validation. Drop after 48 hours unresolved. |
| Confirmed | Matching receipts and duration/session checks pass, or the QR rule passes. | Delete candidate times; retain dates and kind. Apply reveal timing. |
| Revealed | The reveal gate has passed for the viewer. | Return only currently authorized fields; remove access on deletion or safety actions. |

```mermaid
flowchart LR
    O[Observed] -->|two-way swap| E[Exchanged]
    E -->|durable upload| C[Candidate]
    C -->|matching receipts and required presence| F[Confirmed]
    C -->|invalid or 48-hour expiry| X[Dropped]
    F -->|ambient: daily report| R[Revealed]
    F -->|both in session: immediate| R
    Q[Signed-in QR issue and one-time redemption] --> F
    F -->|QR: immediate| R
```

Revealed is a timing state, not a permanent permission grant. A revealed encounter per viewer is a confirmed encounter that a user is now allowed to see. Each of the two users reaches this at their own daily report, so one may see the other before the reverse. This follows from the decision that each user can change their report time. **DEFAULT:** persist the reveal flag per viewer. A confirmed ambient encounter supplies no identifiable preview before that viewer's report. Session and QR encounters pass both viewers' timing gates immediately.

## Confirmed encounter, security definition

### Bluetooth

**FACT:** `EncounterReceipt` contains an immutable identity, protocol version, role, exchange nonce, optional `priorExchangeNonce`, start token pair and its transient wall observation time, optional checkpoint pair/time, monotonic observed duration, initial session flag, final-evidence marker and upload status. A held connection updates one receipt with the checkpoint; a second exchange creates a linked second receipt and retains the final first receipt. Unit 3 must accept both shapes. The authenticated uploader must own the token it claims as its own; authentication and resolution are not built yet.

Confirmation is one server transaction:

1. Authenticate both receipt submissions and resolve tokens to two distinct accounts.
2. Match reciprocal token pairs, version and nonce; for a held connection match both start and checkpoint pairs, and for a second exchange match both exchanges and their `priorExchangeNonce` reference with the same two account owners.
3. Check each token was valid at the claimed exchange/checkpoint time. Check freshness and reject a nonce already consumed by another resolution.
4. Require both phones' observed duration to reach 120 seconds for ambient encounters. For the second exchange, both matching endpoints must be at least 120 seconds apart.
5. Classify as session only when both receipt flags indicate a session and the server's own session records show both users active at the initial exchange. Otherwise apply the ambient threshold.
6. Create or deduplicate the date-only encounter, consume the nonce(s), and delete candidate receipts and their precise times. Set the applicable reveal flags.

**DEFAULT:** freshness means upload no later than 48 hours after the observation, with a candidate lifetime no longer than 48 hours after first upload. The earlier deadline wins. Repeated delivery of the same receipt is idempotent; it never creates another encounter. Retain only expiring nonce digests for replay rejection after resolution. Never allow an expired candidate to revive through a new upload. **FACT:** the device's 4,096-entry nonce ledger can evict older entries before 48 hours and is lost on process restart or Reset; Unit 3's server-side nonce consumption must be the replay control, not the device ledger.

**DEFAULT:** deduplicate repeated exchanges into one encounter per account pair, kind and pair of viewer dates; retain separate ambient and deliberate encounter kinds so an early deliberate encounter cannot reveal a later ambient one. A deduplicated exchange adds no new feed item or notification and never advances an existing reveal flag. Rate-limit uploads to 60 per minute and resolution attempts to 30 per minute per account as initial abuse controls; tune these application limits after tests. These are not provider API limits.

A confirmed Bluetooth encounter is evidence of a Bluetooth interaction, not cryptographic proof of physical distance. A relay can carry a valid exchange, and two malicious clients can falsify observations. Signal strength is only a rough range indicator, never the confirmation gate.

### Sessions and QR

The server owns session start, expiry and stop records. Sessions last two hours or until stopped. Late receipt uploads use that record, rather than trusting a current client flag alone. A stopped local session reports its flag as false even when the stop upload is pending.

For QR, the showing phone obtains a short-lived one-time code from the server while signed in. A distinct signed-in scanning account submits it before expiry. Atomic redemption confirms and reveals the encounter immediately for both accounts. No Bluetooth receipts or two-minute wait are involved.

**DEFAULT:** use a random 128-bit opaque QR code valid for 2 minutes, stored as a digest. Put no name or permanent account identifier in the QR payload. A new code invalidates the previous outstanding code of that user. Reject self-scans, expired codes, reuse and accounts that cannot participate. Apply per-account issuance and redemption rate limits. Code issue and redemption need network access; QR avoids radio dependence, not server validation.

## Background lifecycle and storage

**FACT:** the app declares `bluetooth-central` and `bluetooth-peripheral` background modes. `CoreBluetoothTransport` creates both managers on one serial queue with distinct iOS restoration identifiers, restores delegates, services and connections, and leaves restored discovery untouched until the engine supplies a command. `App.init` recreates the runtime when the persisted local participation switch is on; managers are not created while it is off.

**FACT:** only completed receipt payloads persist; partially assembled frames and monotonic attempts do not. A restored connection without a live connected engine attempt is disconnected logically and retried fresh; only a demonstrably live attempt is kept. On first start after process loss, nonfinal receipts with a session flag or qualifying ambient evidence are finalized, and other nonfinal receipts are removed. Unit 2 therefore does not resume a half-finished second exchange pair across process loss. Never infer continued presence from relaunch. **UNVERIFIED:** real-device restoration continuity still needs its own trial.

**FACT:** `SwiftDataReceiptQueue` is a single model actor storing each receipt as its Codable payload beside identity, enqueue sequence and expiry. It stores at most 4,096 receipts and 4,096 terminal-identity tombstones; a full receipt queue fails the write. Expired receipts are never returned. Enqueue removes expired rows, and the engine runs expiry on start, on refresh and every 15 minutes while running. Receipt expiry uses wall time; monotonic time drives presence. Terminal acknowledgement removes a receipt idempotently, retaining its identity/expiry within the tombstone bound. Checkpoint updates keep the original identity and initial evidence; the second exchange gets a new identity.

Upload is not implemented. **DEFAULT:** use exponential retry/status checks from 5 seconds to 15 minutes with jitter and connectivity/foreground triggers. Delete terminally acknowledged or rejected receipts and expire unresolved observations after 48 hours.

**FACT:** the receipt directory, store and existing sidecars use after-first-unlock file protection, reapplied around writes, and the directory is excluded from device backups. `KeychainTokenBatchStore` uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, with no iCloud synchronization. Auth credentials are not implemented. Check the complete locked SwiftData/sidecar and future credential paths on real devices; the one-day exchange results are not a separate protection audit. Before the first unlock after a reboot nothing works; do not claim otherwise.

**FACT:** token selection uses the stored batch whenever the engine runs or handles a Bluetooth request, caching only the current valid window and reloading on refresh/start. There is no advertised token to update while suspended. A callback across a window boundary selects the new token before answering; fragmented reads use an immutable snapshot until expiry, and the engine refuses/retries presence steps whose own token rolls before completion. No background timer is required for selection. **UNVERIFIED:** crossing a window boundary on real devices was not tested on 2026-10-11.

**FACT:** as recorded in `decisions.md`, **Encounters**, background advertising omits the local name and moves service UUIDs to an overflow area discoverable by an iOS scanner explicitly looking for them. Advertising can slow; scans coalesce duplicates and run less often. A background wake gives around 10 seconds, not a two-minute execution grant. **FACT:** the Apple engineer statement recorded there describes background advertising as best-effort and says force-quit apps are not relaunched.

**FACT:** device check, 2026-10-11, iPhone 15 and iPad (10th generation) — with one app open, the open device woke the locked peer and both approaches produced two-minute evidence in both orientations. With both locked, neither approach produced evidence until a device was woken: a suspended app gets no timer. Held-connection checkpoints then ran late; second exchange attempts beyond the 5-minute bound expired and needed a fresh pair. The first exchange happened immediately after Reset, before both devices were left locked, so discovery between two backgrounded devices was not tested.

**UNVERIFIED:** background-to-background iPhone discovery and rung 2 (Awake). Rungs 1 and 2 remain unproven and never promised. An undecided, unbuilt idea is to ask iOS for the second connection after a delay with `CBConnectPeripheralOptionStartDelayKey`, so the system might wake a locked phone; no result establishes that it will. Force-quitting stops discovery until reopening, and onboarding must say so. Do not use BGTaskScheduler for continuous scanning or deterministic wake-ups. No location permission or location storage exists in v1; a possible later boost waits for Bluetooth-only results.

## Data model

**DEFAULT:** all table names, key columns, enums and constraints below are proposed schema details. Product rules such as 48-hour candidate expiry and current visibility remain binding. Foreign keys cascade through user-owned data; account and mutual encounter deletion also remove cross-user references, except for the binding account-deletion safety record described below.

| Table | Key columns and purpose |
|---|---|
| `auth.users` | Managed Auth identity; release provider is Apple. GitHub is linked to this identity. |
| `profiles` | `user_id` PK/FK, `display_name`, `introduction`, `contact_detail`, `discovery_on`, `age_18_declared`, `terms_version`, `privacy_version`, `moderation_state`; defaults to discovery off. |
| `interests`, `user_interests` | Curated `interest_id`; join PK `(user_id, interest_id)`. |
| `user_purposes` | PK `(user_id, purpose)`; purpose is Discovery or Collaboration, with initial field visibility of everyone eligible once discovery is on. |
| `matching_preferences` | `user_id` PK, `minimum_shared_interests`. |
| `field_visibility` | PK `(owner_id, field)`, `level`; three levels only, including a selector for purposes. Initial levels: display name, introduction, interests and purposes are everyone eligible once discovery is on; contact detail is private. |
| `linked_identities` | PK `(user_id, provider)`, `provider_user_id`, `handle`, `verified_addresses`; unique provider identity, server-managed verification evidence. |
| `external_links` | `link_id` PK, `owner_id`, `source`, `source_item_id`, `url`, editable `title`, `description`, `main_language`, `tags`, `opening_text`, `visibility`, `verification_state`, `display_order`. |
| `sessions` | `session_id` PK, `user_id`, `starts_at`, `expires_at`, `stopped_at`; temporary server session ledger. |
| `temporary_tokens` | `token_digest` PK, `user_id`, `batch_id`, `valid_from`, `valid_until`, `delete_after`; no raw server token after issue. |
| `encounter_candidates` | PK `(exchange_nonce, uploader_id)`, reciprocal token digests, version, session flag, duration, final-evidence marker, checkpoint/reference evidence, observation times, `first_uploaded_at`, `expires_at`; unresolved only. |
| `consumed_nonces` | `nonce_digest` PK, `delete_after`; expiring replay tombstone, no account pair or encounter time. |
| `qr_codes` | `code_digest` PK, `issuer_id`, `expires_at`; remove on atomic redemption. |
| `encounters` | `encounter_id` PK, ordered `user_a`, `user_b`, `kind`, `day_a`, `day_b`; dates only, no creation or observation timestamp. |
| `encounter_views` | PK `(encounter_id, viewer_id)`, `revealed`, date-only `reveal_report_day`, `favorite`; per-viewer access and retention. |
| `saved_links` | PK `(viewer_id, encounter_id, link_id)`; references, never copied link metadata. |
| `blocks` | PK `(blocker_id, blocked_id)`; either direction prevents eligibility and removes the pair's encounters. |
| `reports` | `report_id` PK, `reporter_id`, `subject_id`, optional `link_id`, `reason`, `status`, `reporter_hidden`, review deadline; no copied encounter time. Account deletion erases the report; only operator moderation outcomes may enter the safety record. |
| `deletion_safety_records` | `apple_id_hash` PK, operator moderation outcomes, `delete_after`; no reference to the deleted Auth account. |
| `deletion_safety_blocks` | PK `(apple_id_hash, blocker_id)`; incoming blocks only, with a live blocker FK that cascades when the blocker deletes their own account. |
| `notification_preferences` | `user_id` PK, local report hour/minute, IANA `time_zone`, notification enabled. |
| `report_deliveries` | PK `(user_id, report_day)`, `status`; daily idempotency, no copied profile data. |
| `push_outbox` | PK `(user_id, report_day, installation_id)`, status and expiry; delivery references only, no names or copied cards. |
| `push_tokens` | PK `(installation_id, environment, topic)`, `user_id`, protected APNs device token, `last_registered_at`, `invalidated`; registration metadata, never an encounter timestamp. |

Account deletion is available inside the app and is immediate and permanent for all personal data, with one safety exception: the server keeps only a one-way hash of the Apple account identifier together with operator moderation outcomes and the blocks other people placed on that account, for a period the privacy policy states, and re-applies them if the same Apple identity signs up again. Nothing else survives. The hash cannot be turned back into the Apple identifier; the kept record holds no name, profile field, link, token, encounter or contact detail. A block is dropped when the person who placed it deletes their own account. The privacy policy and the S20 deletion confirmation disclose this exception. The exact retention period is an open item to settle with the legal review.

**DEFAULT:** implement the safety exception with `deletion_safety_records` and `deletion_safety_blocks`. Compute the one-way hash as a keyed hash on the server from the verified Apple identifier, using a server-only secret. Recompute it on Apple sign-up and re-apply unexpired operator moderation outcomes and incoming blocks before allowing participation. The retained hash cannot be reversed into the Apple identifier, and these tables hold no name, profile field, link, token, encounter or contact detail. Delete the record and its blocks when the policy period expires; remove an incoming block on unblock or deletion of the blocker's account.

**DEFAULT:** order account pairs consistently; reject self-pairs. Enforce unique receipt submissions, nonce consumption and QR redemption transactionally. Index candidate expiry, token expiry, encounter participant/day, blocks in both directions and report status. Enforce profile prerequisites when enabling discovery, enum validity and an explicit non-null visibility choice for every published link.

**DEFAULT:** derive each viewer's encounter date from the first exchange's candidate time in that viewer's recorded time zone; freeze those dates on confirmation. Register a valid zone during account setup before issuing encounter tokens or QR codes. QR uses the redemption date in each viewer's zone and immediately discards the transient clock value. Token windows, session timers and job deadlines are operational expiry data, not stored encounter times. Do not place raw observations in function logs, analytics, report jobs or confirmed records.

Direct app access to tables is denied by default. Server functions authenticate the caller, check its live account, and return only authorized fields. **DEFAULT:** expose bounded functions for own-profile edits, token batches, receipt upload, session start/stop, QR issue/redeem, feed/card reads, favorite/save, link preview/publish, block/report, push registration and account deletion. Lock down privileged SQL functions and keep service credentials only on the server.

## Matching and visibility

```text
eligible = confirmed AND viewer.discovery_on AND owner.discovery_on
           AND NOT viewer_blocks_owner AND NOT owner_blocks_viewer
compatible = eligible AND overlapping_purposes
             AND shared_interest_count >= viewer.threshold
             AND shared_interest_count >= owner.threshold
```

**DEFAULT:** each interest threshold starts at 1 and is adjustable. The threshold of each side must pass. Compute from current settings, in both directions, on every authorized read, including past encounters, favorites and saved links.

### Authorization truth table

`C` means confirmed; `Dv`/`Do` are discovery switches; `Bv`/`Bo` are blocks in each direction; `P` is purpose overlap; `Tv`/`To` mean each interest threshold passes. `*` means any value. The rows partition all combinations.

The field columns assume the encounter is already revealed and retained for this viewer and is not hidden by moderation. Otherwise return no other-person fields regardless of the table. Private fields are visible only to their own owner through the separate own-profile API.

| C | Dv | Do | Bv | Bo | P | Tv | To | Eligible | Compatible | Everyone eligible | Compatible only | Private |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | * | * | * | * | * | * | * | No | No | No | No | No |
| 1 | 0 | 0 | * | * | * | * | * | No | No | No | No | No |
| 1 | 0 | 1 | * | * | * | * | * | No | No | No | No | No |
| 1 | 1 | 0 | * | * | * | * | * | No | No | No | No | No |
| 1 | 1 | 1 | 1 | 0 | * | * | * | No | No | No | No | No |
| 1 | 1 | 1 | 0 | 1 | * | * | * | No | No | No | No | No |
| 1 | 1 | 1 | 1 | 1 | * | * | * | No | No | No | No | No |
| 1 | 1 | 1 | 0 | 0 | 0 | * | * | Yes | No | Yes | No | No |
| 1 | 1 | 1 | 0 | 0 | 1 | 0 | 0 | Yes | No | Yes | No | No |
| 1 | 1 | 1 | 0 | 0 | 1 | 0 | 1 | Yes | No | Yes | No | No |
| 1 | 1 | 1 | 0 | 0 | 1 | 1 | 0 | Yes | No | Yes | No | No |
| 1 | 1 | 1 | 0 | 0 | 1 | 1 | 1 | Yes | Yes | Yes | Yes | No |

Discovery is off by default. Enabling it requires a display name, a user-written self-introduction, at least one interest and at least one link of any kind. Enforce these prerequisites on the server. **DEFAULT:** the server rejects a change that would remove a discovery prerequisite (the name, the self-introduction, the last interest or the last link) while discovery is on, and the user must turn discovery off first.

Once discovery is on, display name, self-introduction, interests and purposes default to everyone eligible. Contact detail defaults to private. A link has no default level: publishing requires the owner's choice. A field or link the viewer cannot see is omitted from the response, not sent for SwiftUI to hide.

Incompatible eligible encounters remain in the feed, with whatever fields are authorized. **DEFAULT:** order compatible encounters first within each day, then by shared-interest count and a stable encounter ID; never by stored encounter time. **DEFAULT:** while an encounter is not eligible, for example because the other person turned discovery off, it is hidden from the feed and from favorites, and it returns if it becomes eligible again within its retention period. The non-identifying shell is used only when the encounter is eligible and every field is private. The feed groups by day and offers Start session, QR and a favorites filter.

Reporting hides the subject from that reporter immediately. Three distinct reporters hide the profile from everyone until operator review, within 72 hours. **DEFAULT:** count distinct unresolved reporters and keep the reporter's hide in place while the report record is retained, including after resolution. Moderation suppression is an additional read gate, not a change to the definition of compatibility.

## Link readers

### Selection, preview and verification

All four readers are server-side. Read only the owner's selected public work. Return a preview, let the owner edit every automatically filled field, require an explicit visibility choice, then publish. Keep the original URL and source-specific metadata, not full works. **DEFAULT:** refresh on demand repeats preview and owner confirmation; it does not silently overwrite shared text.

| Reader | Fixed source and selection | Filled fields |
|---|---|---|
| GitHub | Official API at `api.github.com`; select the connected user's own public repositories and README through the API. | Name, description, main language, first README lines. |
| Qiita | Official API v2 at `qiita.com`; save the username once and select its own articles. | Title, tags, opening lines. |
| Zenn | Official per-user RSS at `zenn.dev/USERNAME/feed`; save the username once and select its own articles. | Title, opening lines when available. |
| Other pages | One bounded HTTPS page fetch per preview or requested refresh. | Title and Open Graph preview description only. |

**FACT:** as recorded in `decisions.md`, **Stack, tools and workflow**, GitHub OAuth without a scope grants read-only public access and `GET /users/USERNAME/social_accounts` is public. **DEFAULT:** request no GitHub scope; never request private-repository access or forward OAuth credentials to page readers.

**FACT:** Qiita API v2 documents 1,000 requests/hour authenticated and 60/hour per IP unauthenticated, `GET /api/v2/users/USER_ID/items`, and a linked GitHub ID on user objects. **FACT:** Zenn documents the per-user RSS feed, about 20 items unless `all=1` is supplied. **DEFAULT:** paginate official API lists, use `all=1` when the owner requests older Zenn entries, and handle provider throttling without inventing new provider limits.

**UNVERIFIED:** whether Zenn's feed includes opening text. If absent, fetch only the article page's preview description on the fixed Zenn host. Apply the page-fetch safeguards below to that fallback; never scrape its body.

**DEFAULT:** Disconnect GitHub requires confirmation, makes links verified through that GitHub account unverified, and removes repository link cards read through it. The discovery-prerequisite rejection rule also applies if this would remove the last link.

GitHub links are verified through the connected identity. Other links are verified if under an address on that verified GitHub profile's website or social links; Qiita also qualifies when its linked GitHub ID matches. All others are labelled unverified and reportable as impersonation. **DEFAULT:** compare canonical URLs by exact host and path boundary, not substring or lookalike host; recompute verification after identity/address/link changes. An entered Qiita or Zenn username alone never proves control.

Store only title or name, description, main language, source, tags, and roughly the first 200 characters of opening or preview text. Nothing else from the source is stored. **DEFAULT:** cap both stored opening/preview text and description at 200 characters, strip markup to plain text and keep draft previews only in the owner's editing session. Preserve owner edits until they accept a refreshed preview. On reader failure, retain the existing approved card and original link. Explain before sharing that external URLs can identify the owner even when the in-app nickname does not.

### Fetching other pages

This reader accepts arbitrary URLs and must prevent server-side request forgery:

- Accept HTTPS only; reject embedded credentials and malformed hostnames.
- Resolve the host and refuse private, loopback, link-local and other non-public destinations, including IPv6 and IPv4-mapped IPv6. Reject mixed public/non-public answers.
- Re-check the URL, DNS answers and target address at every redirect. Do not forward authentication or cookies.
- Bound response size, time and redirect count. Accept only HTML; reject other media.
- Extract only the title and preview description. Never extract page bodies or follow page links.
- Treat all fetched material as untrusted text; do not execute scripts or render fetched HTML.

**DEFAULT:** allow port 443 only, at most 3 redirects, 1 MiB of received and decoded data and a 5-second total deadline. Abort while streaming when a bound is exceeded. Use a fetch implementation that connects to a validated address with the original host for TLS and refuses unsafe address changes. If the Edge runtime cannot enforce this, disable arbitrary-page fetching until a safe implementation exists.

DNS can change between validation and connection. Address pinning reduces this risk; the implementation must still test redirects, rebinding, IPv6, parser ambiguity and actual connected addresses. Do not treat a preliminary DNS check as sufficient. The GitHub, Qiita and Zenn readers call only fixed hosts and reject redirects to arbitrary hosts. Discard downloaded buffers after producing the bounded preview.

## Daily report delivery

Ambient encounters reveal at 21:00 local time by default. The user can choose another time and turn notifications off. Notification opt-out does not stop the in-app reveal. Skip days with no confirmed ambient encounters to reveal. Session and QR reveal immediately without waiting for this job.

**DEFAULT:** Cron runs every 5 minutes and calls a restricted report worker. The app registers a validated IANA time-zone identifier on sign-in, foregrounding and detected zone changes; the latest foreground registration wins across devices. The server uses that zone, not a fixed UTC offset. If no valid zone has been registered, defer the report and request it on the next app foreground rather than guess the user's local time.

**DEFAULT:** for a daylight-saving gap, deliver at the first valid local minute after the chosen time; for a repeated time, deliver once at its first occurrence. Key delivery by user and local calendar date. A backward zone change cannot deliver a second report for an already-completed date. A forward change recomputes the next due local date. The report is once per local date, not a guaranteed 24-hour interval while travelling.

**DEFAULT:** at confirmation, assign each ambient view the date of its next scheduled local report: today if before the chosen time, otherwise the next local day. Keep only this date, not the confirmation time. This prevents confirmation after the scheduled cutoff from being revealed by a late Cron run. When the user changes report time or zone, reassign waiting views to the next future local report; do not reveal immediately on the settings update.

**DEFAULT:** the worker locks each due user's delivery row, selects eligible confirmed ambient views whose `reveal_report_day` is due, sets their reveal flags and creates an idempotent push job in the same transaction. Include older unrevealed encounters whose receipts arrived late, at their assigned next report; keep their original encounter dates. Record an empty date as closed without showing a report or sending a push, so later arrivals cannot cause a second run for that date. Encounters confirmed after today's report wait for the next report.

The two users' reports may occur at different instants. Before each feed response and notification handoff, re-check current visibility, discovery, blocks, deletion and moderation. Notifications may include currently authorized names; the delay is the privacy protection. **DEFAULT:** push jobs hold user/day references, not frozen names or cards. An outage causes a delayed report on recovery. Repeated jobs must not reveal or enqueue twice, though exactly-once delivery by the external push service is not assumed.

### Push-token lifecycle

**DEFAULT:** register APNs tokens after permission and on each app registration callback. Associate them with the signed-in account, installation, topic and APNs environment; replace changes atomically. A sign-out removes that installation's association. Account deletion removes all associations and queued notifications. Invalid/unregistered responses delete the token; transient failures retry only for the current report day. Expire registrations after 90 days without re-registration and omit raw tokens from logs.

Keep APNs signing credentials on the server. Lack of permission, a missing token or a push failure never rolls back the reveal; the report remains in-app. **FACT:** free Apple accounts have no push notifications or TestFlight/App Store distribution, and their builds expire after about a week. The friends test therefore reads the report in-app. **UNVERIFIED:** free-account Sign in with Apple availability and the current device cap.

## Retention and deletion contract

The table separates each store and deletion trigger. **DEFAULT** periods are proposals, not settled policy. Encounter observation times exist only in unresolved evidence and are discarded on confirmation or dropping it; diagnostics are bounded on-device test data. Expiry checks run on reads as well as cleanup, so a delayed job cannot extend access.

| Data | Retention | Deletion and access contract |
|---|---|---|
| On-device diagnostics | **FACT:** Development/Internal trial log uses a 7-day cutoff from device-local calendar dates and prunes at load, write and refresh; at most 200 trials, 200 exchange and 200 evidence entries per trial, and the newest 50 attempt endings per trial. **DEFAULT:** the 7-day period and caps may change. | Release contains no diagnostics. Relaunch closes incomplete trials; Reset starts a new trial and retains earlier logs. No raw tokens or peer handles are stored, but shared exchange digests reveal that the two owners met. Sign-out/account-deletion clearing is planned; the log's clear method exists. |
| On-device receipts and unresolved presence | **FACT:** receipt deadline is 48 hours after its first observation; presence attempts end at 5 minutes and pre-exchange peripheral attempts at 20 seconds. Queue caps are 4,096 receipts and 4,096 tombstones. **DEFAULT:** these bounds may change. | Expired receipts are excluded on read and removed on enqueue, start, refresh and 15-minute running maintenance. Terminal acknowledgement removes evidence idempotently; candidate acceptance is nonterminal. Reset clears the queue and attempts. Short ambient evidence is discarded, except a final first receipt needed for a qualifying second exchange. Sign-out/account deletion and server terminal-status cleanup are not yet integrated; they must clear precise evidence without a local confirmed time. |
| Server candidates | At most 48 hours unresolved. **DEFAULT:** also enforce the earlier observation freshness deadline. | Delete on confirmation, rejection, expiry, block, encounter removal or either account's deletion. Delete all embedded observation times. |
| Token batches | **FACT:** device selection prunes expired windows best effort on the next execution, not with a suspended timer; expired tokens are never selected. Batches use device-only after-first-unlock Keychain storage. **DEFAULT:** server digests remain until 48 hours after window end. | The local participation switch stops radio use without deleting the batch; trial Reset clears receipts/attempts but retains valid test tokens. Token-store clear exists; sign-out/account-deletion integration remains planned. The engine nonce ledger expires after 48 monotonic hours and evicts the oldest beyond 4,096; Unit 3 must consume nonces server-side. |
| Session ledger and QR codes | **DEFAULT:** ended sessions up to 48 hours for delayed receipt validation; QR codes at most 2 minutes. | Remove sessions after validation horizon or account deletion; remove QR on use, replacement, expiry, discovery off or sign-out. Neither is an encounter-history log. |
| Confirmed encounters and view rows | 30 days unless that viewer retains a favorite. **DEFAULT:** expiry at the start of local encounter date + 30 days; cleanup hourly. | Expire the non-retaining viewer's access independently. Delete the shared record when neither viewer retains it. Explicit deletion or a block by either user removes it for both immediately, including retained references. |
| Favorites | Retained for the favoriting viewer while the encounter exists. | Current authorization always applies. Unfavorite after normal expiry removes that viewer's retained access. Mutual encounter removal, block or either account's deletion removes the favorite. |
| Saved link references | **DEFAULT:** same retention and current-visibility rules as favorites. | Saving retains access for that viewer, not a metadata snapshot. Unsave, owner link deletion or encounter removal removes the reference; the other person's unretained access still expires. |
| Moderation reports | **DEFAULT:** until resolved, then for the period stated in the privacy policy; exact resolved period remains open. | Account deletion erases reports and account identifiers; only operator moderation outcomes survive with the one-way hash under the safety exception. Resolution ends global suppression only through operator action. No permanent profile snapshot is retained. |
| Push tokens and queued pushes | **DEFAULT:** registration at most 90 days without renewal; retry only through its report day. | Delete on replacement, sign-out, invalidation or account deletion; cancel queued work after loss of authorization. |
| Approved profile/link metadata | While the account/link exists. | Owner removal or account deletion erases active data and invalidates references. Fetched page buffers are discarded after preview; other people's cards are not persisted locally. |
| Blocks and daily delivery keys | **DEFAULT:** active-account blocks until explicitly unblocked; delivery keys 30 days. | Account deletion removes outgoing blocks and delivery keys; incoming blocks survive only in the safety record. A retained block is dropped when its blocker deletes their own account or unblocks. Unblocking does not restore deleted encounters. Keys contain no names, tokens or observation times. |
| Account-deletion safety record | For a period stated in the privacy policy; exact period to settle with the legal review. | Keep only a one-way hash of the Apple account identifier, operator moderation outcomes and blocks placed by others; re-apply them on sign-up with the same Apple identity. The hash cannot be reversed; no name, profile field, link, token, encounter or contact detail survives. Drop a block when its blocker deletes their own account. Delete the record and blocks at expiry. The privacy policy and S20 deletion confirmation disclose the exception. |

**DEFAULT:** run candidate/token/session cleanup every 15 minutes and encounter/delivery-key/safety-record cleanup hourly. Apply expiry predicates in server functions independently of job timing. Clear local expired records at the next permitted execution if the app is suspended; no deterministic background deletion wake is assumed.

Explicit encounter deletion and block are transactional removals of the pair's candidates, confirmed encounters, favorites, saved references and pending delivery references. Discovery off immediately removes eligibility and stops local radio participation, but does not itself erase retained dates. Re-enabling discovery cannot undo an explicit deletion. **DEFAULT:** mark removed candidates' nonces consumed and retain unlinked nonce digests until freshness expiry to prevent a deleted encounter being recreated by the same receipts. Local receipt cleanup follows terminal status or the 48-hour limit when a phone is offline.

In-app account deletion is immediate and permanent for all personal data, with only the safety exception above. Nothing else survives. **DEFAULT:** mark the account inaccessible at the start, compute the safety hash from the verified Apple identity and transfer only operator moderation outcomes and incoming blocks to the safety tables, revoke auth/provider access, erase all other personal data and cross-user references (including outgoing blocks and incoming safety blocks the deleting account placed on others), hard-delete the Auth account, and acknowledge success only when these steps complete. Old credentials cannot read a deleted account. Purge local storage and Keychain. A failed step leaves access denied and reports an actionable deletion error; there is no grace period or user-restoration path.

Managed-service backup and log handling must be verified before public release; do not promise an unverified provider purge period. This does not permit retained active-account data or restoration of a deleted account. Removing access cannot retract an external URL already copied, the original work or a notification already delivered.

## Security requirements

- Authenticate every account-scoped request and require a live account. Release requires Apple sign-in; link GitHub only to that account.
- Deny direct table access by default. Re-evaluate current field/link authorization and safety gates in server functions; never return forbidden fields.
- Reject one-sided, mismatched, invalid-window, stale, self-paired and replayed Bluetooth evidence. Use atomic resolution and QR redemption.
- Enforce the ambient threshold and authoritative two-session exception. Rate-limit receipt upload, resolution, QR and link-fetch work per account.
- Keep temporary tokens, auth credentials and APNs/provider secrets out of advertisements, public tables, diagnostics and task logs. Use protected on-device stores and server secret storage.
- Request no location permission and store no location. Do not retain exact encounter times after candidate resolution, including in operational logging.
- Apply fetch protections, plain-text output and bounded parsing to untrusted titles, descriptions, RSS and README excerpts.
- Hide a report subject immediately from the reporter; suppress at three distinct reporters and provide the owner's review queue and published contact. Include block and deletion controls in v1.
- Make deletion remove favorites, saved links and notification work for both people where required. Retain only the one-way hash of the Apple account identifier, operator moderation outcomes and incoming blocks for the privacy-policy period; re-apply them on sign-up with the same Apple identity. The hash cannot be reversed, and the record holds no name, profile field, link, token, encounter or contact detail. Drop a retained block when its blocker deletes their own account. Disclose this exception in the privacy policy and S20 deletion confirmation; settle the exact period with the legal review. Re-check authorization at use, including after settings change.
- Compile development features out of Release and isolate non-production server paths. Build flags are not server authorization credentials.
- **FACT:** the 2026-10-11 static security review of Unit 2 fixed unbounded adapter events, missing receipt-expiry invocation, unbounded engine ledgers and trial logs, missing own-token rechecks at completion, and unbounded write fragments. The adapter, engine, store and diagnostics now enforce the resource bounds recorded above; admitted work always gets its result events.
- Accepted for now: device-ledger eviction makes server nonce consumption essential; short session candidates need a smaller receipt budget once sessions exist; wall-clock changes affect receipt expiry; failed token-roll cleanup can leave rejected evidence until expiry; and shared Development/Internal trial logs reveal a meeting through the exchange digest. These remain open risks. The decided but unimplemented change to count the 5-second refusal from attempt start needs a security review of its diff.

**DEFAULT:** report reasons are spam, harassment or inappropriate content, impersonation, and other. **DEFAULT:** profile limits are 30 display-name characters, 200 introduction characters and 10 links, with curated interests and an initial-letter avatar; enforce them server-side as well as in the app.

## Test plan

### Automatic checks

Use the terminal entry points in **Stack, tools and workflow** for every implementation unit. **FACT:** Unit 2 has domain core/runtime and paired-fake tests, adapter-state tests on the Mac, SwiftData/Keychain contract and failure tests, and app-hosted participation, local-issuer, runtime, diagnostics and build-kind tests. They cover both receipt shapes, 119/120-second thresholds on independent clocks, late wakes, token rolls including acknowledgement/save completion, timeouts, partial/malformed writes, one-sided results, restoration/process loss, expiry maintenance and resource limits. `check-release-artifact.sh` checks the actual three build artifacts. Backend/database areas still have smoke checks; resolution, accounts and product flows below remain required tests, not implemented coverage. **DEFAULT:** cover the full cases through portable packages, simulator integration, `deno test` and database tests:

| Area | Required cases |
|---|---|
| Fake Bluetooth and clock | Built: 119 rejected, 120 accepted; both approaches and receipt shapes; late checkpoint; unrelated short passes not joined; one-session case cannot bypass ambient evidence; token rolls; malformed/unknown-version frames; timeout, partial write, disconnect, restoration and resource bounds. Follow-up tests must cover the three owner decisions before the matrix. |
| Queue | Built: durable enqueue before response, identity/update/tombstone contract, reopen, expiry filtering/maintenance, caps and storage failures, with replaceable in-memory implementation. Delayed/offline upload and server rejection cleanup remain planned; device protection still needs device checks. |
| Resolution | Both authenticated reporters required; swapped token ownership; expired/stale tokens; duplicate nonce and replay after deletion; receipt updates; same owners across the second exchange; server sessions stopped/expired or flags forged; transaction races. |
| QR | Signed-in issuer and scanner, self-scan, expiry, second issuance, reuse, concurrent redemption and network failure. |
| Authorization | Every truth-table combination in both directions; reveal gate; changed settings on past/favorite/saved records; missing fields truly absent; direct table reads denied; incompatible feed row retained. |
| Safety/deletion | One and three distinct reports, repeat reporter, block in either direction, mutual deletion, one-sided favorite retention, saved-link deletion and hard account deletion with old credentials; only the hashed Apple safety record survives, same-Apple sign-up re-applies outcomes/blocks, different identities do not inherit them, expiry removes the record, and blocker deletion removes retained blocks. Verify policy/S20 disclosure and absence of profile, link, token, encounter and contact data in the safety record. |
| Readers | Own public selection, unverified usernames, owner edits and refresh approval, provider errors, no body retention, URL boundary verification, redirects, rebinding, IPv6, oversize, timeout and non-HTML rejection. |
| Daily report | 21:00/custom time, empty day, opt-out, DST gap/repeat, zone travel, two viewers' different report times, late receipt, Cron replay/outage, visibility change before push and invalid/rotated push token. |
| Build kinds | All three configurations; anonymous code only in development; anonymous/demo/diagnostics absent from Release artifact; event TestFlight artifact uses the release configuration and production backend with Apple sign-in and normal daily reveal/push timing; internal builds with demo/diagnostics go only to the owner's own devices; production rejects demo requests; Japanese/English resources and sample encounter. |

The fake validates logic, not radio reachability. **DEFAULT:** retain aggregated test outcomes without participant identifiers; keep detailed on-device traces under the diagnostics contract.

### One-day radio check

**FACT:** the owner ran the one-day check on 2026-10-11 with an iPhone 15 and an iPad (10th generation), Development builds, locally issued test tokens, no backend and no account. S22 is reachable from S01 before sign-in only in Development; Internal has no route yet and Release excludes it. The local participation switch starts the radio. There is no on-device confirmation harness: a trial counts when both devices show two-minute evidence for the same exchange digest, compared by the owner. The demo setting does not produce confirmed encounters or notifications yet.

Values below are seconds from trial start (Reset), with iPhone first and iPad second. They are evidence elapsed times unless stated otherwise; they are not encounter times retained by the product.

| Approach and conditions | 2026-10-11 results on iPhone 15 / iPad (10th generation) | Interpretation |
|---|---|---|
| First round, before teardown fix | Both reached evidence at about 123–132 s; afterward central attempts failed about every 10 s. | The physical link survived app-level cancel, so the peer saw no new subscription. Pull request 5 fixed unsubscribe-before-cancel and read admission for a still-subscribed central. |
| Held connection, both open, after fix | 124.4 / 127.5 s; 129.0 / 132.2 s. | Both devices reached two-minute evidence. |
| Held connection, iPad open, iPhone locked | 122.6 / 123.8 s; 121.4 / 122.7 s. | Both devices reached two-minute evidence. |
| Held connection, iPhone open, iPad locked | 256.8 / 261.2 s; 261.3 / 265.9 s. | Continuations of both-open trials without Reset; not clean reset-then-lock trials. |
| Held connection, both locked | First exchanges about 2.3 s; checkpoint only after waking a device, about 255 s, observed duration 252.7 s. Repeat gave the same result. | No two-minute evidence while both remained locked; suspended timers did not run. |
| Second exchange, both open | 124.4 / 124.4 s. | Both devices reached two-minute evidence. |
| Second exchange, iPad open, iPhone locked | 125.2 / 136.8 s; 123.6 / 135.3 s; locked iPhone reconnected on its own at 125 s. | The open device woke the locked peer. |
| Second exchange, iPhone open, iPad locked | 126.1 / 133.0 s; 127.4 / 134.4 s. | Both devices reached two-minute evidence. |
| Second exchange, both open, about 2 m apart for 10 minutes | Evidence about 123.5, 256.3, 389.9 and 522.9 s; no failed or disconnected attempt. | Repeated evidence about every 131 seconds exposed unnecessary receipt/radio work. |
| Second exchange, both locked | First exchanges about 1–2 s; no second exchange while locked. Woke a device after about 310 s; attempts ended expired at the 5-minute bound without evidence. Fresh exchanges after waking gave evidence about 445 s. | No two-minute evidence while locked; waking after expiry required a fresh pair. |

**FACT:** conclusions, 2026-10-11 — rungs 3 and 4 worked with both approaches on this iPhone 15/iPad (10th generation) pair in both orientations, with the held connection continuation caveat above. With one app open, the open device woke the locked one. With both locked neither approach produced evidence until waking, because a suspended app gets no timer. The owner also observed a connection at more than 10 m, without a log; it is not a range guarantee. These observations do not replace the 160-trial/battery gate or establish iPhone-with-iPhone behaviour. Rung 3 remains the public promise; rungs 1 and 2 remain unproven and never promised.

**UNVERIFIED:** background-to-background discovery was not tested: the both-locked trials exchanged immediately after Reset, before leaving both devices locked. Rung 2 was not tried. The owner ended the check on 2026-10-11 without a trial across a 15-minute token-window boundary, a real loss of contact and return, or iPhone with iPhone. These trials remain open, along with separate restoration, first-unlock and protected-storage checks.

**FACT:** observations, 2026-10-11 — after Reset one direction often had one failed central attempt at about 1–2 s and completed its first exchange about 10 s later, caused by the current 5-second returning-central rule. In second exchange trials S22 kept the first exchange of each pair pending indefinitely while the trial stayed open, because evidence is recorded under the second exchange's digest. Showing which first exchange an evidence entry completes remains undecided and unbuilt.

### 160-trial matrix and procedure

Borrow a second recent iPhone before the matrix. The iPad is an experimental peer; its result cannot establish iPhone-with-iPhone behaviour. No iPad-specific interface is designed.

**FACT:** owner decisions, 2026-10-11; all not yet implemented — before measuring, make the second exchange the default (both approaches passed rungs 3/4, held connections occupy a slot, and only the second exchange has a possible locked-phone route); add the 15-minute peer pause after evidence, cleared by Reset (stop endless receipt/radio work without a lasting identifier); and count the 5-second returning-central refusal from the previous attempt's start (retain per-handle abuse control while accepting honest long attempts), with security review of that diff. The last two currently distort measurements. Use the second exchange for the matrix and keep the held connection selectable in S22 until the iPhone-with-iPhone trials confirm the choice. Its leave-and-return trade-off remains accepted; delayed system reconnect is still undecided and UNVERIFIED.

| Rung | Stationary conditions | iPhone with iPad | iPhone with iPhone |
|---|---|---|---|
| 1 — Locked | Both locked, app backgrounded. | 20 trials | 20 trials |
| 2 — Awake | At least one awake in another app; neither app in front. | 20 trials | 20 trials |
| 3 — One open | Exactly one app open; the peer locked (**DEFAULT** trial condition). | 20 trials | 20 trials |
| 4 — Both open | Both apps open. | 20 trials | 20 trials |

Total: 4 rungs × 2 pairs × 20 = 160 stationary trials. **DEFAULT:** rung-3 trials run with the peer phone locked, the hardest case of “at least one of the two has the app open”. **DEFAULT:** split asymmetric rungs equally between device orientations and alternate them in the written test sheet.

1. After implementing and checking the three decisions above, select the second exchange in S22, then record device models, iOS version, build version, discovery settings, permissions, battery level and presence approach. Run detached from the debugger; the held connection remains selectable for comparison.
2. Use S22's trial reset action on both devices to reset trial state; reset the test accounts' candidates/encounters when a backend is in use, cancel all connections and clear pending attempts. Verify S22's visible reset confirmation before starting the next trial. Use fresh attempt nonces.
3. Set the required device states, bring the pair into range and start the stationary trial. **DEFAULT:** end at 5 minutes, with no state changes during the trial.
4. In S22, record each phone's per-trial elapsed values from trial start for discovery, two-way exchange completion, two-minute evidence and server confirmation separately. **FACT:** S22 lists recorded trials with missing/pending values, and server confirmation is currently unavailable. Compare both screens' evidence for the same exchange digest; there is no on-device two-receipt confirmation. Development can share the local log as a file; Internal has the support but awaits its Settings route. Sharing is absent from Release and reveals a meeting if both logs share a digest. Record missing, one-sided and duplicate results as such, not as success.
5. Once backend confirmation/reveal exists, use the demo switch for observable confirmation timing while enforcing the two-minute and both-receipts rules. Measure normal daily reveal separately. The current demo setting has no reveal consumer.
6. End, tear down and reset. Outside the stationary matrix, record 10-second and 30-second passes for information only; neither can satisfy ambient presence.

A rung-3 trial passes when both phones hold the two-minute presence evidence for the same exchange within 5 minutes of the start of the trial. Server confirmation time is recorded separately and is not part of the pass mark, because uploads may be deferred. At least 90 percent of rung-3 trials must pass. **DEFAULT:** apply the gate separately to each pair's 20 rung-3 trials, at least 18 successes per pair. Rungs 1 and 2 have no pass mark and only determine their public description. Record rung 4 latency separately. Twenty trials cannot distinguish 90 percent from 80 percent with confidence; the result is a go/no-go signal, not a measured reliability rate. If rung 3 fails, stop and rethink because only QR would remain.

Measure discovery-on versus discovery-off battery use over 8 hours: at most 5 additional percentage points. **DEFAULT:** use the same device, comparable usage and starting conditions on separate runs, recording the comparison rather than inferring it from one battery reading.

Test first unlock after reboot separately: nothing before first unlock, locked operation after first unlock. Also test force-quit and reopen, Bluetooth off/denied, background for an extended period, network loss/recovery, token-batch exhaustion and real QR. These are additional checks, not extra stationary trials counted toward 160.

### Friends, event and release

**DEFAULT:** v1 collects no usage analytics. Product measures are gathered by asking participants at the friends test and at the event, and technical measures come from the diagnostics of development and internal builds.

- Friends: 3–5 people in a small room or cafe; free Apple account, cable installs from the owner's Mac, temporary anonymous sign-in, sessions for immediate results and daily report inside the app without notification. **DEFAULT:** the friends test uses development builds pointed at a hosted non-production Supabase project, because the phones leave the owner's Mac. Anonymous sign-in is enabled only on that non-production project and disabled on production, in addition to being compiled out of the release build. Local Supabase is for automated checks and the owner's own development. GitHub alone is enough. **FACT:** builds expire after about a week. **UNVERIFIED:** the current free-account device cap; if reached, sign a friend's phone with that friend's own free Apple ID.
- After friends: join the Apple Developer Program; add and verify Sign in with Apple, APNs and TestFlight. Test release sign-in and production timing, not just anonymous development flows.
- Event: one real event with 20 or more people using a TestFlight build made with the release configuration against the production backend. No demo switch, diagnostics or anonymous sign-in; attendees sign in with Apple. Verify these build gates before distribution. Internal builds retain demo/diagnostics and go only to the owner's own devices. Check radio results, useful discoveries, duplicate encounters, favorites/saves, authorization changes, blocking/reporting and normal daily delivery through participant feedback and observed app behavior; this event build supplies no diagnostic logs.
- Public release: all four link readers, one professional review of Japanese/English privacy policy and terms, App Store privacy labels, Bluetooth purpose string, in-app deletion, moderation contact, sample encounter and review notes, and Supabase hosting-region/data-flow documentation.
- Japan first. Complete J-PlatPat and USPTO name searches. Later storefront waves require the EU/UK privacy-law check and trader decision; exclude China mainland until the government-filing question is answered.

## Build order

Each unit produces a reviewable change and terminal checks. The owner merges each unit's commit. Units cannot bypass the staged gates in `decisions.md`, **Build, test and release path**.

| Unit | Work and completion gate |
|---|---|
| 1 — Toolchain | **FACT:** complete, merged in pull request 2. Package/app/backend/database smoke entry points established; XcodeGen and Deno installed. Sandbox Swift tests pass with redirected caches and `--disable-sandbox`; iOS-only code builds/type-checks there. Xcode and Supabase checks run in the tester role outside the sandbox. |
| 2 — Bluetooth engine | **FACT:** complete, merged in pull requests 4 and 5. Real app, primitive transport, engine/core, both receipt shapes, test-support product, token provider, durable queue, restoration and build-gated diagnostics built. The 2026-10-11 iPhone 15/iPad (10th generation) gate showed rung-3/4 evidence without backend; teardown fixed in pull request 5. Both-locked evidence waited for wake; omitted trials remain open. |
| Before the 160-trial matrix — presence follow-up | **FACT:** decided 2026-10-11, not yet implemented. Make the second exchange default and keep the held connection selectable until iPhone-with-iPhone matrix trials confirm it: both passed rungs 3/4, holding occupies a slot, and only the second exchange has a possible locked-phone route. Add a 15-minute peer pause after evidence, cleared by Reset, to stop endless receipt/radio work; no lasting identifier permits a longer pause. Count the 5-second refusal from the previous attempt's start to keep per-handle abuse control while admitting honest long attempts; security-review that diff. The current repeat traffic and refusal distort matrix measurements. |
| 3 — Accounts and schema | Development anonymous sign-in, profile prerequisites, interests/purposes, current visibility, server tokens, reciprocal resolution accepting held connection checkpoint and linked second exchange receipt shapes, server nonce consumption and date-only model; no release anonymous path. |
| 4 — Basic encounters | Feed/detail, sessions with Live Activity/control, QR, favorites/saved links, daily in-app reveal, block/report/deletion and sample encounter. |
| 5 — GitHub | Linked verification, own public selection, editable preview and explicit link visibility. Complete basic-function checks and the 160-trial/battery gate. Stop if rung 3 fails. |
| 6 — Friends | Owner cable-installs development builds for 3–5 friends against hosted non-production Supabase (**DEFAULT**), with anonymous sign-in only on that project, sessions and in-app report. Local Supabase remains for automated checks and the owner's own development. Resolve findings before progressing. |
| 7 — Paid developer account integration | Owner joins the Developer Program; verify Apple sign-in, APNs, all three build kinds and TestFlight. |
| 8 — Qiita and Zenn | Official readers, verification and safe Zenn fallback; resolve or preserve the feed-content unknown. |
| 9 — Other pages | Bounded SSRF-safe reader, redirect/rebinding tests and failure behaviour. All readers complete before public release. |
| 10 — Event | Owner runs the 20+ person event with a TestFlight build made with the release configuration against the production backend, with Apple sign-in and no anonymous sign-in, demo switch or diagnostics; internal builds go only to the owner's own devices. Verify normal daily push, authorization and moderation operations. |
| 11 — Japan release | Owner obtains bilingual legal review, resolves release-blocking policy/retention/hosting/name items and completes store deliverables and submission. |
| 12 — Later storefronts | Expand in waves only after the regional checks and decisions; Android remains later. |

**DEFAULT:** these unit boundaries, names and package-level work allocation are starting divisions. Split a large unit into bounded commits without moving its gate. Backend, radio and authorization checks travel with the relevant implementation unit.

## Decision log

1. Retain native SwiftUI/Core Bluetooth iOS first and postpone Android.
   Reason: support the chosen radio path while keeping one-owner scope manageable.
2. Retain external-link hosting rather than copies of portfolios or articles.
   Reason: discovery needs a bounded preview and access to the original work.
3. Retain per-field and per-link server authorization, with direct app table access denied.
   Reason: private data must never depend on client-side hiding.
4. Replace v0.2 AI/Gemini processing, summaries, consent and settings with four link readers.
   Reason: source metadata with owner editing provides the required link previews.
5. Retain modern-device testing and fix minimum iOS 26.0, Xcode 27.0 and Swift 6.4.
   Reason: legacy compatibility is outside project scope.
6. Replace the v0.2 unresolved token investigation with a versioned connected two-way exchange.
   Reason: advertisements must carry no tokens and both phones must take part.
7. Replace the v0.2 state list with Observed, Exchanged, Candidate, Confirmed and Revealed.
   Reason: distinguish radio work, server evidence and disclosure timing.
8. Replace general background expectations with a rung-3 promise and measured rungs 1 and 2.
   Reason: locked/background discovery remains unverified.
9. Replace undifferentiated proximity with two-minute ambient presence and the two-session exception.
   Reason: passing strangers must not expose cards in real time.
10. Replace v0.2 notification choices with daily ambient reveal and immediate session/QR reveal; remove the weekly digest.
    Reason: intentional exchanges and delayed ambient disclosure serve different privacy needs.
11. Remove connection requests and the v0.2 mutual connections visibility level; retain three levels.
    Reason: viewing technical work requires no social connection workflow.
12. Replace the v0.2 matching eligibility rule with separate eligibility and compatibility.
    Reason: matching orders encounters and gates fields without hiding incompatible encounters.
13. Replace open-ended history with date-only records, 48-hour candidates and 30-day viewer retention.
    Reason: minimize movement inference while allowing favorites under current permissions.
14. Add Apple release sign-in, linked GitHub verification and immediate account deletion.
    Reason: durable identities make safety and ownership rules hold.
15. Replace the v0.2 broad milestones with terminal-checked units and toolchain, radio, friends, event and release gates.
    Reason: prove the risky dependencies before public operation.
16. Select SwiftData behind a replaceable receipt queue and generate the project with XcodeGen.
    Reason: isolate background-storage risk and keep project changes reviewable as text.
17. Adopt the public names, 18+ launch and Japan-first staged rollout.
    Reason: make the public product and its release obligations explicit.
18. Record Units 1 and 2 as built and merged in pull requests 2, 4 and 5, on 2026-10-11.
    Reason: distinguish sandbox-compatible Swift checks from external Xcode/Supabase checks, and record the primitive transport, real protocol engine, separate test-support product, two receipt shapes, protected bounded stores and build-kind gates as implementation facts. Unit 2 changed the planned completed-exchange transport interface and second exchange receipt layout.
19. Record the one-day iPhone 15/iPad (10th generation) results and subscription teardown fix on 2026-10-11.
    Reason: rungs 3/4 worked with both approaches on that pair; both-locked timers waited for wake. Pull request 5 fixed unsubscribe-before-cancel and still-subscribed read admission. Background discovery, rung 2 and the not-run trials remain unverified; the public ladder promise is unchanged.
20. Record the 2026-10-11 static security review's fixes and accepted open risks.
    Reason: resource bounds, receipt maintenance and completion token checks are built; device nonce eviction, short-session queue pressure, wall-clock expiry, failed token-roll cleanup and shared-digest meeting disclosure still need follow-up. Server nonce consumption in Unit 3 is the replay control.
21. Make the second exchange the default and retain the held connection in S22 until the iPhone-with-iPhone matrix trials confirm the choice — owner decision of 2026-10-11, not yet implemented; code still defaults to the held connection.
    Reason: both passed rungs 3/4, holding occupies one of four slots for two minutes per peer, and only the second exchange has a possible route for locked phones. Accept that two completed exchanges at least 120 seconds apart prove no continuous presence and count a leave-and-return within the 5-minute attempt.
22. Pause new exchanges with a peer for 15 minutes after two-minute evidence, cleared by Reset — owner decision of 2026-10-11, not yet implemented; only the 10-second backoff exists.
    Reason: a pair repeats about every 131 seconds and spends storage/radio work indefinitely; a longer pause needs a lasting peer identifier that the app does not keep. Implement before the matrix to avoid distorting measurements.
23. Count the returning-central 5-second refusal from the start of its previous attempt — owner decision of 2026-10-11, not yet implemented; it currently counts from the end.
    Reason: retain one attempt per 5 seconds per handle for an attacker and accept an honest peer immediately after an attempt that lasted longer. Security-review the diff and implement before the matrix to remove the observed Reset/retry distortion.

## Defaults chosen during drafting

Rows collect **DEFAULT** choices used above, alongside **FACT** notes where Unit 2 built or changed them. Revisit tunable technical values after the matrix; retain product gates. The explicitly marked owner decisions of 2026-10-11 are binding and not yet implemented, rather than drafting defaults.

| Area | Drafting default |
|---|---|
| Profile | 30-character display name, 200-character introduction, curated interests, initial-letter avatar, at most 10 links. |
| Matching | Threshold starts at 1 per user; compatible-first/shared-interest/stable-ID ordering within each day; ineligible encounters hidden from feed/favorites until eligible again within retention; shell only for eligible all-private encounters. |
| Discovery prerequisites | Server rejects removing name, self-introduction, last interest or last link while discovery is on; turn discovery off first. |
| Reports/sample | Four report reasons; count distinct unresolved reporters; reporter hide while report retained, including after resolution; dismissible on-device sample. |
| Saved links | References with favorite-equivalent per-viewer retention and current permissions; no copied metadata. |
| Project/build layout | **FACT:** three XcodeGen configurations and anchored source/string-table exclusions; Development-only issuer/entry and Development/Internal diagnostics; actual artifact check; separate `EncounterDomainTestSupport`, never linked by the app. Internal awaits its Settings route to S22. **DEFAULT:** planned SessionActivity/site paths; local Supabase for checks/owner development, hosted non-production for friends/internal, anonymous sign-in only there and absent from production/Release, no production demo route. Authentication/reveal remain unbuilt. |
| Terminal entry points | **FACT:** package tests include Mac EncounterBluetooth; sandbox Swift requires redirected caches and `--disable-sandbox`. `typecheck-app.sh` checks each app configuration, hosted tests in Development only. Tester runs Xcode/Supabase and artifact/hosted checks outside the sandbox; unsigned simulator skips real Keychain round-trip and cannot verify device file protection. **DEFAULT:** local preparation, all configurations per unit and iPhone 17 destination. |
| App composition | **FACT:** primitive `BluetoothTransport`, synchronous core/actor runtime and test-only paired fake; durable queue/adapters and nonterminal candidates; AppComposition/EncounterRuntime, persisted local participation switch default off, managers only after participation/storage readiness, runtime recreated from App.init; session flag false. **DEFAULT:** Control Center control, online session start and queued local stop remain planned. |
| Card caching | Other people's cards in memory only, refreshed on open/foreground and cleared without fresh authorization. |
| Transport constants | **FACT:** listed UUIDs, read/notify peripheral characteristic without notified values, subscribe/unsubscribe lifecycle, unsubscribe-before-cancel with 1-second wait and offset-0 read admission; v1 34/50-byte framing, 16-byte token/nonce, optional prior nonce, 64-byte bound and immutable read snapshots. **DEFAULT:** tunable starting constants. |
| Tokens | **FACT:** exact non-overlapping 15-minute windows, protected device batch, pause without validity and no extension; Development-only local issuer with 12-hour quarter-hour-aligned coverage, no Internal/Release issuer. **DEFAULT:** Unit 3 server batches/replenishment/digests, same coverage and windows. |
| Presence | **FACT:** held connection updates one checkpoint receipt; second exchange creates a linked second receipt and keeps the final first receipt. At least 120 monotonic seconds on both phones remains binding. **FACT:** owner decision 2026-10-11, not yet implemented — second exchange default; held connection selectable until iPhone-with-iPhone matrix confirmation. Both passed rungs 3/4, holding occupies a slot for two minutes, and only the second exchange has a possible locked-phone route. Accept leave-and-return within the 5-minute attempt. Code still defaults to held connection. |
| Connection management | **FACT:** persist before write response; own-token rechecks at acknowledgement/after save; 10-second connect, 5-second operation/save, 20-second pre-exchange peripheral bound, 5-minute presence attempt, four active/closing slots, one outgoing per peer, 10-second backoff. **DEFAULT:** tunable timeouts/bounds. |
| Peer pause after evidence | **FACT:** owner decision 2026-10-11, not yet implemented — no new exchange with that peer for 15 minutes; Reset clears it. Current 10-second backoff permits repeats about every 131 seconds, wasting receipts/radio work; no lasting identifier permits a longer pause. Implement before the matrix. |
| Returning-central refusal | **FACT:** currently 5 seconds from the end of an attempt without evidence. **FACT:** owner decision 2026-10-11, not yet implemented — count from its start, retaining one attempt per 5 seconds per handle while admitting honest longer attempts at once. Security-review the diff and implement before the matrix. |
| Resource bounds | **FACT:** adapter admission backlog 256 with admitted work delivered, 16 peripheral links, 8 nonempty write fragments, 2-second peer observation throttle, 256-peer registry/central tracking; engine pending/observed/refusal tables 256, pending lifetime 30 seconds, consumed nonces 4,096/48 hours; queue receipts/tombstones 4,096 each. **DEFAULT:** tunable limits; server replay control remains required. |
| Receipt validation | **FACT:** version/role/start/checkpoint/reference/time/final fields and two built shapes, 48-hour device observation expiry, immutable initial evidence/idempotent identity writes. **DEFAULT:** Unit 3 validation, earlier observation/first-upload expiry and expiring consumed-nonce digests; server consumption is replay control despite bounded device eviction. |
| Deduplication/abuse | One account-pair/kind/viewer-date-pair encounter; no extra item/push or earlier reveal on deduplication; separate deliberate and ambient kinds; 60 uploads and 30 resolution attempts per minute/account; per-account QR/fetch controls. |
| QR/session ledger | 128-bit QR codes, 2-minute expiry, one outstanding code; ended sessions retained at most 48 hours for receipt validation. |
| Restoration/upload | **FACT:** distinct manager restoration IDs, delegates/services/connections restored, completed payloads only, disconnect unknown live attempts; first start finalizes qualifying/session evidence and drops other nonfinal evidence, never resumes a half-finished pair after process loss. **DEFAULT:** unbuilt upload retry 5 seconds–15 minutes with jitter and network/foreground triggers. Device restoration remains UNVERIFIED. |
| Locked storage | **FACT:** after-first-unlock receipt directory/store/sidecars and device-only Keychain tokens, backup-excluded receipt directory; callback token selection, immutable snapshots and own-token completion checks. Auth storage is planned; device protection/first-unlock audit and radio token-boundary trial remain UNVERIFIED. |
| Schema/APIs | All proposed table/column/enum/key/index/function names, pair ordering and transaction constraints; per-viewer reveal/date rows derived from transient evidence and time-zone settings; valid zone registered before token/code issuance. |
| Reader details | No GitHub scope, bounded pagination and owner-requested Zenn `all=1`; 200-character preview and description, transient editing draft, explicit refresh acceptance, URL host/path-boundary verification and revalidation; confirmed GitHub disconnect unverifies dependent links and removes imported repository cards, subject to the discovery-prerequisite rule. |
| Arbitrary fetch bounds | Port 443, three redirects, 1 MiB received/decoded and 5 seconds total; safe validated-address connection or feature disabled until enforceable. |
| Daily scheduling | Five-minute Cron, validated IANA zone/latest foreground device, defer missing zone, DST/travel rules, date-only next-report assignment at confirmation, reassignment after time/zone edits, per-local-date idempotency including closed empty dates, per-viewer reveal and transactional reference-only push jobs. |
| Push lifecycle | Per-installation/account/environment/topic registration; rotate/remove on callbacks, sign-out, invalidation or deletion; 90-day stale expiry and current-report-day retries. |
| Retention jobs | **FACT:** receipts 48 wall-clock hours; engine expiry on start, refresh and each 15 running minutes; incomplete presence 5 minutes; diagnostics 7 days/200 trials, 200 exchange and 200 evidence entries per trial, newest 50 attempt endings per trial; expired token pruning on execution, nonce ledger 48 monotonic hours. **DEFAULT:** tunable local periods/caps; planned server token/nonce horizon 48 hours past window end, date + 30-day viewer expiry, 15-minute transient and hourly encounter/key/safety cleanup. |
| Other retention/deletion | Resolved-report period pending privacy policy; active-account blocks until unblocked, delivery keys 30 days; hard deletion sequence with transfer of only the binding safety exception, local clearing and replay tombstones without account-pair links. |
| Safety-record implementation | `deletion_safety_records` and `deletion_safety_blocks`, server-only keyed hash of verified Apple identity, expiry metadata, cascade on blocker deletion, and re-application before participation on same-Apple sign-up. The exception and policy period are binding product rules, not drafting defaults. |
| Test procedures | **FACT:** test-only paired confirmation check in EncounterDomainTestSupport; Development local tokens and owner comparison of both S22 exchange digests, no on-device confirmation. One-day result recorded for 2026-10-11; not-run trials stay open. **DEFAULT:** required later automated cases, aggregated outcomes without participant IDs, balanced orientations, 5-minute stationary second exchange matrix after all three decided/unimplemented follow-ups, rung-3 peer locked, 18/20 successes per pair on both devices' same-digest evidence, paired battery runs. |
| Diagnostics access/sharing | **FACT:** Development-only S01 → S22 without account/backend, persisted local participation switch; Development/Internal log sharing support with Internal route unbuilt, absent from Release. Shared digests disclose a meeting. S22 first-pair completion display remains undecided/unbuilt. |
| Success measurement | No usage analytics in v1; ask friends-test/event participants for product measures and use development/internal diagnostics for technical measures. |
| Work units | **FACT:** Units 1/2 complete; one-day iPhone 15/iPad gate recorded. **DEFAULT:** remaining boundaries and work split; subdivide without bypassing gates. The three 2026-10-11 presence decisions remain unimplemented and must precede the matrix. |

Discovery off, the two-hour session, two-minute ambient threshold, 21:00 report, default profile/contact visibility and explicit link visibility are product decisions, not drafting gaps.

## Open items and risks

- **UNVERIFIED:** background-to-background iPhone discovery and rung 2. The 2026-10-11 iPhone 15/iPad (10th generation) check produced rung-3/4 evidence with both approaches, but first exchanges in both-locked trials happened immediately after Reset, so background discovery was not tested. Both-locked evidence waited for wake. The matrix still gates rung 3; rungs 1 and 2 stay unproven and never promised.
- **FACT:** owner decision 2026-10-11, not yet implemented — make the second exchange default while retaining the held connection in S22 until iPhone-with-iPhone matrix trials confirm it. Both passed rungs 3/4, holding occupies a slot for two minutes and only the second exchange has a possible locked-phone route. Accepted open trade-off: two completed exchanges at least 120 seconds apart do not prove continuous presence; a departure and return within the 5-minute attempt counts. Code still defaults to held connection.
- **FACT:** owner decision 2026-10-11, not yet implemented — pause new peer exchanges for 15 minutes after evidence, cleared by Reset. The current 10-second backoff produces repeats about every 131 seconds, wasting storage/radio work; no lasting peer identifier permits a longer pause. Implement before the matrix.
- **FACT:** owner decision 2026-10-11, not yet implemented — count the 5-second returning-central refusal from the previous attempt's start, currently its end. Keep one attempt per 5 seconds per handle while admitting honest long attempts at once. The diff needs security review; this and repeat traffic distort measurements and must be fixed before the matrix.
- **UNVERIFIED:** undecided and not built — delayed second connection with `CBConnectPeripheralOptionStartDelayKey` might let iOS wake a locked phone. Do not claim it works. Also undecided/unbuilt: show in S22 which first exchange an evidence entry completes; currently its different digest leaves the first entry pending while the trial remains open.
- **UNVERIFIED:** the owner ended the 2026-10-11 check without a 15-minute token-window-boundary trial, real loss of contact and return, or iPhone-with-iPhone trials. Repeat held connection with iPhone open/iPad locked from a clean Reset; existing values came from a continuation. Borrow the second iPhone before the matrix.
- **FACT:** sandbox checks are settled: redirected caches and `--disable-sandbox` permit Swift tests/builds; the type-check script covers app configurations and Development hosted tests. Xcode generation/builds, hosted test execution, artifact checks and Supabase checks belong to the tester outside that sandbox. Unsigned simulator Keychain and device file-protection limitations still need device validation.
- **UNVERIFIED:** Zenn feed opening text, free-account Apple sign-in and current free-account device cap. Test the feed; use the defined metadata fallback, friends-test authentication and signing contingency.
- Validate restoration continuity, first unlock after reboot, protected SwiftData sidecars and future auth credentials on locked devices separately. Held connections and second exchanges worked with one app open on the tested pair; the fake does not prove radio reachability or locked storage guarantees. QR issuance/redemption and new sessions need the server online.
- Accepted security risk from the 2026-10-11 static review: the device nonce ledger evicts its oldest entry beyond 4,096, so Unit 3 server nonce consumption must provide replay control.
- Accepted security risk: the 4,096-receipt cap is cheap to fill with short contacts only when the session flag is set. The app currently supplies false; short session candidates need a smaller budget once sessions exist.
- Accepted security risk: receipt expiry follows wall time, so changing device time can delete or extend receipts, even though presence uses monotonic time.
- Accepted security risk: failed cleanup after a token-roll rejection can leave the rejected receipt until expiry; the server must still validate evidence.
- Accepted security risk: a shared trial log carries the same exchange digest on both phones and reveals that their owners met. Logs exist only in Development/Internal; sharing does not anonymize that relationship.
- Verify the Edge runtime can enforce connected-address validation, redirect checks and bounded streaming; DNS rebinding remains a fetch risk. Do not ship the other-page reader with a check-then-unrestricted-fetch implementation.
- Supabase free-plan pausing and beta Cron/manual linking can interrupt discovery resolution and reports. Measure recovery and document owner operations; a different operating plan needs a later decision.
- Token/nonce windows and reported clocks need device validation; paired receipts do not defeat relays or colluding clients. Do not claim physical-distance proof.
- Settle the exact account-deletion safety-record retention period with the legal review and state it in the privacy policy and S20 deletion confirmation. Choose the resolved-report retention period in the privacy policy before release. Verify managed-service backups/logs and deletion behaviour; do not invent provider retention guarantees. Review whether session expiry metadata and diagnostics meet the disclosed data flow.
- Owner must publish the moderation contact and meet the 72-hour review obligation. Product success targets remain open; ask participants about useful discoveries, original-link opens and favorites/saves, and use development/internal diagnostics for false positives, duplicates, latency and battery under the no-usage-analytics **DEFAULT**.
- Complete trademark registry searches in J-PlatPat and USPTO. **FACT:** the web search recorded in `decisions.md`, **Product**, found no existing use, but registry searches were not done.
- Obtain the Japanese/English legal review and record Supabase hosting region/data flow, privacy labels and store deliverables. EU/UK privacy-law and trader questions and China mainland government filing remain unresolved; no legal conclusion is assumed.
- **UNVERIFIED:** whether the Supabase free plan allows the second, hosted non-production project.
- Copied external URLs and delivered notifications cannot be retracted. Current permission enforcement controls later in-app access, including favorites and saved links.

Evidence and source URLs remain in `decisions.md`, **Verified sources**, **Encounters**, **Build, test and release path** and **Stack, tools and workflow**.
