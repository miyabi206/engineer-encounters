# Specification — Engineer Encounters

**Version:** 0.4\
**Status:** Draft requirements; product decisions recorded in `decisions.md`\
**Date:** 2026-10-11\
**Related:** `decisions.md` v0.4, `design.md` v0.4, `ui.md` v0.2\
**Platforms:** iOS first, Android later\
**Languages:** Japanese, English

## 1. Product vision and principles

Engineer Encounters helps engineers discover the work of other engineers through physical encounters. Reading someone's work is valuable even when the two never talk.

The public names are **Engineer Encounters** in English and **すれちがいエンジニア** in Japanese. The internal codename and repository name remain **Engineer StreetPass**. The word “StreetPass” must not appear in public-facing names, screens or store text.

The goal is a public App Store product built and operated by its owner alone, part-time, on an individual Apple developer account. Japanese UI comes first; the product supports Japanese and English.

### Principles

- Serendipitous discovery of technical work.
- Minimal user effort, with a clear statement of what discovery can promise.
- User-controlled visibility, enforced by the server.
- Privacy by design and no obligation to communicate.
- Independent ownership of external content; originals stay on their platforms.

There is no AI anywhere in the product. Link readers fill in previews automatically from the original sources.

Version 1 is free, with no ads and no purchases. Ads and a paid no-ads plan come only after the whole app is complete.

## 2. Target users

The initial audience is engineering students and software developers. Other users include open-source contributors, technical writers, researchers, startup founders and engineering community organizers.

Users must be 18 or older at launch. They declare this at sign-up, and the App Store minimum age is set to 18+. The age may be lowered to 16+ later, once moderation has a track record.

Recruiters and career features are outside v1.

## 3. Purposes

Users select their purposes during onboarding and may enable both or change them later.

| Purpose | Value |
|---|---|
| Discovery | Discover technical works published by encountered engineers. |
| Collaboration | Discover people interested in development projects, hackathons, research collaboration or open-source contributions. |

Opportunity mode and career features are a later mode.

## 4. Accounts and profile

### Accounts

- The release build requires Sign in with Apple.
- Sign-up includes the 18+ declaration and acceptance of the terms and privacy policy.
- GitHub is a linked identity used for verification, not a sign-in method.
- Temporary anonymous accounts exist only in development builds and are compiled out of the release build. The friends test uses them.

A durable identity makes blocks, removals, the 18+ declaration and account deletion hold. An anonymous install can be reset by reinstalling.

### Profile fields

| Field | Requirement |
|---|---|
| Display name | **DEFAULT:** up to 30 characters. |
| Self-introduction | Written by the user. **DEFAULT:** up to 200 characters. |
| Interests | **DEFAULT:** selected from a fixed curated list; no free-text interests in v1. |
| Purposes | Discovery, Collaboration, or both. |
| Links | **DEFAULT:** up to 10 per user. |
| Contact detail | One optional detail, private by default. |

**DEFAULT:** no uploaded avatar in v1; the card uses an initial-letter avatar.

Discovery is the master switch for taking part in encounters and is off by default. Turning it on requires a display name, a self-introduction, at least one interest and at least one link of any kind.

Onboarding requests Bluetooth permission and explains what discovery promises, its limitations and the force-quit rule before turning discovery on.

## 5. Links

A link card is one shared link with its automatically filled title or name, description, main language, source, tags and opening or preview text, where available for that source. A link reader is the server component that reads one kind of source.

### Supported sources

| Source | Selection and reading | Automatically filled fields |
|---|---|---|
| GitHub repositories | Connect GitHub, then select from the user's own public repositories. Read through the official GitHub API. | Name, description, main language, first lines of the README. |
| Qiita articles | Enter a Qiita username once, then select from the user's own articles. Read through the official Qiita API v2. | Title, tags, opening lines. |
| Zenn articles | Enter a Zenn username once, then select from the user's own articles. Read through the official per-user RSS feed. | Title, opening lines. |
| Other pages, such as portfolios and blogs | Fetch the page once and read only its title and Open Graph preview description. | Title, preview text. |

**UNVERIFIED:** whether Zenn's feed carries each article's opening text. If it does not, use the preview description of the article page for that field.

### Reading and ownership

- Do not scrape page bodies. Store only title or name, description, main language, source, tags, and roughly the first 200 characters of opening or preview text. Nothing else from the source is stored.
- The owner previews and can edit every automatically filled field before sharing, and can refresh it on demand.
- Links open the original content on its platform. The app does not host portfolios, repositories, articles, documents or resumes.
- External links can identify their owners even when an in-app nickname is used. Explain this before sharing identifiable links.
- Removing a link removes in-app access; it does not delete the original or retract an external URL a reader has already copied.
- Arbitrary-page reading must prevent server-side request forgery and treat fetched text as untrusted. The protections belong in `design.md`, **Fetching other pages**.

### Verification

- A GitHub link is verified by connecting the account.
- Another link is verified when it sits under an address listed on that verified GitHub profile, including its website or social links.
- A Qiita link is also verified when the Qiita account's linked GitHub ID matches the connected account.
- All other links carry an unverified label and can be reported as impersonation.

Build the GitHub reader first; it alone is enough for the friends test. Qiita and Zenn follow, then other pages. All four readers are required before public release.

## 6. Encounters

### Definitions and confirmation

An encounter records physical co-presence under the rules below. Bluetooth encounters require at least 2 minutes within Bluetooth range, with the session exception described below.

- An **ambient encounter** is a Bluetooth encounter in which at least one of the two people was not in a session. A QR encounter is never ambient. This includes an exchange when only one user is in a session; it is revealed at the daily report. The 2-minute threshold is mandatory. Shorter ambient contacts are discarded so a person walking past cannot collect a card.
- A **session** is a time-boxed period started deliberately by the user. A **session encounter** is between two users who are both in a session; an exchange counts immediately.
- A **QR encounter** is created when one user scans the other's QR code, without Bluetooth, and is confirmed immediately under the QR confirmation rule in `design.md`, **Confirmed encounter, security definition**.

An **exchange** is one Bluetooth connection that swaps temporary tokens in both directions. Each phone keeps a **receipt**, which it uploads to the server. An uploaded receipt that has not been confirmed is a **candidate**. A **confirmed encounter** has two cases: for a Bluetooth encounter, the server holds matching receipts from both phones and the rules in **Encounters** are met; for a QR encounter, the showing phone obtained a short-lived one-time code from the server while signed in and the scanning phone uploaded that code before it expired, so both accounts took part and no receipts are involved. One-sided receipts remain candidates.

Symmetric rule: an encounter counts only when both phones take part, meaning both report the Bluetooth exchange, or one shows and the other scans a QR code.

Confirmation must reject invalid, stale or replayed receipts. Session confirmation must use the server's own record that both users had active sessions. The protocol and confirmation details belong in `design.md`, **Bluetooth transport** and **Confirmed encounter, security definition**.

A confirmed Bluetooth encounter is evidence of a Bluetooth interaction, not cryptographic proof of physical distance: an attacker can relay an exchange. Signal strength is only a rough range indicator.

**FACT:** Unit 2 built both held connection (接続を維持) and second exchange (2回目の交換). The held connection updates one receipt with a checkpoint token pair; the second exchange creates a second receipt with `priorExchangeNonce` naming the first exchange and the monotonic duration between exchanges, retaining the first receipt as final. Unit 3 server resolution must accept both shapes, reject replay and require the matching receipts from both phones. On device, S22 shows only local two-minute evidence and an exchange digest (first 8 hexadecimal characters of SHA-256 of the exchange nonce); the owner compares the two screens. The two-receipt confirmation harness is only a test check and is not linked into the app.

### The ladder

The ladder contains five rungs, ordered by user effort. All operate at the same time; the app never switches modes.

| Rung | Conditions | User effort | Product claim |
|---|---|---|---|
| 1 — Locked | Both phones locked, app in the background. | None. | Unproven; may not work at all. Never promised. **FACT:** neither approach produced two-minute evidence while both devices stayed locked on the iPhone 15 and iPad (10th generation) pair on 2026-10-11. |
| 2 — Awake | At least one phone in use with another app in front. | None. | Unproven; measured separately from Locked. **UNVERIFIED:** not tried on 2026-10-11; measured separately from Locked, never promised. |
| 3 — One open | At least one user has the app open. | One tap by one person. | The public promise, subject to the release gate. Expected to work through two independent paths: the open phone scanning and the open phone advertising. **FACT:** both approaches worked in both orientations on the iPhone 15 and iPad (10th generation) pair on 2026-10-11; the held connection with iPad locked was a continuation, not a clean reset-then-lock trial. |
| 4 — Both open | Both users have the app open. | One tap each. | Fastest. **FACT:** both approaches worked on the iPhone 15 and iPad (10th generation) pair on 2026-10-11. |
| 5 — Manual | One user shows a QR code and the other scans it. | A few seconds together. | Always works; no Bluetooth. |

Public wording promises rung 3 and describes rungs 1 and 2 as “may also work”. Use no beacons or other fixed hardware.

Force-quitting the app stops discovery until it is reopened. Onboarding must explain this. Before the first unlock after a reboot, discovery does not work; this limitation is tested separately.

**FACT:** on 2026-10-11 the owner checked an iPhone 15 with an iPad (10th generation), using Development builds and local test tokens, without a backend or account. In the trials with one app open the locked device completed its part on time; in most of them its step followed contact from the open device within seconds, which is consistent with the open device waking it (an inference from timing, not logged); in the second-exchange trial with the iPhone locked, the locked iPhone made its second connection on its own at about 125 s, about ten seconds before the iPad made its own. With both locked, neither approach produced two-minute evidence until a device was woken; a suspended app gets no timer.

**UNVERIFIED:** discovery between two backgrounded devices, including two iPhones. Both-locked trials completed the first exchange immediately after Reset, before backgrounding, so they did not test discovery. Rung 2 was not tried. Platform facts and the full check are recorded in `decisions.md`, **Encounters** and **Build, test and release path**; lifecycle details are in `design.md`, **Background lifecycle and storage**.

### Sessions

- A Start session button starts a session lasting 2 hours or until the user stops it.
- A running session is shown as a Live Activity.
- A one-tap control, as a widget or Control Center control, can start a session.
- Two users who are both in a session see each other immediately after confirmation.

## 7. Reveal and notifications

A **revealed encounter per viewer** is a confirmed encounter that a user is now allowed to see. Each of the two users reaches this at their own daily report, so one may see the other before the reverse. This follows from the decision that each user can change their report time. The **daily report** is the once-a-day reveal of that day's ambient encounters.

- Ambient encounters become visible, with names, only when that viewer's daily report arrives. The reveal gate is per viewer; before it passes, that viewer receives no identifiable preview.
- The report defaults to 21:00 local time. Users can change its time and turn its notification on or off. Skip the report on days with no encounters.
- A daily report notification may show names. Delay provides the protection: immediate ambient reveal would identify nearby strangers in real time.
- Session encounters and QR encounters pass both viewers' reveal gates immediately.
- The release build has no immediate ambient notifications.
- Do not issue someone-is-nearby notifications or prompts of any kind. There is no weekly digest.
- Development and internal builds have a demo switch for immediate ambient reveal and notification. The same switch is used in device tests and is compiled out of the release build.

APNs delivers the daily report notification. Scheduling, time-zone handling and push-token lifecycle belong in `design.md`, **Daily report delivery**. Notification and session surfaces belong in `ui.md`, **Surfaces outside the app**.

## 8. Matching and visibility

### Eligibility and compatibility

- **Eligible:** a confirmed encounter, discovery on for both users, and no block in either direction.
- **Compatible:** eligible, with overlapping purposes and the interest threshold of each side met.
- **DEFAULT:** each user's interest threshold starts at 1 shared interest and is adjustable.

Matching never hides an encounter. It orders the feed and gates fields set to compatible only.

### Visibility levels

Each profile field and link uses one of three levels:

| Level | Who can see it |
|---|---|
| Everyone eligible | Any eligible encountered user. |
| Compatible only | Eligible users who also meet compatibility conditions. |
| Private | No other user. |

Once discovery is on, the display name, self-introduction, interests and purposes default to everyone eligible. Links have no default level: the user must choose a level when adding each link. The optional contact detail defaults to private.

Current settings apply in both directions, including to past encounters, favorites and saved links. The server enforces authorization and never sends an unauthorized field to the app. Direct table access from the app is denied by default.

`design.md`, **Matching and visibility**, must publish a truth table covering both discovery switches, blocks, purposes, interest thresholds and each visibility level.

## 9. Privacy and safety

### Data and retention

- Never request or store location in v1. The server never stores location.
- Store an encounter's date, not its time. Times exist only inside unresolved candidates and are discarded on confirmation or dropping the candidate.
- Drop unresolved candidates after 48 hours.
- Delete encounters automatically after 30 days unless the viewing user marks them as favorites. A favorite is retained for that viewer and shows only what the other user currently allows.
- An encounter deletion or block by either user removes the encounter for both, including favorites.
- Users can save individual link cards. **DEFAULT:** saved links follow the same rules as favorites and disappear when the encounter is removed.
- Account deletion is available inside the app and is immediate and permanent for all personal data, with one safety exception: the server keeps only a one-way hash of the Apple account identifier together with operator moderation outcomes and the blocks other people placed on that account, for a period the privacy policy states, and re-applies them if the same Apple identity signs up again. Nothing else survives. The hash cannot be turned back into the Apple identifier; the kept record holds no name, profile field, link, token, encounter or contact detail. A block is dropped when the person who placed it deletes their own account. The privacy policy and the S20 deletion confirmation disclose this exception. The exact retention period is an open item to settle with the legal review.
- Bluetooth exchanges must not carry account IDs, names, GitHub handles, email addresses or links; only temporary tokens identify the participants.

The retention and deletion contract must also cover on-device diagnostics, on-device receipts, token batches, reports and push tokens. **DEFAULT:** Development and Internal diagnostics are kept for 7 days; reports are kept until resolved, then for a period stated in the privacy policy, unless account deletion erases them; only operator moderation outcomes may survive under the safety exception above. Unspecified retention periods remain open. Details belong in `design.md`, **Retention and deletion contract**.

### Moderation

- Block, report and account deletion are required in v1.
- Hide a reported person from the reporter at once.
- A profile reported by 3 different users is hidden from everyone until the operator reviews it, within 72 hours.
- **DEFAULT:** report reasons are spam, harassment or inappropriate content, impersonation, and other.
- The owner is the operator and publishes a moderation contact address.
- Receipt uploads and encounter resolution must be rate-limited per account.

### Sample encounter

New users see one clearly labelled sample encounter. It also gives App Review something to open. **DEFAULT:** the sample exists only on the device and can be dismissed.

## 10. Scope of v1

### Included

- Discovery and purpose selection.
- Profiles and links with automatic filling and owner editing.
- Three visibility levels and server-enforced matching and authorization.
- Encounter feed grouped by day, with session and QR actions and a favorites filter; favorite encounters and saved links.
- Daily report, sessions and QR exchange.
- Block, report and in-app account deletion.
- A clearly labelled sample encounter.

### Excluded

- Opportunity mode, recruiters and career features.
- Connection requests and the mutual connections visibility level.
- Weekly digest and immediate ambient notifications in the release build.
- Private messaging, organization verification and recruiting dashboards.
- Semantic recommendations, an iPad-specific interface and Android.

### Later

- Ads and a paid no-ads plan after the whole app is complete. Ad SDK data collection must then be included in App Store privacy labels, and that step makes the owner a trader under EU rules.
- A possible opt-in background boost where on-device location wakes the app, with nothing sent to the server and the feature off by default. Revisit it only after Bluetooth-only results for rungs 1 and 2.
- A career mode.
- Android, reusing the backend and Bluetooth protocol.

The interface uses standard iOS components, light and dark modes, and Dynamic Type, with Discover, Profile and Settings tabs. It retains the concept's teal accent and card layout. Screen definitions, navigation, bilingual labels and external surfaces belong in `ui.md`, **Navigation**, **The 26 screens** and **Surfaces outside the app**.

## 11. Supported devices

The initial app is native iOS, using Swift and SwiftUI. Minimum iOS is 26.0; builds use Xcode 27.0 and Swift 6.4. Legacy support is not a project requirement.

Development and radio tests use the owner's iPhone 15 and iPad (10th generation), plus a second recent iPhone borrowed before the matrix. The iPad is an experimental peer; an iPhone-with-iPad result does not establish iPhone-with-iPhone behaviour. There is no iPad-specific interface in v1.

| Build kind | Distribution | Development features |
|---|---|---|
| Development | Run from the owner's Mac. | Temporary anonymous sign-in, the demo switch and diagnostics. |
| Internal | TestFlight only to the owner's own devices. | The demo switch and diagnostics; Sign in with Apple, no anonymous sign-in. |
| Release | App Store; TestFlight for the 20-person event, made with the release configuration against the production backend. | Sign in with Apple; anonymous sign-in, the demo switch and diagnostics are all compiled out. |

Core Bluetooth provides discovery; it is the only Apple framework that works in the background between strangers without pairing and permits a later Android implementation of the same protocol.

Implementation uses SwiftData with a replaceable receipt queue, CryptoKit and the Keychain, camera QR scanning, Supabase's free-plan Auth, PostgreSQL, Edge Functions and Cron, and APNs. Architecture, backend languages, storage, token handling, repository structure and development tools belong in `design.md`, **Stack, tools and workflow**, following `decisions.md`, **Stack, tools and workflow**.

**FACT:** Unit 2 built AppComposition and EncounterRuntime around a persisted local participation switch, default off. No Bluetooth manager is created before it is on; App.init recreates the runtime when participation is on so state restoration works. The session flag source is false until sessions exist. KeychainTokenBatchStore uses after-first-unlock, this-device-only accessibility. Development issues local test tokens in a 12-hour batch of quarter-hour-aligned 15-minute windows; Internal and Release have no issuer and stay paused for lack of a token until Unit 3. App-directory-anchored source exclusions and conditional compilation gate Development and Diagnostics sources; the release-artifact script checks marker names and string tables in all three configurations.

**FACT:** SwiftDataReceiptQueue stores each receipt’s Codable payload beside identity, sequence and expiry on a model actor, with after-first-unlock file protection, a backup-excluded directory and at most 4,096 receipts and 4,096 terminal-identity tombstones. Expired receipts are never returned; the engine invokes expiry on start, refresh and every 15 minutes while running. The adapter bounds admission, observations and write fragments, and the engine bounds peer/nonce ledgers and rechecks its own token at completion; the verified values and accepted security trade-offs are recorded in `decisions.md`, **Technical design inputs**.


## 12. Release path and gates

Each stage gates the next. Device radio tests and battery measurements are performed by the owner.

| Stage | Required work and gate |
|---|---|
| 1 — Toolchain check | **FACT:** Unit 1 implemented and merged to main (pull request 2); XcodeGen and Deno installed. Sandbox Swift tests pass with local cache paths and `--disable-sandbox`, and iOS code compiles with the simulator triple/SDK. XcodeGen, xcodebuild, app-hosted tests, release-artifact checks and every Supabase command run outside that sandbox in the tester role. The sandbox question is resolved. |
| 2 — Bluetooth engine | **FACT:** Unit 2 implemented and merged to main (pull requests 4 and 5), with real-app S22 diagnostics. The owner’s 2026-10-11 check used an iPhone 15 and an iPad (10th generation), Development builds and local test tokens, no backend/account. Rungs 3 and 4 worked with both approaches in both orientations, subject to the continuation limitation below; unrun trials remain open. |
| 3 — Basic functions | Build the basic functions, implement all three 2026-10-11 owner decisions below (decided but not yet implemented), then complete the 160-trial matrix with a borrowed second iPhone. Security-review the refusal diff before the matrix. |
| 4 — Friends test | Test with 3 to 5 friends in a small room or cafe using the free Apple account, cable installs from the owner's Mac, temporary anonymous sign-in and sessions for immediate results. **DEFAULT:** the friends test uses development builds pointed at a hosted non-production Supabase project, because the phones leave the owner's Mac. Anonymous sign-in is enabled only on that non-production project and disabled on production, in addition to being compiled out of the release build. Local Supabase is for automated checks and the owner's own development. View the daily report inside the app without a notification. The GitHub reader alone is sufficient. |
| 5 — Developer Program | Join the Apple Developer Program; add and verify Sign in with Apple, push notifications and TestFlight. |
| 6 — Event | Test at one real event with 20 or more people using a TestFlight build made with the release configuration against the production backend. No demo switch, diagnostics or anonymous sign-in; attendees sign in with Apple. Internal builds keep the demo switch and diagnostics and go only to the owner's own devices. |
| 7 — Review and Japan release | Obtain one professional review of the privacy policy and terms in Japanese and English, then release publicly in Japan. All link readers must be complete. |
| 8 — Other storefronts | Expand in waves under the regional conditions below, with worldwide availability as the goal. |

**FACT — one-day check, 2026-10-11:** on the iPhone 15 and iPad (10th generation), held-connection evidence with both open arrived at these values: iPhone 124.4 and 127.5 s; iPad 129.0 and 132.2 s. With iPad open and iPhone locked: iPhone 122.6 and 123.8 s; iPad 121.4 and 122.7 s. With iPhone open and iPad locked: iPhone 256.8 and 261.2 s; iPad 261.3 and 265.9 s, only as a continuation of the both-open trial without Reset, not a clean reset-then-lock trial. Second-exchange evidence with both open: iPhone about 124.4 s for both exchanges; iPad about 124.4 s for both exchanges. With iPad open and iPhone locked: iPhone 125.2 and 136.8 s; iPad 123.6 and 135.3 s. With iPhone open and iPad locked: iPhone 126.1 and 133.0 s; iPad 127.4 and 134.4 s. Values are seconds from trial start (Reset). Each device records two evidence values per trial, one per role; each row gives the iPhone values, then the iPad values. The two devices start their trial clocks at their own Reset, so values for the same exchange differ slightly between devices. Count a trial only when both devices show evidence for the same exchange digest. In the trials with one app open the locked device completed its part on time; in most of them its step followed contact from the open device within seconds, which is consistent with the open device waking it (an inference from timing, not logged); in the second-exchange trial with the iPhone locked, the locked iPhone made its second connection on its own at about 125 s, about ten seconds before the iPad made its own.

With both locked, the held connection’s first exchanges were at about 2.3 s; its checkpoint ran only after wake at about 255 s, with observed duration 252.7 s (repeated with the same result). The second exchange’s first exchanges were at about 1–2 s; none completed again while locked. Wake after about 310 s expired the attempts at their 5-minute bound without evidence; fresh exchanges after wake produced evidence at about 445 s. Both-locked discovery remains **UNVERIFIED**, because first exchanges occurred just after Reset. With both open about 2 m apart for 10 minutes, the second exchange produced evidence at about 123.5, 256.3, 389.9 and 522.9 s without a failed or disconnected attempt. The owner also observed connection beyond 10 m without a log; this is not a distance guarantee.

Before pull request 5, evidence arrived at about 123–132 s, followed by central failures about every 10 s: app-level cancellation left the physical link up and no new subscription reached the peer. Unit 2 changed teardown to unsubscribe before cancel (at most 1 second’s wait) and admits an offset-0 read as a new logical link from a still-subscribed central. After Reset, one direction can still fail at about 1–2 s and complete its first exchange about 10 s later because of the 5-second refusal. S22 records second-exchange evidence under the second exchange digest; its first exchange stays pending while the trial is open, then missing after closure.

The owner ended the check on 2026-10-11 without token-window-boundary, real loss-of-contact-and-return, or iPhone-with-iPhone trials. Those and rung 2 remain **UNVERIFIED**; an iPhone-with-iPad result does not establish iPhone-with-iPhone reliability.

**Owner decisions — 2026-10-11, prerequisites of the matrix:** all three are binding, decided but **not yet implemented**.

- Make the second exchange the default. Keep the held connection selectable in S22 until iPhone-with-iPhone matrix trials confirm the choice. Both approaches passed rungs 3 and 4 on the tested pair; a held connection occupies one of the engine’s four connection slots for two minutes per peer; only the second exchange has a possible route for locked phones. Accepted trade-off: two completed exchanges at least 120 seconds apart prove two-minute evidence, not continuous presence, so leaving and returning within the 5-minute attempt still counts. **FACT:** the code still defaults to held connection; this decision is not yet implemented.
- After two-minute evidence with a peer, start no new exchange with that peer for 15 minutes (one token window); Reset clears the pause. Repeating about every 131 to 133 seconds currently stores receipts and uses the radio indefinitely. A longer pause is impossible without a lasting peer identifier, which the app does not keep. **FACT:** only the 10-second backoff exists; this decision is not yet implemented.
- Count a returning central’s 5-second refusal from the previous attempt’s start, rather than its end, retaining one attempt per 5 seconds per handle while accepting honest peers immediately after longer attempts. **FACT:** the code still counts from the end of an attempt without evidence; this decision is not yet implemented and its diff needs a security review. The pause and refusal changes must precede the matrix because current behaviour distorts its measurements.

### Device matrix and battery gate

- Test rungs 1 to 4 on two pairs: iPhone with iPad and iPhone with iPhone. Run 20 stationary trials for each rung and pair, for 160 trials total.
- Record 10-second and 30-second passes for information only.
- Measure completion time of the two-way token exchange and whether both phones confirm two minutes of continued presence.
- A rung-3 trial passes when both phones hold the two-minute presence evidence for the same exchange within 5 minutes of the start of the trial. Server confirmation time is recorded separately and is not part of the pass mark, because uploads may be deferred. At least 90 percent of rung-3 trials must pass.
- Rungs 1 and 2 have no pass mark; their results determine only how they are described.
- Discovery must add at most 5 percentage points of battery use over 8 hours compared with discovery off.
- If rung 3 fails, stop and rethink: only the QR rung would remain.
- Twenty trials cannot distinguish 90 percent from 80 percent with confidence. The outcome is a go or no-go signal, not a measured reliability rate.

Run detached from the debugger. Record iOS and build versions, reset state between trials, bound pending connection lifetimes, and record per-trial elapsed values for discovery, exchange completion, two-minute evidence and server confirmation separately. Test the first-unlock-after-reboot limitation separately. Radio procedures belong in `design.md`, **Test plan**.

The simulator has no Bluetooth. **FACT:** Unit 2 changed BluetoothTransport to a radio command/event interface, with EncounterEngineCore owning the deterministic synchronous protocol and EncounterEngine running it as an actor. FakeBluetoothTransport, the paired-phones rig, manual clock and confirmation check are in EncounterDomainTestSupport, never linked by the app; the fake now exercises the real exchange logic, including the 2-minute rule and token rotation. The both-receipts check is a test oracle; server confirmation arrives in Unit 3. Implementation units have terminal checks for Swift packages, simulator builds, backend functions and the local database; commands and tooling belong in `design.md`, **Stack, tools and workflow**. Before the event, verify the TestFlight artifact uses the release configuration and production backend, requires Apple sign-in, contains no anonymous sign-in, demo switch or diagnostics, and follows normal daily reveal and notification timing. Internal builds go only to the owner's own devices.

### Distribution and operational limits

- **FACT:** free Apple accounts cannot distribute through TestFlight or the App Store; builds expire after about a week and push notifications are unavailable.
- **UNVERIFIED:** whether Sign in with Apple is available on a free account. Older sources report a device cap of about 3, but the current cap is unconfirmed.
- If the free account's device cap is reached during the friends test, a friend's phone can be signed using that friend's own free Apple ID.
- **FACT:** Supabase can pause a low-activity free-plan project over a 7-day period; paid projects are not paused. A quiet week after release could take the app offline until the owner restores it manually.
- **FACT:** Supabase labels manual identity linking and Supabase Cron as beta. Their integration and the free-plan backend are specified in `design.md`, **Stack, tools and workflow**.

### Public release requirements

The owner is responsible for:

- Privacy policy and terms in Japanese and English, disclosing the account-deletion safety exception and its retention period, with public URLs for these and support.
- App Store privacy labels and the Bluetooth purpose string.
- In-app account deletion and a published moderation contact.
- An App Review demonstration using the sample encounter and review notes.
- A data-flow description covering Supabase and its hosting region for the Japanese privacy-law assessment.
- Trademark registry searches in J-PlatPat and USPTO for both public names before public release. **FACT:** a web search found no existing app, service or trademark using either name; the registries were not searched.

Japan is the first storefront. Other storefronts follow in waves. EU and UK release requires a privacy-law check and a trader decision. China mainland is excluded until the government-filing question is answered. These legal questions remain open and must not be presented as settled.

## 13. Success metrics

**DEFAULT:** v1 collects no usage analytics. Product measures are gathered by asking participants at the friends test and at the event, and technical measures come from the diagnostics of development and internal builds.

Technical measures:

- Encounter confirmation success and latency, reported separately by rung and device pair.
- Per-trial elapsed values for discovery, exchange completion, two-minute evidence and server confirmation.
- False-positive and duplicate encounters.
- Additional battery use with discovery enabled.

Product measures:

- Relevant links discovered and original-link opening rate.
- Favorite encounters and saved links.
- Useful discoveries reported by users.

The objective is meaningful discovery, not maximizing the number of encounters. Technical acceptance uses the gates in **Release path and gates**; product targets remain open.

## 14. Defaults chosen during drafting

**DEFAULT** items fill gaps and are not confirmed owner decisions. Technical starting values may change after the matrix. **FACT** entries below distinguish what Unit 2 built from defaults still awaiting implementation or review.

| Area | Drafting default |
|---|---|
| Display name | Up to 30 characters. |
| Self-introduction | Up to 200 characters. |
| Interests | Fixed curated list; no free-text interests in v1. |
| Avatar | Initial-letter avatar; no uploaded avatar in v1. |
| Links | Up to 10 per user. |
| Interest threshold | 1 shared interest by default, adjustable by each user. |
| Reports | Reasons: spam, harassment or inappropriate content, impersonation, other. |
| Sample encounter | On-device only and dismissible. |
| Saved link | Same retention and current-visibility rules as a favorite; disappears if the encounter is removed. |
| Feed card | Display name, shared interests, first visible link card, a verified or unverified label per link, encounter kind (ambient, session or QR), and day. Never time or place. Layout belongs in `ui.md`, **The 26 screens**. |
| Temporary tokens | Random, server-issued in batches, valid for 15-minute windows and the only identifiers exchanged. Details belong in `design.md`, **Bluetooth transport**. |
| Presence implementation | **FACT:** Unit 2 built held connection and second exchange; the code default is still held connection. The 2026-10-11 decision to default to second exchange is binding, not a drafting default, and is not yet implemented; see **Release path and gates**. |
| Friends-test backend | Development builds use hosted non-production Supabase; anonymous sign-in enabled only there, disabled on production and compiled out of release. Local Supabase is for automated checks and the owner's own development. |
| Success measurement | No usage analytics in v1; ask friends-test/event participants for product measures and use development/internal diagnostics for technical measures. |
| Diagnostics | Development and Internal diagnostics kept for 7 days. **FACT:** Unit 2 caps each trial at 200 exchanges and 200 evidence entries, keeps 200 trials and the newest 50 attempt endings, and shows dropped-entry counters. S22 has only a Development route from S01 until Settings exists. |
| Moderation report retention | Kept until resolved, then for a period the privacy policy will state, unless account deletion erases them; only operator moderation outcomes may survive under the safety exception. |

Discovery off, the 21:00 daily report, profile visibility and private contact details are specified product defaults, rather than gaps filled during drafting. Links require an explicit visibility choice. The second-exchange default, 15-minute peer pause and refusal-from-attempt-start decisions are also binding; all three are not yet implemented and are recorded with reasons in **Release path and gates**.

## 15. Open items

- Trademark registry searches for **すれちがいエンジニア** and **Engineer Encounters**.
- **UNVERIFIED:** background-to-background discovery, including two iPhones, and rung 2 (not tried); neither rung 1 nor rung 2 is promised. Both-locked trials began with foreground first exchanges.
- **UNVERIFIED:** whether Zenn's feed includes the opening text of an article.
- **UNVERIFIED:** the unrun 15-minute token-window-boundary, real loss-of-contact-and-return and iPhone-with-iPhone trials, a clean reset-then-lock held-connection trial with iPad locked, the 160-trial matrix and battery gate. The sandbox question is resolved by Unit 1, as recorded in **Release path and gates**.
- Implement the three binding 2026-10-11 owner decisions before the matrix; all are decided but not yet implemented. The refusal diff requires a security review.
- **UNVERIFIED:** delayed second connection using `CBConnectPeripheralOptionStartDelayKey` to wake a locked phone; undecided and not built. Showing in S22 which first exchange an evidence entry completes is also undecided and not built.
- Accepted Unit 2 security risks from the 2026-10-11 static review: oldest-entry eviction above 4,096 nonces means Unit 3 server nonce consumption is the replay control; short session candidates need a smaller budget than the 4,096-receipt cap when sessions exist; wall-clock changes can delete or extend receipts; failed cleanup after a token-roll rejection can leave a receipt until expiry; shared Development/Internal trial logs expose matching exchange digests and reveal that the owners met. The review fixes and current bounds are recorded in `decisions.md`, **Technical design inputs**.
- **UNVERIFIED:** whether Sign in with Apple is available on a free Apple account, and its current device cap.
- Whether a foreign developer needs a government filing number for China mainland distribution; sources conflict.
- Whether a solo developer with a free, ad-free app counts as a trader under EU rules.
- The exact retention period for resolved moderation reports.
- The exact retention period for the account-deletion safety record (hashed Apple identifier, operator moderation outcomes and incoming blocks), to settle with the legal review and state in the privacy policy.
- Remaining retention defaults for token batches, push tokens and Development/Internal diagnostics are in `design.md`, **Retention and deletion contract**. **FACT:** Unit 2 implements the 48-hour receipt expiry, protected storage and backup exclusion; receipt expiry is invoked on start, refresh and every 15 minutes while running. Sign-out/account-deletion integration and real-device protection checks remain to complete.
- `design.md`, **Daily report delivery**, now proposes time-zone handling values as **DEFAULT**, pending confirmation after the device checks.
- Transport timing values remain adjustable **DEFAULT** values in `design.md`, **Bluetooth transport**; Unit 2’s current timeouts, subscription teardown and both receipt shapes are implemented facts. Reliable locked evidence and background discovery remain unverified.
- Product success targets; no numerical targets are specified.
- **UNVERIFIED:** whether the Supabase free plan allows the second, hosted non-production project.

The full source list and evidence markings are in `decisions.md`, **Verified sources**, **Encounters**, **Build, test and release path**, and **Stack, tools and workflow**.

## 16. Changes from v0.2

- Adopt the Japanese and English public names and keep the codename internal.
- Set launch age to 18+, Japanese UI first, free operation without ads or purchases, and a Japan-first rollout.
- Require Sign in with Apple for release; use GitHub only as a linked verification identity.
- Define profile requirements, discovery prerequisites and labelled drafting limits.
- Replace the previous content-processing feature with editable, automatically filled link cards from four source readers.
- Promise the One open rung, measure the two background rungs separately, require two minutes for ambient encounters and both phones' reports for Bluetooth confirmation.
- Add 2-hour sessions, a Live Activity, a one-tap session control and QR exchange.
- Reveal ambient encounters only at the daily report; remove the weekly digest and release-build immediate ambient notifications.
- Reduce visibility to three levels and remove connection requests. Separate eligibility from compatibility; matching orders the feed and gates compatible-only fields.
- Apply current settings to past encounters, favorites and saved links, with server-only authorization.
- Include favorites, saved links, block, report, immediate account deletion and the sample encounter in v1.
- Define date-only records, 48-hour candidate expiry, 30-day encounter retention and mutual encounter removal.
- Fix the minimum iOS version and build tools, distinguish three build kinds, and introduce staged device, friends, event, legal and regional release gates.
- Move protocol, schema and tooling details to `design.md` and screen details to `ui.md`.

**Changes in v0.4 — 2026-10-11:**

- Record Units 1 and 2 merged to main, the resolved sandbox checks and the engine-owned command/event protocol with test-only confirmation support.
- Record the iPhone 15/iPad (10th generation) one-day check, the unsubscribe fix, evidence limitations and unrun trials; keep rung 3 as the public promise and rungs 1 and 2 unproven and never promised.
- Record the three binding presence decisions with reasons and not-yet-implemented status as prerequisites of the matrix.
- Update diagnostics and storage facts, accepted security risks, current document versions and remaining open items.
