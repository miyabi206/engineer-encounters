# Decisions — Engineer Encounters

**Version:** 0.6\
**Status:** Confirmed product decisions; drafting defaults and unverified items labelled\
**Date:** 2026-10-12\
**Related:** `specification.md` v0.6, `design.md` v0.6, `ui.md` v0.4\
**Platforms:** iOS first, Android later\
**Languages:** Japanese, English

Unmarked items are binding product decisions. **DEFAULT** marks a value chosen to fill a gap during drafting, not a decision made by the product owner. **UNVERIFIED** marks an unresolved claim that must not be presented as fact. **FACT** retains the evidence marking in the decision brief.

## 0. Glossary

- **Encounter:** two users were within Bluetooth range of each other and the app recorded it under the rules in **Encounters**.
- **Ambient encounter:** a Bluetooth encounter in which at least one of the two people was not in a session. A QR encounter is never ambient.
- **Session:** a time-boxed period a user starts on purpose with the Start session button.
- **Session encounter:** an encounter between two users who were both in a session.
- **QR encounter:** an encounter created by one user scanning the QR code of the other.
- **Ladder:** the five ways an encounter can be recorded, ordered by how much the users must do. Each one is a rung.
- **Exchange:** one Bluetooth connection in which the two phones swap temporary tokens in both directions.
- **Receipt:** the record one phone keeps of an exchange, uploaded to the server.
- **Candidate:** an uploaded receipt the server has not yet confirmed.
- **Confirmed encounter:** for a Bluetooth encounter, the server holds matching receipts from both phones and the rules in **Encounters** are met. For a QR encounter, the showing phone obtained a short-lived one-time code from the server while signed in and the scanning phone uploaded that code before it expired, so both accounts took part and no receipts are involved.
- **Revealed encounter:** a confirmed encounter that a user is now allowed to see. Each of the two users reaches this at their own daily report, so one may see the other before the reverse. This follows from the decision that each user can change their report time.
- **Daily report:** the once-a-day moment when the ambient encounters of that day are revealed, with a notification.
- **Card:** what one user sees of another, meaning the authorized profile fields and link cards.
- **Link card:** one shared link with its automatically filled title or name, description, main language, source, tags and opening or preview text, where available.
- **Link reader:** the server component that reads one kind of source (GitHub, Qiita, Zenn, other pages).
- **Eligible and compatible:** defined in **Matching and visibility**.
- **Discovery:** the master switch for product discovery and card eligibility. Token issue and discovery-off confirmation follow **Accounts**.
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

The dated owner decision retains its original prospective wording; the FACT record below states today's implementation.

**Owner decision — token prerequisite, 2026-10-12 (binding):** planned token issue will require a signed-in account, recorded 18+ declaration and acceptance of terms and privacy policy, and a valid registered time zone; discovery on will not be required. Accepted consequence: discovery-off accounts can have encounters confirmed and stored as dates only, becoming visible if both people later turn discovery on within retention, subject to reveal and current authorization. No Unit 3 function creates links, so the app cannot turn discovery on before Unit 5. Requiring discovery for token issue remains an owner open item to revisit once onboarding and link flows exist. See `design.md`, **Unit 3 contract** for the built server/client detail.

**FACT — Unit 3 built, 2026-10-12:** Development temporary anonymous sign-in, declarations, own-account RPCs, server token issue and receipt upload/resolution are implemented through `37ed0dc`. Auth/Data API uses SQL RPC with protected private tables and current-visibility card authorization. Local Supabase anonymous sign-in is enabled; environment limits are in **Open and unverified items**. The code-derived wire, limits, locks, replay, cleanup and app recovery contract is in `design.md`, **Unit 3 contract**. Restoring an account has no sign-in control; only not-authenticated automatically signs out. Switching accounts requires sign-out then sign-in; the built sign-out is a diagnostics action in Development/Internal. Stored sessions, server tokens and receipts are bound to backend/account; unbound or foreign stores are quarantined before network/radio use. A stored session is identified as belonging to another backend or account only from the record kept with its credential in the Keychain; stale or unreadable preferences never establish a mismatch or initiate deletion. The prepared-binding lease is in memory, and account-derived storage names use HMAC-SHA-256 keyed with the per-installation salt. A durable non-secret sign-out marker prevents failed credential deletion from restoring an account or allowing new sign-in; pending credential deletion is retried on its own on restore/refresh without tearing down the runtime. Refresh during sign-in or sign-out does not discard the new session. When Keychain is unavailable no stored session is available; while the binding is not ready no backend call is attempted and the runtime reports storage unavailable, retrying preparation on the next refresh. Each build kind reads its own backend settings; only Development allows non-HTTPS/local networking. Apple sign-in remains Unit 7.

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
- No scraping of page bodies. Store only title or name, description, main language, source, tags, and roughly the first 200 characters of opening or preview text. Nothing else from the source is stored. The original stays on its platform and the link opens the original.
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
| 1 — Locked | Both phones locked, app in the background. | None. | Unproven, may not work at all, never promised. **FACT:** neither approach produced two-minute evidence while both devices stayed locked on the iPhone 15 and iPad (10th generation) pair in the 2026-10-11 check. |
| 2 — Awake | At least one phone in use with another app in front. | None. | Unproven. **UNVERIFIED:** not tried on 2026-10-11; measured separately from rung 1, never promised. |
| 3 — One open | At least one of the two has the app open. | One tap by one person. | The public promise. Expected to work by two independent paths, the open phone scanning and the open phone advertising. **FACT:** both presence approaches worked in both device orientations on the iPhone 15 and iPad (10th generation) pair on 2026-10-11; the held connection with iPad locked was a continuation, not a clean reset-then-lock trial. The matrix remains the release gate. |
| 4 — Both open | Both have the app open. | One tap each. | Fastest. **FACT:** both presence approaches worked on the iPhone 15 and iPad (10th generation) pair on 2026-10-11. |
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
- **FACT:** the owner’s 2026-10-11 check used an iPhone 15 and an iPad (10th generation), Development builds and local test tokens, without a backend or account. In the trials with one app open the locked device completed its part on time; in most of them its step followed contact from the open device within seconds, which is consistent with the open device waking it (an inference from timing, not logged); in the second-exchange trial with the iPhone locked, the locked iPhone made its second connection on its own at about 125 s, about ten seconds before the iPad made its own. With both locked, neither approach produced two-minute evidence until a device was woken: a suspended app gets no timer. First exchanges happened just after Reset, before both devices were backgrounded.
- **UNVERIFIED:** discovery between two backgrounded devices, including two iPhones, was not tested. Sources conflict and nothing official settles it. Rung 2 was not tried. Rungs 1 and 2 remain unproven and never promised; this pair does not establish iPhone-with-iPhone behaviour.
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
- Account deletion is available inside the app and is immediate and permanent for all personal data, with one safety exception: the server keeps only a one-way hash of the Apple account identifier together with operator moderation outcomes and the blocks other people placed on that account, for a period the privacy policy states, and re-applies them if the same Apple identity signs up again. Nothing else survives. The hash cannot be turned back into the Apple identifier; the kept record holds no name, profile field, link, token, encounter or contact detail. A block is dropped when the person who placed it deletes their own account. The privacy policy and the S20 deletion confirmation disclose this exception. The exact retention period is an open item to settle with the legal review.
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
- Defaults: once discovery is on, the display name, self-introduction, interests and purposes are visible to everyone eligible. A link has no default level, so the user must choose one when adding it. The contact detail is private by default.
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

1. **Toolchain check. FACT:** Unit 1 is implemented and merged to main (pull request 2). The sandbox question is resolved: Swift package checks pass with local cache paths and `--disable-sandbox`; Xcode and Supabase checks run outside that sandbox in the tester role. See **Repository and tools**.
2. **Bluetooth engine first. FACT:** Unit 2 is implemented and merged to main (pull requests 4 and 5), with the real app and S22 diagnostics. The owner completed the one-day check on 2026-10-11 with an iPhone 15 and an iPad (10th generation), Development builds, local test tokens, no backend and no account. Rungs 3 and 4 worked with both approaches in both orientations, with the trial limitation below; unrun trials remain open.
3. **Basic functions.** Follow the Unit 3 allocation under **User interface** and the built contract in `design.md`, **Unit 3 contract**, then complete Units 4 and 5 before the 160-trial matrix, using a borrowed second iPhone. **FACT:** the three binding owner decisions of 2026-10-11 were implemented on 2026-10-12; device verification remains open before the matrix; see **Bluetooth transport**.
4. **Friends test:** 3 to 5 friends in a small room or cafe, on the free Apple account. **DEFAULT:** the friends test uses development builds pointed at a hosted non-production Supabase project, because the phones leave the owner's Mac. For the later hosted test, enable anonymous sign-in only on that non-production project and disable it on production, in addition to being compiled out of the release build. Local Supabase is for automated checks and the owner's own development. That means cable installs from the Mac of the owner, builds that stop working after about a week, the temporary anonymous sign-in, sessions for immediate results, and the daily report viewed inside the app without a notification. The GitHub reader alone is enough. If the device cap of the free account is reached, the phone of a friend can be signed with the own free Apple ID of that friend.
5. **Join the Apple Developer Program.** Add and verify Sign in with Apple, push notifications and TestFlight.
6. **One real event with 20 or more people,** using a TestFlight build made with the release configuration against the production backend. No demo switch, diagnostics or anonymous sign-in is included; attendees sign in with Apple. Verify these build gates and normal daily reveal and notification timing before the event. Internal builds, which keep the demo switch and diagnostics, go only to the owner's own devices.
7. **One professional review of the privacy policy and terms,** in Japanese and English. Then public release in Japan.
8. **Later storefronts in waves,** as in **Product**.

**FACT — one-day radio check, 2026-10-11:** the owner used an iPhone 15 and an iPad (10th generation), Development builds and local test tokens, with no backend or account. Values are seconds from trial start (Reset). Each device records two evidence values per trial, one per role; each row gives the iPhone values, then the iPad values. The two devices start their trial clocks at their own Reset, so values for the same exchange differ slightly between devices. A trial counts only when both devices show two-minute evidence for the same exchange digest.

| Presence approach | Device state | Result |
|---|---|---|
| Held connection | Both open | Evidence: iPhone 124.4 and 127.5 s; iPad 129.0 and 132.2 s. |
| Held connection | iPad open, iPhone locked | Evidence: iPhone 122.6 and 123.8 s; iPad 121.4 and 122.7 s. |
| Held connection | iPhone open, iPad locked | Evidence: iPhone 256.8 and 261.2 s; iPad 261.3 and 265.9 s, only as a continuation of the both-open trial without Reset; not a clean reset-then-lock trial. |
| Held connection | Both locked | First exchanges at about 2.3 s; checkpoint only after waking a device at about 255 s, observed duration 252.7 s. A repeat gave the same result. |
| Second exchange | Both open | Evidence: iPhone about 124.4 s for both exchanges; iPad about 124.4 s for both exchanges. |
| Second exchange | iPad open, iPhone locked | Evidence: iPhone 125.2 and 136.8 s; iPad 123.6 and 135.3 s; the locked iPhone reconnected on its own at 125 s. |
| Second exchange | iPhone open, iPad locked | Evidence: iPhone 126.1 and 133.0 s; iPad 127.4 and 134.4 s. |
| Second exchange | Both open, about 2 m apart for 10 minutes | Evidence at about 123.5, 256.3, 389.9 and 522.9 s; no failed or disconnected attempt. |
| Second exchange | Both locked | First exchanges at about 1–2 s; no second exchange while locked. Waking a device after about 310 s ended attempts as expired at the 5-minute bound, without evidence. Fresh exchanges after waking gave evidence at about 445 s. |

Before the unsubscribe fix, both devices reached evidence at about 123–132 s, then every central attempt failed about every 10 s. The physical link stayed up after app-level cancellation, so the peer saw no new subscription. Pull request 5 fixed unsubscribe-before-cancel and read admission for a still-subscribed central. The table records the check after that fix.

The owner also saw connections beyond 10 m, without a log; Bluetooth range is not a distance guarantee. After Reset, one direction often had a failed central attempt at about 1–2 s and completed the first exchange about 10 s later, attributed to the then-current 5-second refusal rule. **FACT — fake transport test, 2026-10-12:** `testCentralReturningAfterOwnResetCompletesFirstExchangeImmediatelyAfterALongAttempt` shows that under held connection a central returning right after its own Reset, more than 5 seconds after its previous attempt began, completes a first exchange at once. Under second exchange, if the other phone still holds a waiting attempt (first exchange done, evidence not yet reached), it takes the returning link as that attempt’s reconnect. The returning central receives a reconnect-evidence frame where it expects an initial exchange, ends with an invalid frame and completes the first exchange after the 10-second backoff. The 2026-10-11 observation therefore has a second cause under second exchange which the refusal change does not remove. Removing it needs a protocol decision: undecided, not built. In second-exchange trials, S22 leaves the first exchange of a pair pending in an open trial because evidence is recorded under the second exchange digest (a closed trial shows missing instead).

The check ended on 2026-10-11 without a trial across a 15-minute token-window boundary, a real loss of contact and return, or iPhone with iPhone. Those remain **UNVERIFIED**, as do rung 2 and background-to-background discovery. The first exchange in both-locked trials happened immediately after Reset, so those trials did not test background discovery.

### The 160-trial matrix

- Rungs 1 to 4, on two device pairs (iPhone with iPad, iPhone with iPhone), 20 stationary trials each, 160 trials in total.
- 10-second and 30-second passes are recorded for information only.
- Measured: the time to complete the two-way token exchange, and whether both phones can confirm two minutes of continued presence.
- Pass mark: A rung-3 trial passes when both phones hold the two-minute presence evidence for the same exchange within 5 minutes of the start of the trial. Server confirmation time is recorded separately and is not part of the pass mark, because uploads may be deferred. At least 90 percent of rung-3 trials must pass.
- Rungs 1 and 2 are reported with no pass mark. Their results only decide how the app describes them.
- Battery: at most 5 percentage points extra over 8 hours with discovery on, compared with discovery off.
- If rung 3 fails, stop and rethink, because only the QR rung would remain.
- Twenty trials cannot tell 90 percent from 80 percent with confidence. The result is a go or no-go signal, not a measured rate.
- Procedure rules: run detached from the debugger. Record the iOS and build versions. Reset state between trials and bound the lifetime of pending connections so one trial cannot contaminate the next. Record per-trial elapsed values for discovery, exchange completion, two-minute evidence and server confirmation separately.

Devices: an iPhone 15 and an iPad (10th generation) owned by the owner, and a second recent iPhone borrowed before the matrix. An iPhone-with-iPad result does not establish iPhone-with-iPhone behaviour.

### Free Apple account limits

- **FACT,** from Apple engineer forum replies and older third-party sources: no TestFlight or App Store distribution, builds expire after about a week, and push notifications are not available.
- **UNVERIFIED:** Sign in with Apple is probably also unavailable on a free account.
- **UNVERIFIED:** older sources report a cap of about 3 registered devices. The current number was not confirmed.

### Compliance deliverables

All are owned by the owner:

- Privacy policy and terms in Japanese and English, disclosing the account-deletion safety exception and its retention period.
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
| Internal build | TestFlight only to the owner's own devices. | The demo switch and diagnostics; Apple sign-in remains Unit 7, no anonymous sign-in. |
| Release build | App Store; TestFlight for the 20-person event, made with the release configuration against the production backend. | Apple sign-in remains Unit 7; anonymous sign-in, the demo switch and diagnostics are all compiled out. |

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
- Every unit of work has the applicable terminal checks: `swift test`, `xcodebuild` on the simulator, `deno test`, and the local database tests of Supabase. **FACT:** `xcodegen`, `xcodebuild`, app-hosted tests, `ios/Tests/check-release-artifact.sh` and every Supabase command do not run in the implementing agent’s sandbox; the tester role runs them outside it.
- On the Mac of the owner: macOS 27.0.1, Xcode 27.0 with the iOS 27.0 SDK and simulator, Swift 6.4, Homebrew, the Supabase CLI, Docker, Node and the Codex CLI. **FACT:** XcodeGen and Deno are installed. The VS Code Swift extension is to be added.

**FACT:** plain `swift test` fails on the module-cache path inside the implementing agent’s sandbox. This form passes there, with `<Package>` replaced by the package name:

```sh
env XDG_CACHE_HOME=$PWD/.build/sandbox/xdg CLANG_MODULE_CACHE_PATH=$PWD/.build/sandbox/clang SWIFTPM_MODULECACHE_OVERRIDE=$PWD/.build/sandbox/manifest swift test --disable-sandbox --package-path ios/Packages/<Package> --cache-path $PWD/.build/sandbox/swiftpm-cache --config-path $PWD/.build/sandbox/swiftpm-config --security-path $PWD/.build/sandbox/swiftpm-security --manifest-cache local
```

The same environment and cache options with `swift build --triple arm64-apple-ios26.0-simulator --sdk <iPhoneSimulator SDK path>` compile iOS-only code there. `ios/Scripts/typecheck-app.sh Development`, `Internal` or `Release` type-checks the app without `xcodebuild`; only Development also type-checks the hosted tests. EncounterBluetooth declares macOS, so `swift test --package-path ios/Packages/EncounterBluetooth` runs on the Mac (use the cache options above in the sandbox). In the documented unsigned simulator test command, the real Keychain round-trip test is skipped on `errSecMissingEntitlement`. The receipt file-protection assertion is an iOS-only package test, absent from that scheme’s simulator test action; locked-device protection still requires device validation.

### Workflow

- The owner develops in VS Code with cross-harness: one agent plans and reviews, another implements. Work is split into units. Each unit becomes one commit on a work branch, and the owner merges.
- The simulator has no Bluetooth. **FACT:** Unit 2 changed BluetoothTransport to radio commands and events, with the encounter engine owning the complete exchange, so the fake exercises the real protocol logic. The fake, paired-phones rig, manual clock and local confirmation check live in EncounterDomainTestSupport, which the app never links. The both-receipts check is a test oracle, not on-device confirmation; Unit 3 has built server resolution; S22 still has no confirmation measurement. Only radio behaviour is verified on real devices, by the owner, using S22 and a written test sheet.
- Things that need Xcode itself or the hands of the owner: signing in the Apple ID for code signing, every real-device Bluetooth trial, battery measurements, and the App Store submission screens.

## 10. Technical design inputs

These inputs originated in an independent review of the v0.2 documents and belong in `design.md`. Items marked **DEFAULT** are starting values that the matrix may change. Built Unit 3 server/client details are defined in `design.md`, **Unit 3 contract** rather than repeated here.

**Owner decision — review, 2026-10-12 (binding):** the owner confirmed the planned auth and database changes of Unit 3 and a security review of its diff before merge.

**FACT:** implementation and review are complete; see **Retention and deletion contract** in `decisions.md` for the review outcome.

**Defaults chosen during drafting (consistency review additions):**

| Area | Drafting default |
|---|---|
| Friends-test backend | Development builds use hosted non-production Supabase; planned hosted anonymous sign-in enabled only there, disabled on production and compiled out of release; local anonymous Auth is already enabled. Local Supabase is for automated checks and the owner's own development. |
| Unit 3 | **FACT:** built server, wire, schema and client contract, with tunable **DEFAULT** limits, is in `design.md`, **Unit 3 contract**; its three owner decisions are binding. |

### Bluetooth transport

- One fixed application service UUID. Every phone acts as both peripheral (advertising that service) and central (scanning for exactly that service).
- Tokens are never placed in advertisements. After discovery the central connects, reads the current token of the peripheral from one characteristic, and writes its own current token to another. One connection therefore gives both phones the token of the other.
- **FACT:** Unit 2 uses versioned exchange frames. The peripheral-token characteristic `7AEF0002` has read and notify; no value is ever notified. The central subscribes after discovering the characteristics. The peripheral treats subscription as connected and unsubscription as disconnected: Core Bluetooth supplies no other central connect/disconnect signal to a peripheral and no way for it to force a central off. The central unsubscribes before cancelling its link, waiting at most 1 second. A read at offset 0 from a still-subscribed central with no open logical link admits a new logical connection (pull request 5).
- No account ID, name, GitHub handle, email or link is ever sent over Bluetooth. This is a binding rule carried over from v0.2; only temporary tokens identify participants.
- Built token issue follows the binding prerequisite under **Accounts** and `design.md`, **Unit 3 contract**.
- **FACT:** Unit 2 built both presence approaches: held connection (接続を維持), with a checkpoint after at least 120 seconds, and second exchange (2回目の交換), completing another exchange at least 120 seconds after the first within the 5-minute attempt. The 2026-10-11 check showed rungs 3 and 4 working on the iPhone 15 and iPad (10th generation) pair, not reliable both-locked evidence or background discovery.
- **FACT:** BluetoothTransport in EncounterDomain is a radio-primitives interface. Commands: `startDiscovery`, `stopDiscovery`, `connect`, `read`, `write`, `disconnect`, `answerRead`, `answerWrite`. Events: `availabilityChanged`, `peerObserved`, `connected`, `connectFailed`, `frameRead`, `readFailed`, `writeAcknowledged`, `writeFailed`, `disconnected`, `incomingRead`, `incomingWrite`, `restored`. EncounterEngineCore is the deterministic synchronous core; EncounterEngine is its actor runtime. Unit 2 changed the planned transport-owned exchange to this engine-owned exchange so the fake tests the real protocol.
- **FACT:** Unit 2 implements a 10-second connect timeout, 5-second operation timeout, four active connection slots, a 5-minute presence-attempt bound and a 10-second duplicate-attempt backoff. These timings remain adjustable **DEFAULT** values except the binding 120-second ambient threshold. One-sided uploaded receipts remain candidates and expire after 48 hours; built server handling is in `design.md`, **Unit 3 contract**.

**Owner decisions — 2026-10-11:** all three are binding. **FACT:** implemented on 2026-10-12; these implementation prerequisites of the 160-trial matrix are done. Device verification and the borrowed second iPhone remain open.

- Use the second exchange as the default presence approach. Keep the held connection selectable in S22 until the matrix’s iPhone-with-iPhone trials confirm the choice. Reasons: both approaches passed rungs 3 and 4 on the tested pair; the engine gives a phone four connection slots and a held connection occupies one for two minutes per peer; the second exchange is the only approach with a possible route for locked phones. Accepted trade-off: it proves two completed exchanges at least 120 seconds apart, not continuous presence; leaving and returning within the 5-minute attempt still counts. **FACT — implemented on 2026-10-12:** EncounterEngineCore, EncounterEngine and EncounterRuntime default to the second exchange. S22 reads a missing or unrecognised stored value as second exchange; held connection stays selectable and a device that chose it earlier keeps that stored choice. Release has no S22 and uses second exchange. A phone on held connection and a phone on second exchange produce no two-minute evidence together (`testDifferentPresenceApproachesFailCleanly`); both S22 selectors must show the same approach before a trial.
- After two-minute evidence with a peer, start no new exchange with that peer for 15 minutes (one token window); Reset clears the pause. Reason: the 2026-10-11 check showed a pair repeating about every 131 to 133 seconds, indefinitely storing receipts and using the radio. A longer pause is impossible because the app keeps no lasting identifier of a peer. **FACT — implemented on 2026-10-12:** `EncounterProtocol.evidencePauseDuration` is 900 seconds. When an exchange this phone started (central role) reaches two-minute evidence, it starts no new outgoing attempt to that temporary peer handle until 900 monotonic seconds after that evidence. It does not refuse the peer: an incoming link from a paused handle is accepted and offered an initial exchange. Evidence reached only in the peripheral role sets no pause. The in-memory table is keyed by temporary peer handle, holds at most 256 entries and drops the oldest at capacity. Reset clears it on that phone only; turning the local participation switch off and on keeps it; process relaunch loses it. Paused peers stay out of the pending-peer table; after expiry a peer is dialled at its first observation at or after expiry, with no timer wake-up at expiry. With this code on both phones a pair no longer repeats every 131 to 133 seconds; one further cycle can occur in a direction that started late or failed because that phone has not yet reached evidence as central. **DEFAULT:** central-role-only scope is an implementation choice narrower than the owner’s 2026-10-11 wording, “after two-minute evidence with a peer”. The peripheral saves its receipt before the central receives the acknowledgement, so only the central knows both phones hold matching receipts; the handle a phone dials is the central-role handle. The owner has not yet confirmed this scope. **UNVERIFIED:** whether a backgrounded phone receives a new discovery so that it resumes after 15 minutes.
- Count the 5-second refusal of a returning central from the start of that central’s previous attempt, rather than its end. Reason: an attacker remains limited to one attempt per 5 seconds per handle, while an honest peer whose attempt lasted longer is accepted at once. **FACT — implemented on 2026-10-12:** a returning central is refused until 5 seconds after the start of its previous peripheral-role attempt when that attempt ended without evidence. An attempt lasting 5 seconds or longer leaves no refusal, so that central is accepted at once. A new incoming link that would supersede a still-connected stale attempt begun less than 5 seconds ago is disconnected instead of replacing it. The refusal table still holds at most 256 handles, dropping the oldest at capacity; Stop and Reset still clear it. The pause and refusal changes addressed distorted matrix measurements.

**UNVERIFIED:** asking iOS for the second connection after a delay with `CBConnectPeripheralOptionStartDelayKey` might let the system wake a locked phone. This is undecided and not built. Showing in S22 which first exchange an evidence entry completes is also undecided and not built.

### Confirmed encounter, security definition

- A receipt names the two tokens, a per-exchange nonce, whether the phone was in a session, and the observed duration. **FACT:** Unit 2’s held connection updates one receipt with a checkpoint token pair. The second exchange creates a second receipt with `priorExchangeNonce` equal to the first exchange’s nonce and the monotonic duration between exchanges; the first receipt is retained and marked final. Built Unit 3 server resolution is in `design.md`, **Unit 3 contract**.
- **FACT:** there is no on-device two-receipt confirmation. S22 shows only that device’s two-minute evidence and an exchange digest (the first 8 hexadecimal characters of SHA-256 of the exchange nonce); the owner compares both screens. The local confirmation harness is only a test check in EncounterDomainTestSupport.
- The server confirms a Bluetooth encounter only when it holds matching receipts from both phones, both tokens were valid for their windows, the receipt is fresh, and it has not been used before (replay rejection).
- Ambient: confirmed only when the two-minute rule is met. Session: confirmed immediately when the own record of the server shows both users had an active session. QR: confirmed immediately when the scanning phone uploads, before expiry, a short-lived one-time code that the showing phone obtained from the server while signed in; both accounts took part and no receipts are involved.
- Even a correct exchange can be relayed by an attacker, so a confirmed Bluetooth encounter is evidence of a Bluetooth interaction and not cryptographic proof of physical distance. Signal strength is only a rough range indicator.
- Rate-limit receipt uploads and encounter resolution per account.

Encounter states for `design.md`, **Encounter states**: Observed (a discovery callback), Exchanged (tokens swapped), Candidate (receipt uploaded), Confirmed, Revealed. These replace the v0.2 list.

### Background lifecycle and storage

- **FACT:** Unit 2 built AppComposition and EncounterRuntime around a persisted local participation switch, default off. No encounter Bluetooth manager is created before participation/storage readiness; explicit Bluetooth permission requests use a permission-only observer. App.init recreates the runtime when the flag is on, including background relaunches for Core Bluetooth state restoration; uncertain interrupted attempts are abandoned. The session flag source returns false until sessions exist.
- **FACT:** KeychainTokenBatchStore uses after-first-unlock, this-device-only accessibility. Development’s LocalTestTokenIssuer supplies a 12-hour batch of quarter-hour-aligned 15-minute windows. Signed-in builds use the server issuer; signed-out Internal/Release have no local issuer and cannot establish a new session before Unit 7. Built account integration is under **Accounts** and `design.md`, **Unit 3 contract**.
- **FACT:** per-configuration `EXCLUDED_SOURCE_FILE_NAMES`, anchored at the app source directory, and conditional compilation gate `ios/App/Development` to Development and `ios/App/Diagnostics` to Development and Internal. `ios/Tests/check-release-artifact.sh` builds all three configurations and checks marker names and string tables. Current Settings/diagnostics reachability is under **User interface**.
- Receipts are queued on the device; built upload/retry/terminal handling is in `design.md`, **Unit 3 contract**. **FACT:** SwiftDataReceiptQueue is a model actor storing each receipt’s Codable payload beside identity, sequence and expiry, with after-first-unlock file protection and a backup-excluded store directory. It bounds receipts and terminal-identity tombstones to 4,096 each, never returns expired receipts, and the engine invokes expiry on start, refresh and every 15 minutes while running.
- Storage and Keychain items that the background path needs must be readable while the phone is locked after its first unlock. Before the first unlock after a reboot nothing works. Document that as a limitation and test it separately.
- Do not rely on BGTaskScheduler for continuous scanning or deterministic wake-ups. This is unchanged from v0.2.

### Retention and deletion contract

State separately how long each of these is kept and what deletes it: on-device diagnostics, receipts on the device, candidates on the server, token batches, confirmed encounters, favorites, reports, and push tokens.

- **DEFAULT:** Development and Internal diagnostics are kept 7 days. **FACT:** Unit 2 prunes on launch, writes and Refresh; the specific clearing follow-up is listed under **Open and unverified items**. Logs contain dates, elapsed values and exchange digests, not identities or raw tokens.
- **DEFAULT:** reports are kept until resolved and then for a period the privacy policy will state, unless account deletion erases them; only operator moderation outcomes may survive under the safety exception in **Privacy and safety**.
- Removing access cannot retract an external URL a reader has already copied.

**FACT — Unit 2 security fixes, static review on 2026-10-11:** the unbounded adapter event stream, missing receipt expiry invocation, unbounded engine ledgers and trial log, missing own-token recheck at completion, and unbounded write fragments were fixed.

- Adapter: admission threshold of 256 queued events; at that threshold observations are dropped and new subscriptions are refused, while events for admitted work are always delivered (so this is not a hard cap on all events). At most 16 open peripheral-role links, 8 write fragments per callback and no empty fragment, one observation per peer every 2 seconds, and a 256-peer registry.
- Engine: at most 256 pending peers, dropped 30 seconds after their last observation; 256 observed peers; a 4,096-entry consumed-nonce ledger expiring after 48 hours; returning-central refusal implemented on 2026-10-12 (see **Bluetooth transport**); a 20-second pre-exchange peripheral attempt bound; own token rechecked at the write acknowledgement and after save.
- Diagnostics: at most 200 exchange and 200 evidence entries per trial, 200 trial records, and the newest 50 attempt endings. S22 shows counters for exchange/evidence entries dropped beyond the limits.

**FACT — security review, 2026-10-12:** the security reviewer role statically reviewed the refusal and pause diffs; no device test was run. Creation of peripheral-role attempts stays limited to one per 5 seconds per handle while participation is uninterrupted and that handle stays in the 256-entry refusal table; eviction above 256 is the bound that already existed. The finding fixed the same day was that paused peers kept being observed could fill the 256-entry pending-peer table and keep other peers from being dialled; paused peers are now kept out of that table.

Accepted security trade-offs remain open: oldest nonce entries are evicted above 4,096, so Unit 3 server nonce consumption is the replay control; short session candidates can cheaply fill the 4,096-receipt cap and need a smaller budget when sessions exist; now that second exchange is the default, waiting peripheral-role attempts also expose the cap without the session flag, as qualified below; wall-clock changes can delete or extend receipts; failed cleanup after a token-roll rejection can leave the receipt until expiry; sharing a trial log exposes the matching exchange digest on both phones and reveals that their owners met (Development and Internal only).

Accepted open risk, rated low by the 2026-10-12 security review: no enforced idle interval remains after an evidence-free attempt lasting 5 seconds or longer, so four handles can keep all four connection slots occupied continuously. Before the change this needed five handles using the 20-second pre-exchange bound, or four handles occupying about 300 of every 305 seconds by completing a first exchange and withholding evidence. A separate occupancy or failure budget is possible later hardening: undecided, not built.

**UNVERIFIED — code review, not tested:** under second exchange a peripheral-role attempt waiting without a link is not counted in the four connection slots and the number of such attempts is not capped. Each keeps a provisional receipt for up to 5 minutes; about 14 first exchanges per second from distinct handles for 5 minutes would reach the 4,096-receipt cap without the session flag. A full queue fails the write and the runtime then stops the engine as storage unavailable. Open risk, no decision.

**FACT — Unit 3 security review, 2026-10-12:** the initial review found no high and two medium app findings, both fixed (failed-deletion sign-out recovery and backend/account storage isolation). Follow-up review of the fix found one high and one medium issue, both fixed in `37ed0dc`. Final recovery behaviour is under **Accounts**; accepted risks are listed once under **Open and unverified items**. This review is complete, alongside the earlier Unit 2 reviews above.

**FACT — last full verification, 2026-10-12:** local Supabase passed 3218 pgTAP assertions in seven files and clean public/private lint; the live local HTTP flow passed. Package tests: Domain 128, Storage 33, Backend 69, Bluetooth 73. Simulator app-hosted tests: Development 129, Internal 117; UI package tests 70; release-artifact check passed. One simulator host was killed at launch under heavy load and passed on rerun. Hosted tests here mean app-hosted simulator tests, not hosted Supabase. Commands/environment are in `design.md`, **Terminal checks and owner's tools**. **UNVERIFIED:** no app-to-backend simulator/device run, hosted Supabase exercise, or real-device verification of the three Unit 2 presence follow-ups occurred.

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

The UI document is `ui.md`, version 0.4. Unit 2 built the welcome/diagnostics base; Unit 3 built the allocated account screens and Settings list. Current UI routing is recorded below.

**Owner decision — scope, 2026-10-12 (binding):** Unit 3 will build `S02`, `S03`, `S05`, `S12`, `S16`, `S17`, the Settings list needed to reach `S12`, `S16`, `S17`, and the two declarations plus Development-only temporary sign-in on `S01`. `S04` and all link flows will stay in Unit 5, Sign in with Apple in Unit 7, and sessions, QR, feed, block, report and deletion in Unit 4. Until the owner supplies real values, screens will use a placeholder interest list and a threshold range of 1 to 10; the real list and range remain open.

**FACT:** this scope is built; see `design.md`, **Unit 3 contract** for its current implementation.

- Start from the six concept screens in `proposal.pdf` (pages 3 to 5). Keep their teal accent on a light background and their card layout. Build with standard iOS components, with light and dark modes and Dynamic Type.
- A tab bar at the bottom of the screen with three tabs: Discover, Profile, Settings.
- The Connections tab of the concept is removed, because connection requests are out of v1. The My links tab of the concept becomes Profile, because the name, self-introduction and interests live there too.
- Removed from the concept screens: the Request a connection button, the Mutual connections level, the Allow AI processing toggle, and both AI screens.
- Added: Start session, the active session screen, and QR exchange.
- The Settings tab opens a plain list that leads to the seven settings screens. That list is described in `ui.md`, **Navigation**, and is not one of the numbered screens.

**FACT:** Unit 3 routes S01 → S02 → S03 → S05 → Settings; the list reaches S12/S16/S17 and S22 in Development/Internal. S04/links and the final tab roots await later units. S16 activation is unavailable and S05 cannot activate before links exist. The onboarding completion marker uses an installation-salted digest. S12 requires name/introduction/an interest only while discovery is on; purpose remains a screen requirement. Text omissions follow **Open and unverified items**. `ui.md`, **Navigation**, governs detailed built versus future routes.

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

- **Owner — interests and threshold:** supply the real curated interest list and threshold range; the retained scope decision fixes interim values.
- **Owner — token prerequisite:** revisit requiring discovery once onboarding/link flows exist; see the retained account decision.
- **Legal/UI texts:** supply legal texts, links and final version strings, plus the two S05 sketch headings; those links/headings are omitted until supplied.
- **Unit 4 — feed deduplication:** deduplicate same-day cards per viewer.
- **Unit 4 — deletion races:** deletion must take the account advisory lock and map foreign-key races; upload already maps these to `not_found`, while other own-account calls need the future deletion integration.
- **Unit 4 — short session evidence:** decide early discard before expiry and a smaller receipt budget.
- **Unit 4 — physical cleanup:** implement confirmed-encounter/session cleanup; Unit 3 only cleans transient evidence/digests/limiter events.
- **Unit 4 — diagnostics clearing:** call the existing trial-log clear method on sign-out/account deletion.
- **Bluetooth status follow-up:** engine powered-off state is unavailable; the app side channel already distinguishes powered off for S05/S16/S22. Keep the distinction consistent.
- **UNVERIFIED — app/backend:** the app has never been run against a backend in the simulator or on a device.
- **UNVERIFIED — hosted Supabase:** no hosted project has been exercised, including the anonymous sign-in setting.
- **Accepted Unit 3 review risks:** callers can learn whether an overheard token is live for another account; the evidence limit under **Confirmed encounter, security definition**; a counterpart changing zone can cause a second same-day card until feed deduplication. Review and final implementation: `design.md`, **Security requirements** and **Unit 3 contract**.

- The trademark registry search for **すれちがいエンジニア** and **Engineer Encounters**.
- **UNVERIFIED:** background-to-background discovery, including two iPhones; the both-locked check began with foreground first exchanges. Rungs 1 and 2 remain unproven and never promised; rung 2 was not tried.
- Whether the Zenn feed carries the opening text.
- **UNVERIFIED:** the unrun token-window-boundary, real loss-of-contact-and-return, and iPhone-with-iPhone trials; the clean reset-then-lock held-connection trial with iPad locked, and the 160-trial matrix and battery gate.
- **FACT:** the three binding owner decisions of 2026-10-11 were implemented on 2026-10-12; see **Bluetooth transport** for the completed prerequisites of the matrix.
- **DEFAULT:** central-role-only pause scope awaits owner confirmation; see **Bluetooth transport**.
- **UNVERIFIED:** background resumption after 15 minutes and device verification remain open; see **Bluetooth transport** and **Retention and deletion contract**.
- **FACT — fake transport test, 2026-10-12:** the second exchange Reset mismatch still needs a protocol decision, undecided and not built; see **Build, test and release path**.
- **UNVERIFIED — code review, not tested:** when two phones are Reset one after the other, the fresh first exchange made by the phone Reset first is deleted when the second phone is Reset. Under second exchange its reconnect at 120 seconds then meets a new attempt offering an initial exchange, ends with an invalid frame and starts again, so that direction reaches two-minute evidence at about 250 seconds. Reset both phones as close together as possible.
- **UNVERIFIED — code review, not tested:** waiting second exchange attempts expose the receipt cap without the session flag, an open risk with no decision; see **Retention and deletion contract**.
- Accepted open risk, rated low on 2026-10-12: occupancy or failure hardening is undecided and not built; see **Retention and deletion contract**.
- **UNVERIFIED:** delayed second connection with `CBConnectPeripheralOptionStartDelayKey`; undecided and not built. Showing which first exchange a second-exchange evidence entry completes in S22 is also undecided.
- Accepted Unit 2 security risks: oldest-entry nonce eviction requires Unit 3 server replay control; short session candidates need a smaller receipt budget; wall-clock receipt expiry; failed cleanup after token-roll rejection; shared diagnostic digests reveal that the owners met.
- **FACT:** the sandbox question is resolved in **Repository and tools**; it is no longer unverified.
- Whether Sign in with Apple is available on a free Apple account, and the current device cap.
- Whether a foreign developer needs a government filing number for the China mainland storefront. Sources conflict.
- Whether a solo developer with a free, ad-free app counts as a trader under EU rules.
- The exact retention period for resolved reports.
- The exact retention period for the account-deletion safety record (hashed Apple identifier, operator moderation outcomes and incoming blocks), to settle with the legal review and state in the privacy policy.
- **UNVERIFIED:** whether the Supabase free plan allows the second, hosted non-production project.
