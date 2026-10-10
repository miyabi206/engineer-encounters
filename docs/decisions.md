# Decisions — Engineer Encounters

**Version:** 0.3\
**Status:** Confirmed product decisions; drafting defaults and unverified items labelled\
**Date:** 2026-10-10\
**Related:** `specification.md` v0.3, `design.md` v0.3, `ui.md` v0.1\
**Platforms:** iOS first, Android later\
**Languages:** Japanese, English

Unmarked items are binding product decisions. **DEFAULT** marks a value chosen to fill a gap during drafting, not a decision made by the product owner. **UNVERIFIED** marks an unresolved claim that must not be presented as fact. **FACT** retains the evidence marking in the decision brief.

## 0. Glossary

- **Encounter:** two users were within Bluetooth range of each other and the app recorded it under the rules in **Encounters**.
- **Ambient encounter:** an encounter in which at least one of the two people was not in a session.
- **Session:** a time-boxed period a user starts on purpose with the Start session button.
- **Session encounter:** an encounter between two users who were both in a session.
- **QR encounter:** an encounter created by one user scanning the QR code of the other.
- **Ladder:** the five ways an encounter can be recorded, ordered by how much the users must do. Each one is a rung.
- **Exchange:** one Bluetooth connection in which the two phones swap temporary tokens in both directions.
- **Receipt:** the record one phone keeps of an exchange, uploaded to the server.
- **Candidate:** an uploaded receipt the server has not yet confirmed.
- **Confirmed encounter:** for a Bluetooth encounter, the server holds matching receipts from both phones and the rules in **Encounters** are met. For a QR encounter, the showing phone obtained a short-lived one-time code from the server while signed in and the scanning phone uploaded that code before it expired, so both accounts took part and no receipts are involved.
- **Revealed encounter:** a confirmed encounter that the two users are now allowed to see.
- **Daily report:** the once-a-day moment when the ambient encounters of that day are revealed, with a notification.
- **Card:** what one user sees of another, meaning the authorized profile fields and link cards.
- **Link card:** one shared link with its automatically filled title, source, tags and opening text.
- **Link reader:** the server component that reads one kind of source (GitHub, Qiita, Zenn, other pages).
- **Eligible and compatible:** defined in **Matching and visibility**.
- **Discovery:** the master switch a user has for taking part in encounters.
- **Development build, internal build, release build:** defined in **Stack, tools and workflow**.

## 1. Product

- Goal: a public App Store product, built and operated by the owner alone, part-time, on an individual Apple developer account.
- Core: engineers discover the work of other engineers through physical encounters. Reading the work of someone is valuable even if the two never talk.
- Public names: Japanese **すれちがいエンジニア**, English **Engineer Encounters**. The word “StreetPass” must not appear in any public-facing name, screen or store text. **Engineer StreetPass** remains the internal codename and repository name.
- A trademark registry search (J-PlatPat, USPTO) for both public names is still to do before public release. **FACT:** a web search found no existing app, service or trademark using either name. The registries themselves were not searched.
- Languages: Japanese and English. Japanese UI first.
- Age: 18+ at launch, self-declared at sign-up and set as the App Store minimum age. It may be lowered to 16+ later, once moderation has a track record.
- Price: v1 is free with no ads and no purchases. Ads and a paid no-ads plan come only after the whole app is complete. That later step puts the data collection of an ad SDK into the App Store privacy labels and makes the owner a trader under EU rules.
- Rollout: Japan storefront first. Other storefronts follow in waves. EU and UK come after a privacy-law check and the trader decision. China mainland is excluded until the government-filing question is answered. Worldwide availability is the goal.
- Purposes a user can select: Discovery and Collaboration. Opportunity mode, recruiters and career features are a later mode, out of v1.

## 2. Profile, accounts and links

### Accounts

- Sign in with Apple is required in the release build.
- Anonymous accounts exist only in development builds, as a temporary sign-in that is compiled out of the release build. The friends test in **Build, test and release path** uses it.
- GitHub is connected as a linked identity for verification. It is not a way to sign in.
- Rationale: a durable identity is what makes blocks, removals, the 18+ declaration and account deletion hold. An anonymous install can be reset by reinstalling.

### Profile

Profile fields: display name, self-introduction written by the user, interests, purposes, links, and one optional contact detail.

- **DEFAULT:** display name up to 30 characters, self-introduction up to 200 characters.
- **DEFAULT:** interests are chosen from a fixed curated list. No free-text interests in v1.
- **DEFAULT:** no uploaded avatar in v1. The card shows an initial-letter avatar, as the concept screens do.
- **DEFAULT:** up to 10 links per user.

Discovery is off by default. Turning it on requires a display name, a self-introduction, at least one interest and at least one link of any kind.

### Link sources in v1

| Source | How it is read | Automatically filled fields |
|---|---|---|
| GitHub repositories | Official GitHub API after the user connects their account. The user picks from their own public repositories. | Name, description, main language, first lines of the README. |
| Qiita articles | Official Qiita API v2. The user enters their Qiita username once and picks from their own articles. | Title, tags, opening lines. |
| Zenn articles | Official per-user RSS feed. The user enters their Zenn username once and picks from their own articles. | Title, opening lines. |
| Other pages, such as a portfolio or another blog | One fetch of the page, reading only its title and preview description (Open Graph). | Title, preview text. |

### Rules for links

- **UNVERIFIED:** whether the Zenn feed carries the opening text of each article. If it does not, the preview description of the article page fills that field.
- No scraping of page bodies. Only the title, source, tags and roughly the first 200 characters are stored. The original stays on its platform and the link opens the original.
- The owner of a link previews and can edit every automatically filled field before sharing, and can refresh it on demand.
- Verification: a GitHub link is verified by connecting the account. Any other link counts as verified when it sits under an address listed on that verified GitHub profile (its website or social links), or when the linked GitHub ID of the Qiita account matches. Everything else is labelled unverified and can be reported as impersonation.
- Build order of the readers: GitHub first (it alone is enough for the friends test), then Qiita and Zenn, then other pages. All of them land before public release.
- There is no AI anywhere in the product. Remove every mention of Gemini, AI summaries, AI consent and AI settings. The automatic link reading above replaces them.
- The app does not host portfolios, repositories, articles, documents or resumes. This is unchanged from v0.2.

## 3. Encounters

Definition: an encounter is co-presence of at least 2 minutes within Bluetooth range.

- This is a hard threshold for ambient encounters. An ambient contact shorter than 2 minutes is discarded, so someone walking past cannot collect a card.
- Only when both users are in a session does an exchange count immediately. An exchange when only one user is in a session is ambient, requires 2 minutes and is revealed at the daily report.

### The ladder

All rungs operate at the same time. The app never switches modes.

| Rung | Device state or action | User effort | Status |
|---|---|---|---|
| 1 — Locked | Both phones locked, app in the background. | None. | Unproven, may not work at all, never promised. |
| 2 — Awake | At least one phone in use with another app in front. | None. | Unproven, measured separately from rung 1. |
| 3 — One open | At least one of the two has the app open. | One tap by one person. | The public promise. Expected to work by two independent paths, the open phone scanning and the open phone advertising. |
| 4 — Both open | Both have the app open. | One tap each. | Fastest. |
| 5 — Manual | One shows a QR code and the other scans it. | A few seconds together. | Always works, no Bluetooth. |

### Rules

- Public wording: promise rung 3. Describe rungs 1 and 2 as “may also work”.
- No beacons or other fixed hardware.
- No location in v1: never requested and never stored. An opt-in background boost in which on-device location wakes the app (nothing sent to the server, off by default) is to be revisited after the test matrix shows how rungs 1 and 2 perform on Bluetooth alone.
- No someone-is-nearby notifications or prompts of any kind.
- Symmetric rule: an encounter counts only when both phones take part, meaning both report the Bluetooth exchange, or one shows and the other scans a QR code.
- Force-quitting the app stops discovery until the app is reopened. Onboarding must say so.

### Sessions

- Started with a Start session button. A session lasts 2 hours or until the user stops it.
- A running session is shown as a Live Activity. A one-tap control (widget or Control Center control) can start one.
- Two users who are both in a session see each other immediately.

### Platform facts and unknowns

- **FACT** (Apple, Core Bluetooth Background Processing for iOS Apps): a backgrounded app advertises without its local name, and its service UUIDs move to an overflow area that only an iOS device explicitly scanning for them can discover. Advertising frequency may decrease. Background scanning coalesces duplicate discoveries and scans less often. An app woken in the background has around 10 seconds.
- **FACT:** an Apple engineer wrote on the Apple Developer Forums in July 2026 (thread 837516) that background advertising is best-effort and “slows or stops”, that tokens should be read over a connection and not carried in advertisements, and that an app the user force-quit is not relaunched.
- **UNVERIFIED:** whether two backgrounded iPhones discover each other at all. Sources conflict and nothing official settles it. Only the device tests can answer.
- **FACT:** a comparable App Store app, Twicon (AYcanD Inc., rated 16+, requires iOS 26), states in its own listing that an exchange is most likely with the app open, likely in the background, and unlikely after force-quit, and recommends keeping the app open to be sure. It asks for Always location permission and uses location as a trigger for background detection, which this product does not do. It adds a random delay before delivery so the person met is harder to identify. It had one rating, so it is not evidence of reliability.

## 4. Reveal and notifications

- Ambient encounters become visible, with names, only when the daily report arrives. The report comes at 21:00 local time by default and is skipped on days with no encounters. The user can change the time.
- The notification of the daily report may show names. The protection is the delay, not hiding names.
- Session encounters and QR encounters are revealed immediately.
- The release build has no immediate notification for ambient encounters.
- A demo switch that reveals and notifies ambient encounters immediately exists only in development and internal builds and is compiled out of the release build. The device tests use the same switch.
- There is no weekly digest.
- Rationale: revealing ambient encounters immediately would let a user learn in real time which nearby stranger is which person.

## 5. Privacy and safety

- The server never stores location.
- The server stores the date of an encounter, not its time. Times exist only inside unresolved candidates and are discarded when a candidate is confirmed or dropped.
- Unresolved candidates are dropped after 48 hours.
- Encounters are deleted automatically after 30 days, unless the viewing user has marked the encounter as a favorite. A favorite is kept for that viewer but always shows only what the other person currently allows.
- Deleting an encounter, or a block, by either person removes the encounter for both people, even if it was a favorite.
- Account deletion is done inside the app, and is immediate and permanent.
- Block, report and account deletion are all part of v1.
- A reported person is hidden from the reporter at once. A profile reported by 3 different users is hidden from everyone until the operator reviews it, which happens within 72 hours.
- **DEFAULT:** report reasons are spam, harassment or inappropriate content, impersonation, other.
- The operator is the owner, with a published contact address.
- New users see one clearly labelled sample encounter. It also gives App Review something to open.
- **DEFAULT:** the sample encounter exists only on the device, and the user can dismiss it.
- Users can also save individual link cards. **DEFAULT:** a saved link follows the same rules as a favorite. It shows only what the owner currently allows and disappears if the encounter is removed.

## 6. Matching and visibility

- **Eligible:** a confirmed encounter, discovery on for both people, and no block in either direction.
- **Compatible:** eligible, plus overlapping purposes, plus the interest threshold of each side met.
- **DEFAULT:** the interest threshold defaults to 1 shared interest and is adjustable by the user.
- Three visibility levels: everyone eligible, compatible only, private. The v0.2 mutual connections level is removed together with connection requests.
- Defaults: once discovery is on, the display name, self-introduction and interests are visible to everyone eligible. A link has no default level, so the user must choose one when adding it. The contact detail is private by default.
- Matching never hides an encounter. It only orders the feed and gates the compatible-only fields.
- Current settings always apply, in both directions, including to past encounters.
- The server enforces all of this. A field the viewer may not see is never sent to the app.
- `design.md`, **Matching and visibility**, publishes a truth table covering the discovery switches of both users, blocks, purposes, interest thresholds and each visibility level.

## 7. Scope of v1

- In: discovery, profile and links with automatic filling, the three visibility levels, the encounter feed, favorites and saved links, the daily report, sessions, QR exchange, block, report, account deletion, and the sample encounter.
- Out of v1: Opportunity mode and recruiters, AI summaries, connection requests, the mutual connections level, the weekly digest, immediate ambient notifications, private messaging, organization verification, recruiting dashboards, semantic recommendations, an iPad-specific interface, and Android.
- Later: ads with a paid no-ads plan after the whole app is complete. A possible opt-in location background boost. A career mode. Android reusing the backend and the Bluetooth protocol.

## 8. Build, test and release path

### Stages

Each stage gates the next.

1. **Toolchain check. UNVERIFIED:** whether `swift test` and `xcodebuild` run inside the sandbox that the implementing agent uses on this Mac. The first unit of work proves it.
2. **Bluetooth engine first,** built inside the real app with a diagnostics screen. Then a one-day check of rungs 3 and 4 on real devices, with made-up identities, no backend, and logs kept on the devices.
3. **Basic functions.** Then the 160-trial matrix, using a borrowed second iPhone.
4. **Friends test:** 3 to 5 friends in a small room or cafe, on the free Apple account. That means cable installs from the Mac of the owner, builds that stop working after about a week, the temporary anonymous sign-in, sessions for immediate results, and the daily report viewed inside the app without a notification. The GitHub reader alone is enough. If the device cap of the free account is reached, the phone of a friend can be signed with the own free Apple ID of that friend.
5. **Join the Apple Developer Program.** Add and verify Sign in with Apple, push notifications and TestFlight.
6. **One real event with 20 or more people,** distributed through TestFlight.
7. **One professional review of the privacy policy and terms,** in Japanese and English. Then public release in Japan.
8. **Later storefronts in waves,** as in **Product**.

### The 160-trial matrix

- Rungs 1 to 4, on two device pairs (iPhone with iPad, iPhone with iPhone), 20 stationary trials each, 160 trials in total.
- 10-second and 30-second passes are recorded for information only.
- Measured: the time to complete the two-way token exchange, and whether both phones can confirm two minutes of continued presence.
- Pass mark: rung 3 confirms an encounter within 5 minutes in at least 90 percent of trials.
- Rungs 1 and 2 are reported with no pass mark. Their results only decide how the app describes them.
- Battery: at most 5 percentage points extra over 8 hours with discovery on, compared with discovery off.
- If rung 3 fails, stop and rethink, because only the QR rung would remain.
- Twenty trials cannot tell 90 percent from 80 percent with confidence. The result is a go or no-go signal, not a measured rate.
- Procedure rules: run detached from the debugger. Record the iOS and build versions. Reset state between trials and bound the lifetime of pending connections so one trial cannot contaminate the next. Record discovery, exchange completion and confirmation times separately.

Devices: an iPhone 15 and an iPad (10th generation) owned by the owner, and a second recent iPhone borrowed before the matrix. An iPhone-with-iPad result does not establish iPhone-with-iPhone behaviour.

### Free Apple account limits

- **FACT,** from Apple engineer forum replies and older third-party sources: no TestFlight or App Store distribution, builds expire after about a week, and push notifications are not available.
- **UNVERIFIED:** Sign in with Apple is probably also unavailable on a free account.
- **UNVERIFIED:** older sources report a cap of about 3 registered devices. The current number was not confirmed.

### Compliance deliverables

All are owned by the owner:

- Privacy policy and terms in Japanese and English.
- App Store privacy labels.
- The Bluetooth purpose string.
- In-app account deletion.
- A review demonstration: the sample encounter plus review notes.
- A published moderation contact.
- A data-flow description covering Supabase and its hosting region for the Japanese privacy-law assessment.

## 9. Stack, tools and workflow

### Languages

- Front end: Swift, with SwiftUI for the screens.
- Back end: TypeScript for the Supabase Edge Functions, and SQL for the PostgreSQL schema, access rules and server functions.
- Website: plain HTML for the privacy policy, terms and support pages, which the App Store requires as URLs.

### iOS app

- Minimum iOS 26.0. Built with Xcode 27.0 and Swift 6.4.
- Core Bluetooth for discovery. Rationale: it is the only Apple framework that works in the background between strangers without pairing, and an Android app can speak the same protocol later.
- SwiftData for local storage. The queue of pending receipts sits behind its own interface so it can move to SQLite if background writes misbehave.
- CryptoKit and the Keychain for the temporary tokens.
- A Live Activity for sessions, and a one-tap control to start one.
- Camera QR scanning for rung 5.

Three build kinds:

| Build | Distribution | Included development features |
|---|---|---|
| Development build | Run from the Mac of the owner. | Anonymous sign-in, the demo switch and the diagnostics screen. |
| Internal build | Distributed to the own testers of the owner through TestFlight. | The demo switch and diagnostics. |
| Release build | The App Store version. | None of those three features is compiled in. |

### Back end

- Supabase on the free plan: Auth (native Sign in with Apple, and linking a GitHub identity to a signed-in user), PostgreSQL, Edge Functions, and Supabase Cron for the daily report and the retention jobs.
- APNs for the daily report notification.
- Visibility is enforced through server functions that return only authorized fields. Direct table access from the app is denied by default.
- **FACT:** Supabase pauses a free-plan project that shows low activity over a 7-day period. Paid projects are not paused. Risk: a quiet week after release could take the app offline until the owner restores it by hand.
- **FACT:** Supabase labels manual identity linking and Supabase Cron as beta.
- **FACT:** GitHub documents that an OAuth app with no scope gets read-only access to public information, and that the endpoint `GET /users/USERNAME/social_accounts` is public. Qiita API v2 allows 1,000 requests per hour authenticated and 60 per hour per IP address unauthenticated, lists the articles of a user at `GET /api/v2/users/USER_ID/items`, and exposes a linked GitHub ID on user objects. Zenn documents a per-user RSS feed at `https://zenn.dev/USERNAME/feed`, limited to about 20 items unless the query parameter `all=1` is added.

### Repository and tools

- One repository with the directories `ios`, `supabase` (database migrations and Edge Functions), `site` and `docs`.
- App code lives in local Swift packages with a thin app target on top, so most logic builds and tests with `swift test` without a simulator.
- The Xcode project file is generated from a text file by XcodeGen. Nobody edits the project file by hand.
- Every unit of work has terminal checks: `swift test`, `xcodebuild` on the simulator, `deno test`, and the local database tests of Supabase.
- On the Mac of the owner: macOS 27.0.1, Xcode 27.0 with the iOS 27.0 SDK and simulator, Swift 6.4, Homebrew, the Supabase CLI, Docker, Node and the Codex CLI. XcodeGen and Deno are approved and will be installed when implementation starts. The VS Code Swift extension is to be added.

### Workflow

- The owner develops in VS Code with cross-harness: one agent plans and reviews, another implements. Work is split into units. Each unit becomes one commit on a work branch, and the owner merges.
- The simulator has no Bluetooth. Therefore the Core Bluetooth calls sit behind an interface. The encounter logic (the 2-minute rule, token rotation, the both-phones-report rule) is tested automatically against a fake. Only radio behaviour is verified on real devices, by the owner, using the diagnostics screen and a written test sheet.
- Things that need Xcode itself or the hands of the owner: signing in the Apple ID for code signing, every real-device Bluetooth trial, battery measurements, and the App Store submission screens.

## 10. Technical design inputs

These inputs come from an independent review of the v0.2 documents and belong in `design.md`. Items marked **DEFAULT** are starting values that the one-day check and the matrix may change.

### Bluetooth transport

- One fixed application service UUID. Every phone acts as both peripheral (advertising that service) and central (scanning for exactly that service).
- Tokens are never placed in advertisements. After discovery the central connects, reads the current token of the peripheral from one characteristic, and writes its own current token to another. One connection therefore gives both phones the token of the other.
- Characteristics carry a protocol version so the format can change.
- **DEFAULT:** tokens are random, issued by the server in batches, each valid for a 15-minute window, and are the only identifier exchanged. No account ID, name, GitHub handle, email or link is ever sent over Bluetooth.
- **DEFAULT:** a phone confirms two minutes of continued presence either by keeping the connection and reading again after two minutes, or by a second exchange with the same peer at least two minutes after the first. Which of these works in the background is a question for the one-day check.
- Define connection timeouts, teardown, and what a one-sided result means. When one phone holds a receipt and the other does not, it stays a candidate and is dropped after 48 hours.

### Confirmed encounter, security definition

- A receipt names the two tokens, a per-exchange nonce, whether the phone was in a session, and the observed duration.
- The server confirms a Bluetooth encounter only when it holds matching receipts from both phones, both tokens were valid for their windows, the receipt is fresh, and it has not been used before (replay rejection).
- Ambient: confirmed only when the two-minute rule is met. Session: confirmed immediately when the own record of the server shows both users had an active session. QR: confirmed immediately when the scanning phone uploads, before expiry, a short-lived one-time code that the showing phone obtained from the server while signed in; both accounts took part and no receipts are involved.
- Even a correct exchange can be relayed by an attacker, so a confirmed Bluetooth encounter is evidence of a Bluetooth interaction and not cryptographic proof of physical distance. Signal strength is only a rough range indicator.
- Rate-limit receipt uploads and encounter resolution per account.

Encounter states for `design.md`, **Encounter states**: Observed (a discovery callback), Exchanged (tokens swapped), Candidate (receipt uploaded), Confirmed, Revealed. These replace the v0.2 list.

### Background lifecycle and storage

- Opt in to Core Bluetooth state preservation and restoration, and define how the central and peripheral managers are rebuilt, how an interrupted exchange is handled, and how tokens rotate while the app is suspended.
- Receipts are queued on the device and uploaded later when the network is available.
- Storage and Keychain items that the background path needs must be readable while the phone is locked after its first unlock. Before the first unlock after a reboot nothing works. Document that as a limitation and test it separately.
- Do not rely on BGTaskScheduler for continuous scanning or deterministic wake-ups. This is unchanged from v0.2.

### Retention and deletion contract

State separately how long each of these is kept and what deletes it: on-device diagnostics, receipts on the device, candidates on the server, token batches, confirmed encounters, favorites, reports, and push tokens.

- **DEFAULT:** development-build diagnostics are kept 7 days.
- **DEFAULT:** reports are kept until resolved and then for a period the privacy policy will state.
- Removing access cannot retract an external URL a reader has already copied.

### Fetching other pages

The fourth link reader is the only part that fetches arbitrary URLs, so it carries the server-side request forgery protections:

- HTTPS only.
- Reject URLs carrying credentials.
- Resolve the host and refuse private, loopback and link-local addresses, including IPv6.
- Re-check every redirect.
- Limit response size and time.
- Accept only HTML.
- Read only the title and preview description.
- Treat everything fetched as untrusted text.
- Note the residual risk that the address can change between the check and the fetch, and test redirect and rebinding cases.

The GitHub, Qiita and Zenn readers call only fixed hosts.

### Daily report delivery

A scheduled job runs at a regular interval, selects users whose local time has reached their report time, marks the confirmed ambient encounters of that day as revealed, and sends the notification. Define the time-zone handling and the push-token lifecycle.

## 11. User interface

The UI document is new: `ui.md`, version 0.1.

- Start from the six concept screens in `proposal.pdf` (pages 3 to 5). Keep their teal accent on a light background and their card layout. Build with standard iOS components, with light and dark modes and Dynamic Type.
- A tab bar at the bottom of the screen with three tabs: Discover, Profile, Settings.
- The Connections tab of the concept is removed, because connection requests are out of v1. The My links tab of the concept becomes Profile, because the name, self-introduction and interests live there too.
- Removed from the concept screens: the Request a connection button, the Mutual connections level, the Allow AI processing toggle, and both AI screens.
- Added: Start session, the active session screen, and QR exchange.
- The Settings tab opens a plain list that leads to the seven settings screens. That list is described in `ui.md`, **Navigation**, and is not one of the numbered screens.

### The 26 screens

The identifiers are fixed.

| Area | ID | Screen |
|---|---|---|
| Onboarding | S01 | Welcome and sign-in (includes the 18+ declaration and acceptance of the terms and privacy policy). |
| Onboarding | S02 | Profile basics (display name, self-introduction). |
| Onboarding | S03 | Interests and purposes. |
| Onboarding | S04 | First link. |
| Onboarding | S05 | Permissions and turning discovery on (Bluetooth permission, what is promised and what is not, the force-quit note). |
| Discover tab | S06 | Feed, grouped by day (with Start session, QR exchange and the favorites filter). |
| Discover tab | S07 | Encounter detail (the card of the other person). |
| Discover tab | S08 | Active session. |
| Discover tab | S09 | QR exchange (show and scan). |
| Discover tab | S10 | Favorites (favorite encounters and saved links). |
| Profile tab | S11 | My card, as others see it. |
| Profile tab | S12 | Edit profile. |
| Profile tab | S13 | Links list. |
| Profile tab | S14 | Add link (choose GitHub, Qiita, Zenn or another page, connect or enter the username, pick items). |
| Profile tab | S15 | Edit link (the automatically filled fields, and visibility). |
| Settings tab | S16 | Discovery and matching. |
| Settings tab | S17 | Visibility. |
| Settings tab | S18 | Daily report (time, notification on or off). |
| Settings tab | S19 | Blocked users. |
| Settings tab | S20 | Account (sign out, delete account). |
| Settings tab | S21 | Legal and support. |
| Settings tab | S22 | Diagnostics (development and internal builds only). |
| Shared states | S23 | Bluetooth off or permission denied. |
| Shared states | S24 | Discovery off. |
| Shared states | S25 | Empty feed with the sample encounter. |
| Shared states | S26 | Report and block. |

For each screen `ui.md` gives: its purpose, how the user reaches it, a text sketch of the layout, its elements, its empty, loading and error states, where each action leads, and the Japanese and English wording of its key labels.

`ui.md` also describes the surfaces outside the app: the daily report notification, the session Live Activity, and the one-tap control that starts a session.

**DEFAULT:** an encounter card in the feed shows the display name, the shared interests, the first visible link card, a verified or unverified label per link, how the two met (ambient, session or QR), and the day. It never shows a time or a place.

## 12. Verified sources

| Source | URL |
|---|---|
| Apple, Core Bluetooth Background Processing for iOS Apps | https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html |
| Apple Developer Forums thread 837516 (July 2026) | https://developer.apple.com/forums/thread/837516 |
| App Store listing for Twicon | https://apps.apple.com/jp/app/id6781988066 |
| GitHub, Scopes for OAuth apps | https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps |
| GitHub, Social accounts API | https://docs.github.com/en/rest/users/social-accounts |
| Qiita API v2 documentation | https://qiita.com/api/v2/docs |
| Zenn, RSS feeds | https://zenn.dev/zenn/articles/zenn-feed-rss |
| Supabase, Project pausing | https://supabase.com/docs/guides/platform/free-project-pausing |
| Supabase, Login with Apple | https://supabase.com/docs/guides/auth/auth-apple |
| Supabase, Identity linking | https://supabase.com/docs/guides/auth/auth-identity-linking |
| Supabase, Scheduling Edge Functions | https://supabase.com/docs/guides/functions/schedule-functions |
| App Store Connect Help, EU Digital Services Act compliance information | https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-compliance-information/ |
| Apple Developer Forums, free account code signing | https://developer.apple.com/forums/thread/838074 |

## 13. Open and unverified items

- The trademark registry search for **すれちがいエンジニア** and **Engineer Encounters**.
- Whether two backgrounded iPhones discover each other at all.
- Whether the Zenn feed carries the opening text.
- Whether `swift test` and `xcodebuild` run inside the sandbox of the implementing agent.
- Whether Sign in with Apple is available on a free Apple account, and the current device cap.
- Whether a foreign developer needs a government filing number for the China mainland storefront. Sources conflict.
- Whether a solo developer with a free, ad-free app counts as a trader under EU rules.
- The exact retention period for resolved reports.
