# User interface — Engineer Encounters

**Version:** 0.5\
**Status:** Draft interface; drafting defaults and open items labelled\
**Date:** 2026-10-12\
**Related:** `decisions.md` v0.7, `specification.md` v0.7, `design.md` v0.7\
**Platforms:** iOS first, Android later\
**Languages:** Japanese, English

## Principles and look

The public names are **すれちがいエンジニア** and **Engineer Encounters**. Japanese comes first. The interface helps people read another engineer's work without an obligation to talk. Version 1 is free, with no ads or purchases.

`decisions.md`, **User interface**, fixes the screen identifiers and visual direction. Its other product decisions take precedence over `specification.md` v0.7. This document follows `design.md` v0.7 for implementation rules, naming the relevant sections below. **DEFAULT** choices are collected in **Defaults chosen during drafting**; unresolved choices are in **Open items**.

Use standard iOS components, light and dark modes, and Dynamic Type. Keep the concept's teal accent, rounded cards, large titles and short subtitles. The light appearance uses an off-white background, dark navy text, white cards and thin borders. In dark appearance, use system dark surfaces and readable text. Teal marks primary actions, selected pills and links. Destructive actions use the standard destructive style. Text wraps and layouts scroll at large text sizes. Icons always have accessible names; color alone never communicates a state.

The following rules apply to every screen, sketch, card and external surface:

- Show an encounter's **day only**, never its time or place. Do not request location. Session time remaining and the daily report's scheduled time are control information, not encounter times.
- Ambient encounters appear only through the viewer's daily report; the two viewers may reveal at different times (`design.md`, **Encounter states** and **Daily report delivery**). Before reveal, show no names, cards, counts, avatars or nearby-person prompts for them. A session encounter appears immediately only when both people are in a session and confirmation succeeds. QR encounters appear immediately after confirmation.
- Show only currently authorized fields. Matching orders the feed and gates compatible-only fields; it does not hide an otherwise eligible encounter. A card can have no visible links. **DEFAULT:** while an encounter is not eligible, for example because the other person turned discovery off, it is hidden from the feed and from favorites, and it returns if it becomes eligible again within its retention period. The non-identifying shell is used only when the encounter is eligible and every field is private. An eligible all-private shell has no initial avatar or inferred identity (`design.md`, **Matching and visibility**).
- Eligibility requires a confirmed encounter, discovery on for both people, and no block in either direction. Compatibility also requires overlapping purposes and both people's shared-interest thresholds. The three visibility choices are everyone eligible, compatible only and private. Once discovery is on, display name, self-introduction, interests and purposes default to everyone eligible; contact detail defaults to private, and links require an explicit choice.
- Current visibility applies to old encounters, favorites and saved links. Under `design.md`, **iOS app structure**, other people's cards stay only in memory, are re-fetched on opening or foregrounding, and are cleared on sign-out, access changes or loss of a fresh authorization response. Favorites and saved links store references, not card snapshots. If access disappears, remove that content. A deleted encounter or a block removes it for both people, including favorites and saved links. Turning discovery off does not itself delete encounters.
- Ordinary encounters expire after 30 days. A favorite is retained for its viewer; the other viewer's unretained access expires independently. Under `design.md`, **Retention and deletion contract**, expiry is at the start of the local encounter date plus 30 days, and a saved link follows the same retention rule. Neither overrides current authorization or encounter removal. Unconfirmed candidates are never cards and expire after 48 hours.
- There is no AI. There are no connection requests, mutual connections or private messages. Link previews come from the source readers and are edited by their owner. Originals stay on their platforms.
- Use initial-letter avatars only from an authorized display name under the source drafting default. Do not add a role field or an uploaded avatar. Verification is a property of each link, not a badge certifying the whole person.
- **DEFAULT:** the friends test uses development builds pointed at a hosted non-production Supabase project, because the phones leave the owner's Mac. For the later hosted test, enable anonymous sign-in only on that non-production project and disable it on production, in addition to being compiled out of the release build. Local Supabase is for automated checks and the owner's own development.
- Built prerequisite protection is in `design.md`, **Unit 3 contract**. Link mutation protection remains Unit 5; see S12/S16 for client controls.
- Build distribution/features follow `design.md`, **Build kinds**. Development anonymous controls are built on S01; Apple sign-in remains Unit 7. Release artifact checks exclude anonymous/demo/diagnostics code and navigation. The demo setting has no reveal/notification consumer yet. Each build kind reads independent backend address/public-key settings; only Development allows non-HTTPS/local networking.

For a failed write, keep the input and show an inline error with Retry. Confirm success before leaving the form; the session stop follows the immediate local-stop rule on S08. Do not show stale protected content on a loading or error screen. System permission sheets, browser pages and confirmations are surfaces, not additional numbered screens.

Shared wording used throughout:

| Japanese | English |
|---|---|
| 見つける | Discover |
| プロフィール | Profile |
| 設定 | Settings |
| 戻る | Back |
| キャンセル | Cancel |
| 保存 | Save |
| 再試行 | Retry |
| 読み込み中… | Loading… |
| 読み込めませんでした | Could not load |
| 確認済み | Verified |
| 未確認 | Unverified |
| すれちがった相手 | Everyone eligible |
| 条件が合う相手のみ | Compatible only |
| 非公開 | Private |

The visibility explanations clarify that “Everyone eligible” still requires discovery on for both people and no block. “Compatible only” also requires overlapping purposes and both interest thresholds. “Private” means no other user can see the field.

## Navigation

**Owner decision — scope, 2026-10-12 (binding):** Unit 3 will build `S02`, `S03`, `S05`, `S12`, `S16`, `S17`, the Settings list needed to reach `S12`, `S16`, `S17`, and the two declarations plus Development-only temporary sign-in on `S01`. `S04` and all link flows will stay in Unit 5, Sign in with Apple in Unit 7, and sessions, QR, feed, block, report and deletion in Unit 4. Until the owner supplies real values, screens will use a placeholder interest list and a threshold range of 1 to 10; the real list and range remain open.

**FACT:** this scope is built; see `design.md`, **Unit 3 contract** for its current implementation.

**Owner decision — review, 2026-10-12 (binding):** the owner confirmed the planned auth and database changes of Unit 3 and a security review of its diff before merge.

**FACT:** implementation and review are complete; see **Retention and deletion contract** in `decisions.md` for the review outcome.

The dated binding decisions retain their original wording. **FACT — Unit 3 built, 2026-10-12:** the allocated screens and app composition are implemented through `37ed0dc`; the sketches still describe the full later product where noted. Server behaviour is defined once in `design.md`, **Unit 3 contract**.

**FACT:** Stored sessions, server tokens and receipts are bound to backend/account; unbound or foreign stores are quarantined before network/radio use. A stored session is identified as belonging to another backend or account only from the record kept with its credential in the Keychain; stale or unreadable preferences never establish a mismatch or initiate deletion. The prepared-binding lease is in memory, and account-derived storage names use HMAC-SHA-256 keyed with the per-installation salt. A durable non-secret sign-out marker prevents failed credential deletion from restoring an account or allowing new sign-in; pending credential deletion is retried on its own on restore/refresh without tearing down the runtime. Refresh during sign-in or sign-out does not discard the new session. When Keychain is unavailable no stored session is available; while the binding is not ready no backend call is attempted and the runtime reports storage unavailable, retrying preparation on the next refresh. The initial 2026-10-12 security review found no high and two medium app findings, both fixed; follow-up review of the fix found one high and one medium issue, both fixed in `37ed0dc`. See `decisions.md`, **Retention and deletion contract**, for review evidence and last full local pgTAP/HTTP/package/simulator/artifact verification. Accepted risks and unrun environments are in **Open items**.

**FACT:** the built signed-in root is a plain Settings list after S01 → S02 → S03 → S05; there is no S04 link editor or Discover/Profile tab root yet. The list reaches S12, S16, S17 and S22 in Development/Internal. Internal also offers diagnostics from its signed-out/loading/error roots; Development keeps its no-account S01 entry. Release excludes S22. Onboarding completion is keyed by an installation-salted HMAC-SHA-256 digest, with legacy UUID keys removed. S16 cannot activate discovery; link-dependent onboarding activation is described on S05.

**DEFAULT — Units 4/5:** tab/list integration, all planned RPC/client rules and the dated owner demonstration-first order follow `design.md`, **Unit 4 and 5 contract**. Unit 4 builds Discover S06, Profile S11 and Settings (plain list S16–S21, plus S22 in Development/Internal), S07–S10, S18–S21 and S23–S26; S22 gains the demo consumer/clearing. Unit 5 builds S04/S13–S15 and Disconnect GitHub on S20. S12 leaves the Settings list and remains reachable from S11/S06 and prerequisite routes. S23/S24/S25 are S06 panels, not tab roots. Use the destinations’ bilingual titles.

**Mockup of the Settings list:** [images/settings-list.png](images/settings-list.png)

The later completed onboarding route has no tab bar: S01 → S02 → S03 → S04 → S05. **DEFAULT:** it requires name, self-introduction, an interest, a purpose and a first link before S05; S04 uses S14/S15, and successful S05 activation requests notification permission before S06, skipping push requests where unavailable. Existing completed users will enter S06. **FACT:** Unit 3 bypasses the unbuilt S04 to reach S05 and offers Not now → Settings with discovery off; Back returns to S03. Notification, legal and complete tab routes remain later work. Built sign-in/restoration is on S01; discovery controls are on S05/S16.

**DEFAULT:** Tab roots keep their own navigation stacks. Details and editors push onto the current stack; S26 is a sheet. Back returns to the named originating screen. S23, S24 and S25 are shared state views within the Discover flow, rather than extra tabs. They retain navigation to Profile and Settings. S06 can contain the S25 empty state or an S23/S24 status panel while retaining accessible, authorized content. S24 never exposes another person's card while discovery is off.

Completed-product navigation map (an arrow names an in-app destination; “same” means the current screen). Built Unit 3 routing above and the per-screen FACT notes take precedence until later flows exist:

| Origin | Action and destination |
|---|---|
| S01 | Sign in → S02 for new users, unfinished setup screen for returning users, or S06; legal links → S21; Development-only diagnostics before sign-in → S22 (**FACT**, built in Unit 2); current account route is above; legal routes await texts. |
| S02 | Continue → S03; Back → S01. |
| S03 | Continue → S04; Back → S02. |
| S04 | Add first link → S14 → S15 → S04; edit saved link → S15; Continue → S05; Back → S03. |
| S05 | Enable → notification explanation/system permission on S05 → S06 whether granted or declined; skip request if push unavailable; Bluetooth issue → S23; defer discovery → S24; Back → S04. |
| S06 | Card → S07; Start session → S08; QR → S09; Favorites chip → S10; interests → S12; discovery settings → S16; shared states → S23, S24 or S25. |
| S07 | Favorites/save link → same; safety → S26; per-link Report impersonation → S26 with link context; delete → S10 if opened there, otherwise S06; original link → browser, return S07; Back → originating S06/S08/S09/S10 or sample S24/S25. |
| S08 | Stop or Back → S06; QR → S09; revealed session card → S07; unmet discovery/Bluetooth prerequisites → S24/S23. |
| S09 | Confirmed QR exchange → S07; discovery off → S24; Back → S06, S08, S23 or S25, its origin. |
| S10 | Favorite or saved-link context → S07; original link → browser, return S10; remove favorite/save → same; Back → S06. |
| S11 | Edit → S12; My links → S13; visibility → S17; original link → browser, return S11. |
| S12 | Save, Cancel or Back → whichever screen opened it: Settings list, S11, S06, S16 or S24; prerequisite guidance → S16; visibility → S17, then return S12. |
| S13 | Add → S14 → S15 → S13; edit → S15; original link → browser, return S13; Back → S11/S17/S16/S24, its origin. |
| S14 | Select source item or fetch page → S15; Cancel/Back → S04 or S13, its origin. |
| S15 | Save/delete existing link → S04 or S13, its origin; Cancel → S14 for a new link or S04/S13 for an existing link; prerequisite guidance → S16. |
| Settings list | Completed Unit 4 list → `S16`–`S21`, plus `S22` in Development/Internal; `S12` moves to Profile/Discover. Historical Unit 3 routes are recorded above. |
| S16 | Save settings → same; complete profile → S12; add link → S13; Bluetooth issue → S23; discovery off → S24; Back → whichever screen opened it: Settings list, S06, S12, S15, S20, S23 or S24. |
| S17 | Save → same; link visibility → S13 → S15; Back → Settings list, S11 or S12, its origin. |
| S18 | Time/notification change → same; system settings → iOS Settings, return S18; Back → Settings list. |
| S19 | Unblock → same; Back → Settings list. |
| S20 | Disconnect GitHub → confirmation → same (**DEFAULT**); sign out/delete account → S01; Cancel → same; prerequisite guidance → S16; Back → Settings list. |
| S21 | Policy, terms or support → external surface, return S21; Back → Settings list or S01, its origin. |
| S22 | **FACT:** local participation switch, trial reset with visible confirmation, presence selector, recorded trials, Refresh/Retry and demo setting → same; Share trial log → system share sheet, return S22; Back returns to the invoking Settings/welcome root; current routing is above. |
| S23 | Retry → S06/S08/S05/S16, its origin, if ready; QR → S09; discovery settings → S16; iOS Settings → system, return S23. |
| S24 | Enable discovery → S16; complete basics → S12; add link → S13; sample → S07 in sample context; return to Discover → S06 containing S24 until enabled. |
| S25 | Sample → S07 in sample context; Start session → S08; QR → S09; dismiss → same empty state. |
| S26 | Successful report/block → S10 if the encounter was opened there, otherwise S06; Cancel → S07 if accessible. |

Selecting a different bottom tab preserves its navigation stack; reselecting the current tab returns to its root. Permission requests return to the invoking screen. Auth and external-link flows return to their invoking screen unless the action explicitly signs out or deletes the account.

## Mockups

`images/` holds illustrative mockups of the screens listed below. They show the Japanese interface in light appearance and were produced with an image generator. They are not screenshots of the app.

This document governs. Where a mockup differs from the purpose, elements, states, actions or wording defined here, follow this document. Use a mockup for look, spacing and layout only. Do not take the following from a mockup: sample people, sample links, interest names (the vocabulary is an open item), icon choices, the device frame or the image size. The mockups do not show dark appearance, English, large text sizes, or empty, loading and error states.

| Screen | Mockup | Known differences (not exhaustive) |
|---|---|---|
| S01 Welcome and sign-in | [s01-welcome-sign-in.png](images/s01-welcome-sign-in.png) | None recorded. |
| S02 Profile basics | [s02-profile-basics.png](images/s02-profile-basics.png) | None recorded. |
| S03 Interests and purposes | [s03-interests-purposes.png](images/s03-interests-purposes.png) | None recorded. |
| S04 First link | [s04-first-link.png](images/s04-first-link.png) | The identity warning is shortened. |
| S05 Permissions and turning discovery on | [s05-permissions-discovery-on.png](images/s05-permissions-discovery-on.png) | The explanatory sentences are shortened. |
| S06 Feed | [s06-feed.png](images/s06-feed.png) | The あなたの興味 row starts with a selected すべて chip; the row lists the user's own interests and is not a filter. The background-discovery note is not drawn. |
| S07 Encounter detail | [s07-encounter-detail.png](images/s07-encounter-detail.png) | One chip under 共通点 is drawn as unselected; every chip there is a shared item. |
| S08 Active session | [s08-active-session.png](images/s08-active-session.png) | The explanatory line says encounters appear immediately; the two session rules in S08 apply instead. |
| S09 QR exchange | [s09-qr-exchange.png](images/s09-qr-exchange.png) | None recorded. |
| S10 Favorites, 相手 segment | [s10-favorites.png](images/s10-favorites.png) | Cards are not grouped by day. A 最近保存したリンク block is drawn under this segment; saved links belong only to the other segment. |
| S10 Favorites, 保存したリンク segment | [s10-favorites-saved-links.png](images/s10-favorites-saved-links.png) | None recorded. |
| S13 Links list | [s13-links-list.png](images/s13-links-list.png) | None recorded. |
| S16 Discovery and matching | [s16-discovery-matching.png](images/s16-discovery-matching.png) | None recorded. |
| Settings list | [settings-list.png](images/settings-list.png) | None recorded. |

S11, S12, S14, S15 and S17 to S26 have no mockup. Build them from their text sketches, in the same visual style.

## The 26 screens

Sketches show English wording. Label tables provide Japanese and English equivalents. Square brackets mark controls, parentheses mark conditional elements. The common state and authorization rules above apply in addition to each screen's states.

### S01 Welcome and sign-in

**Mockup:** [images/s01-welcome-sign-in.png](images/s01-welcome-sign-in.png)

**Purpose and entry:** Introduce the product and establish a durable account. Open on first launch, after sign-out or account deletion, or when authentication has expired.

**FACT:** Unit 3 extends the welcome with separate 18+/agreement declarations and temporary anonymous sign-in in Development when backend configuration is valid and the account is signed out. Apple/legal routes remain later work; omissions are listed in **Open items**.

**Owner decision — token prerequisite, 2026-10-12 (binding):** planned token issue will require a signed-in account, recorded 18+ declaration and acceptance of terms and privacy policy, and a valid registered time zone; discovery on will not be required. Accepted consequence: discovery-off accounts can have encounters confirmed and stored as dates only, becoming visible if both people later turn discovery on within retention, subject to reveal and current authorization. No Unit 3 function creates links, so the app cannot turn discovery on before Unit 5. Requiring discovery for token issue remains an owner open item to revisit once onboarding and link flows exist. See `design.md`, **Unit 3 contract** for the built server/client detail.

```text
Engineer Encounters
Discover the work of engineers you encounter.
[ ] I am 18 or older
[ ] I agree to the terms and privacy policy
[Terms]  [Privacy policy]
[Sign in with Apple]
(Development only: [Temporary sign-in] [Diagnostics])
```

**Elements — completed product sketch:** public name, introduction, age/agreement declarations, legal links and Apple sign-in. Built controls and omissions are described above. Both declarations are required before sign-in. GitHub is not a sign-in option. The built temporary anonymous control is compiled only for Development, with the same declarations; Internal/Release exclude it. Those builds cannot sign in before Unit 7; the Apple control in this sketch is the later product plan.

**States:** **FACT:** declarations start unchecked; loading disables repeated sign-in. Restoration shows progress without a sign-in control. Only not-authenticated automatically signs out; setup/transport/storage failures retain a pending account with Retry. Sign-in is refused while a session exists; account switching is sign-out then sign-in, with sign-out only on S22 in Development/Internal. Error preserves declaration input; cancellation adds no error. A person who cannot declare 18+ cannot proceed.

**Actions:** **FACT:** temporary sign-in saves declarations and zone then loads the own profile; setup failure retains the account for Retry. New/incomplete setup follows **Navigation**; completed onboarding returns to Settings. The later Apple/full-tab/legal routes follow the navigation map. Retry stays in the current sign-in/setup state. Diagnostics entry and return follow **Navigation**.

| Japanese | English |
|---|---|
| すれちがいエンジニア | Engineer Encounters |
| すれちがったエンジニアの作品を見つけよう | Discover the work of engineers you encounter. |
| 18歳以上です | I am 18 or older |
| 利用規約とプライバシーポリシーに同意します | I agree to the terms and privacy policy |
| 利用規約 | Terms |
| プライバシーポリシー | Privacy policy |
| Appleでサインイン | Sign in with Apple |
| テスト用の一時サインイン | Temporary sign-in |
| 診断 | Diagnostics |

### S02 Profile basics

**Mockup:** [images/s02-profile-basics.png](images/s02-profile-basics.png)

**Purpose and entry:** Enter the name and introduction used on the card. Reach from S01 or Back on S03.

```text
[Back] Profile basics
Tell others a little about yourself.
Display name [                         ] 0/30
Introduction [                        ] 0/200
[Continue]
```

**Elements:** Display name and user-written introduction, character counters and field validation. **FACT:** built counters/validation count trimmed Unicode code points (scalars), with **DEFAULT** limits 30 and 200; server-only invisible-input handling follows `design.md`, **Unit 3 contract**. Both are required to enable discovery; no role or photo field is added.

**States:** Empty: blank fields with Continue unavailable until valid. Loading: keep entered text while saving. Error: identify the invalid field or show a save error; preserve both fields.

**Actions:** **FACT:** Continue saves → S03. Back → S01. Editing and Retry stay on S02. **DEFAULT:** completed onboarding steps retain entered values when revisited.

| Japanese | English |
|---|---|
| プロフィールの基本情報 | Profile basics |
| あなたのことを少し教えてください | Tell others a little about yourself. |
| 表示名 | Display name |
| 自己紹介 | Introduction |
| 次へ | Continue |
| 表示名と自己紹介を入力してください | Enter a display name and introduction |

### S03 Interests and purposes

**Mockup:** [images/s03-interests-purposes.png](images/s03-interests-purposes.png)

**Purpose and entry:** Choose interests and why the user wants to discover others. Reach from S02 or Back on S04.

```text
[Back] Interests and purposes
Interests
[Curated interest chips, multiple selection]
Purposes
[ ] Discovery       [ ] Collaboration
[Continue]
```

**Elements:** The placeholder interest list authorized under **Navigation** until the owner supplies the real list; no free-text interest entry. Discovery and Collaboration can both be selected and changed later. Once discovery is on, purposes default to everyone eligible, like display name, self-introduction and interests. Select at least one interest for discovery. **DEFAULT:** require at least one purpose here so compatibility can be evaluated; do not preselect one.

**States:** Empty: nothing selected, with selection guidance. Loading: show progress for the list or saving, preserving selections. Error: list-load Retry or save failure without losing selections. Final interest vocabulary remains in **Open items**; built selection limits are in `design.md`, **Unit 3 contract**.

**Actions:** Selecting chips/checkboxes stays on S03. Continue saves → S04. Back → S02. Retry → S03.

| Japanese | English |
|---|---|
| 興味・目的 | Interests and purposes |
| 興味のある分野 | Interests |
| 利用目的 | Purposes |
| 作品を見つける | Discovery |
| 一緒につくる | Collaboration |
| 興味と目的をそれぞれ1つ以上選んでください | Choose at least one interest and purpose |
| 次へ | Continue |

### S04 First link

**Mockup:** [images/s04-first-link.png](images/s04-first-link.png)

**Purpose and entry:** Planned for Unit 5 under **Navigation**. Add and preview one link before S05 under the onboarding **DEFAULT**. Reach from S03, S15 after saving a first link, or Back on S05.

```text
[Back] Your first link
Your work stays on its original platform.
[Add a link]
(Saved link: source, title, preview, visibility)
External links may reveal your identity.
[Continue]
```

**Elements:** The source-platform explanation, add action, a preview of the saved link and an identity warning. Any supported source, verification status or chosen visibility, including private, meets the one-link prerequisite. A new link has no preselected visibility.

**States:** Empty: explain the one-link requirement; Continue is unavailable. Loading: load the saved preview or return from saving with progress. Error: Retry loading or editing the link; do not claim it was shared when save failed.

**Actions:** Add a link → S14 with S04 as return destination. Saved preview → S15 for editing, returning to S04 after save. Continue → S05 once a link exists. Back → S03. Retry → S04.

| Japanese | English |
|---|---|
| 最初のリンク | Your first link |
| リンクを追加 | Add a link |
| 作品は元のサービスに保存されたままです | Your work stays on its original platform. |
| ニックネームでも、外部リンクから個人が特定されることがあります | External links may reveal your identity, even with a nickname. |
| 発見をオンにするにはリンクが1件以上必要です | Add at least one link to enable discovery |
| 次へ | Continue |

### S05 Permissions and turning discovery on

**Mockup:** [images/s05-permissions-discovery-on.png](images/s05-permissions-discovery-on.png)

**Purpose and entry:** Explain discovery and request Bluetooth access before activation. **FACT:** Unit 3 enters from S03, with discovery off; the later full route enters from S04 and adds notification permission after activation.

```text
[Back] Enable discovery
What discovery promises
One of you has the app open; stay in range 2 minutes.
Locked or background discovery may also work.
Ambient encounters arrive in your daily report.
Force-quitting stops discovery until you reopen.
Bluetooth access [Allow Bluetooth]
[Enable discovery]  [Not now]
(After activation: Your daily report arrives as a notification.)
(System notification permission sheet, if push is available)
```

**FACT:** the built S05 has explanation, prerequisite checklist, Bluetooth permission/recovery and enable/defer controls. Activation cannot proceed until a link exists; link creation stays Unit 5 and its Add link action is unavailable here. Not now completes the explanation and returns to Settings; Back returns to S03. The two unprovided sketch headings are omitted; see **Open items**. Permission status uses the app side channel's powered-off distinction. Notification permission remains later work.

**Elements — later completed flow:** The full bilingual explanation below, Bluetooth purpose text, permission status and explicit enable/defer controls. Explain that both phones must participate; one-sided exchanges do not become cards. Sessions and QR are alternatives, not a switch between detection modes. Explain the first-unlock-after-reboot limitation. Do not ask for location. Right after successful discovery activation, show the one-line explanation “Your daily report arrives as a notification” and request system notification permission here. Granting enables daily report notifications; declining leaves notifications off and does not block or disable discovery; S18 is the place to change notifications later. If push is unavailable, including development builds on a free Apple account, skip the request and explain that the report is read in the app.

**States:** built activation is gated by the S05 prerequisites above. The remaining states below describe the later link/notification/S23 flow. Empty: permission not requested and discovery off. Loading: wait for the Bluetooth sheet or activation result; after activation, await the notification sheet without resetting discovery. Notification denial is a permitted outcome, not an activation error. Error: denied access/Bluetooth off → S23; missing profile/link prerequisites link to S02, S03 or S04; activation failure retains discovery off and offers Retry.

**Actions — later completed flow:** Allow Bluetooth invokes the system permission sheet, then returns to S05 or S23. Built permission recovery opens iOS Settings directly. Enable discovery validates prerequisites and saves → notification explanation and permission sheet on S05 → S06, initially containing S25 if empty, whether permission is granted or declined. Skip the notification sheet when push is unavailable. Built token prerequisites follow the owner decision on `S01` and `design.md`, **Unit 3 contract**; the later QR zone prerequisite remains in `design.md`, **Data model**. Not now → S24 in the Discover tab, keeping discovery off. Back → S04. Retry stays on S05.

| Japanese | English |
|---|---|
| 発見をオンにする | Enable discovery |
| Bluetoothを許可 | Allow Bluetooth |
| 毎日のレポートが通知で届きます | Your daily report arrives as a notification |
| 通知を許可しなくても、発見は利用できます | Discovery works even without notification permission |
| このビルドでは、レポートはアプリ内で確認できます | In this build, read your report in the app |
| あとで | Not now |
| 2人とも発見がオンでBluetoothを利用できる場合、少なくともどちらかがアプリを開いていれば、Bluetoothの届く範囲に2分以上いることで、すれちがいが記録されます。 | When discovery is on for both of you and Bluetooth is available, an encounter is recorded after at least 2 minutes within Bluetooth range when at least one of you has the app open. |
| 画面をロックしているときや、アプリがバックグラウンドにあるときも、記録される場合があります。 | Discovery may also work while phones are locked or the app is in the background. |
| 通常のすれちがいは、毎日のレポートでまとめて届きます。初期設定は現地時間の21:00です。 | Ambient encounters appear together in your daily report, at 21:00 local time by default. |
| 2人ともセッション中なら、すれちがいは確認後すぐに表示されます。QR交換も確認後すぐに表示されます。 | Encounters between two people in a session appear immediately after confirmation. QR encounters also appear immediately after confirmation. |
| アプリを強制終了すると、もう一度開くまで発見は停止します。 | Force-quitting the app stops discovery until you reopen it. |
| 再起動後は、一度ロックを解除するまで発見できません。 | After a restart, discovery cannot work until the phone is unlocked once. |
| すれちがいを記録するためにBluetoothを使用します。位置情報は使用しません。 | Bluetooth is used to record encounters. Location is not used. |

### S06 Feed

**Mockup:** [images/s06-feed.png](images/s06-feed.png)

**Purpose and entry:** Browse revealed encounters grouped by day. Open from the Discover tab, completed onboarding or a daily report notification.

```text
Discover
Explore the work of people you encounter.
[Discovery enabled]  Background discovery may also work.
[Start session]  [QR exchange]
Your interests  [chips]
[Favorites → separate screen]
October 10
  [Initial] Name · Shared interests
  Ambient / Session / QR
  First visible link · Source · Tags · Verified / Unverified
  [View shared work]
No need to message. Explore at your pace.
[Discover] [Profile] [Settings]
```

**Elements:** Discovery status linked to S16, session action (View session when active), QR, the user's interest chips, a Favorites chip opening S10 and day groups. The source drafting card includes display name, shared interests, first visible link, per-link verification and encounter kind. No encounter time or place appears. Omit unauthorized fields; if no link is visible, the card can still open S07. **DEFAULT:** newer day groups come first. Within a day, follow `design.md`, **Matching and visibility**: compatible encounters first, then shared-interest count, then a stable encounter ID; never encounter time. **DEFAULT:** hide ineligible encounters from this feed and from favorites; they return if eligible again within retention. Only eligible encounters with every field private use a non-identifying shell with day and kind and no avatar or identity.

**States:** Empty: S25. Loading: neutral skeletons without names, counts or candidate data. Error: inline Retry; never present an unrevealed ambient card as a fallback. Discovery off: S24 suppresses cards. Bluetooth unavailable: S23 status; existing authorized revealed cards remain readable, and QR can still work.

**Actions:** Card/View shared work → S07. Start/View session → S08; prerequisites route to S24 or S23. QR → S09, or S24 if discovery is off. Favorites filter → S10. Status → S16; interests → S12. Retry stays on S06. Tabs → S06, S11 or Settings list.

| Japanese | English |
|---|---|
| 見つける | Discover |
| すれちがった人の作品を見てみよう | Explore the work of people you encounter. |
| 発見はオンです | Discovery enabled |
| バックグラウンドでも記録される場合があります | Background discovery may also work |
| セッションを開始 | Start session |
| セッションを見る | View session |
| QR交換 | QR exchange |
| あなたの興味 | Your interests |
| お気に入り | Favorites |
| 共通の興味：{count}件 | {count} shared interests |
| 公開されている情報はありません | No information is shared with you |
| 通常のすれちがい | Ambient |
| セッション | Session |
| 共有された作品を見る | View shared work |
| メッセージは不要です。自分のペースで見てみましょう。 | No need to message. Explore at your pace. |

### S07 Encounter detail

**Mockup:** [images/s07-encounter-detail.png](images/s07-encounter-detail.png)

**Purpose and entry:** Read the other person's authorized card and links. Reach from S06, S08, S09, S10 or the S25 sample.

```text
[Back] Encounter                         [Favorite]
Only information shared with you
(Sample encounter banner)
[Initial] Display name
Introduction
Day · Ambient / Session / QR
Purposes [authorized purpose chips]
What you have in common [interest / purpose chips]
Link cards: source, title, description, tags, opening text
  Verified / Unverified  [Open original link] [Save link]
  [Report impersonation]
(Authorized contact detail)
[More: report or block]  [Delete encounter]
```

**Elements:** Initial avatar, authorized profile fields, authorized purposes, common interests/purposes only when authorized, day and kind, all visible link cards, per-link verification and an optional authorized contact detail. Only when eligible and every field is private, retain a non-identifying shell with day and kind, omit the avatar, and use “No information is shared with you” under the visibility **DEFAULT** (`design.md`, **Matching and visibility**). Purposes default to everyone eligible once discovery is on, like display name, self-introduction and interests; show authorized purposes even when they do not overlap with the viewer's purposes. No role is inferred. Explain that an unverified link's ownership is not confirmed. A sample is labelled throughout and has no real contact or live safety action.

**States:** Empty: no visible links → say so without implying poor compatibility; missing/removed encounter → return to S06 or S10. Loading: placeholders until authorization succeeds. Error: Retry without protected cached content. Sample mode uses fictitious on-device data and no encounter date/kind pretending it is real.

**Actions:** Favorite/remove favorite and save/unsave link stay on S07; they affect S10. Open original link → browser, return S07. More → S26. Per-link Report impersonation → S26 with that authorized link as context and impersonation selected. Delete encounter opens a destructive confirmation, then removes it for both people → S10 if opened there, otherwise S06. Cancel deletion stays on S07. Back → S06, S08, S09 or S10, its origin. In sample mode, Back → S24 or S25, its origin; favorite, save, delete and safety controls are omitted under a drafting default, and originals are only safe sample links.

| Japanese | English |
|---|---|
| すれちがった相手 | Encounter |
| あなたに公開されている情報だけを表示しています | Only information shared with you |
| 利用目的 | Purposes |
| 共通点 | What you have in common |
| 元のリンクを開く | Open original link |
| リンクを保存 | Save link |
| 保存を解除 | Unsave link |
| お気に入りに追加 | Add to favorites |
| お気に入りから外す | Remove from favorites |
| 公開されているリンクはありません | No links are shared with you |
| 連絡先 | Contact detail |
| 通報・ブロック | More: report or block |
| なりすましを通報 | Report impersonation |
| すれちがいを削除 | Delete encounter |
| 2人の一覧から削除され、お気に入りや保存したリンクも削除されます。 | This removes the encounter for both people, including favorites and saved links. |
| サンプルのすれちがい | Sample encounter |

### S08 Active session

**Mockup:** [images/s08-active-session.png](images/s08-active-session.png)

**Purpose and entry:** Show and stop a deliberately started session. Start from S06 or S25, reopen from View session, or open from the Live Activity or one-tap control.

```text
[Back] Session
Session active · Time remaining 1:59:00
Lasts up to 2 hours
Both in a session: encounters appear immediately.
Only one in a session: 2 minutes, then daily report.
[QR exchange]  [Stop session]
Revealed session encounters [cards, day only]
```

**Elements:** Own-session status and remaining duration, two-hour limit, stop control, QR and confirmed/revealed session cards. No participant presence indicators or pending ambient results. Starting a session does not disable ambient or QR discovery. Follow `design.md`, **iOS app structure**: a new session becomes active only after server acknowledgement. An offline user may finish an already-started session, but cannot start a new one. Stop immediately clears the local session flag and queues the server stop, including while offline.

**States:** Empty: an active session can have no revealed session encounters; use calm guidance. Loading: starting progress, with no active claim before server acknowledgement; a queued stop never keeps the local session active. Error: failed/offline start → Retry on S08; failed stop upload → show Session ended with retry status, retaining the queued stop; unmet discovery/Bluetooth conditions → S24/S23. On expiry, show Session ended and a return action. The timer is session duration, never an encounter clock.

**Actions:** Successful start stays on S08. Stop ends the session → S06; expiry's Done → S06. QR → S09. A revealed card → S07. Back → S06 while the session continues. Retry → S08. **DEFAULT:** starting has no extra confirmation; stopping is immediate locally, queues the server stop and does not start another session. Never restore the active local flag because a stop upload failed.

| Japanese | English |
|---|---|
| セッション | Session |
| セッション中 | Session active |
| 残り時間 | Time remaining |
| 最大2時間 | Lasts up to 2 hours |
| 2人ともセッション中なら、確認後すぐに表示されます。 | When both people are in a session, encounters appear immediately after confirmation. |
| 片方だけがセッション中の場合は、2分以上のすれちがいが毎日のレポートで届きます。 | If only one person is in a session, encounters require 2 minutes and appear in the daily report. |
| セッションを停止 | Stop session |
| まだセッションでのすれちがいはありません | No session encounters yet |
| セッションが終了しました | Session ended |
| セッションを開始するにはネット接続が必要です | Connect to start a session |
| セッションは停止しました。接続が戻ると停止を送信します | Session stopped. The stop will sync when connected |
| 完了 | Done |

### S09 QR exchange

**Mockup:** [images/s09-qr-exchange.png](images/s09-qr-exchange.png)

**Purpose and entry:** Exchange cards together without Bluetooth. Reach from S06, S08, S23 or S25 when signed in and discovery is on.

```text
[Back] QR exchange
[Show code] [Scan code]
Show: one-time QR code · Valid for 2 minutes [Refresh code]
Scan: camera view [Allow camera, if needed]
Confirmed exchanges appear immediately.
(Confirming… / Expired code)
```

**Elements:** Show/scan segments, a one-time code valid for 2 minutes and camera preview, following `design.md`, **Confirmed encounter, security definition**, **Sessions and QR**. Only one code may be outstanding per account; refreshing invalidates the previous one. Code issue and redemption require network access. Reject self-scans. A showing phone obtains its code while signed in; confirmation follows a distinct signed-in account's successful redemption before expiry. Do not expose a profile or a pending peer identity before confirmation. No Bluetooth or location permission is needed for QR. Discovery-on eligibility still applies to both accounts.

**States:** Empty: no code yet or no scanned code. Loading: generating a code or confirming the exchange. Error: generic code unavailable for expired/replaced/used/cancelled/blocked cases, malformed code or self-scan, network failure, or camera denial; offer refresh/retry or iOS Settings as appropriate. Bluetooth denial does not block QR. Discovery off → S24. Do not call an offline scan confirmed.

**Actions:** Switch segment, Refresh code and Retry stay on S09. Allow camera invokes the system sheet and returns S09. Camera settings → iOS Settings, return S09. Confirmed exchange → S07 for either participant once available. Back → S06, S08, S23 or S25, its origin.

| Japanese | English |
|---|---|
| QR交換 | QR exchange |
| コードを表示 | Show code |
| コードを読み取る | Scan code |
| コードを更新 | Refresh code |
| カメラを許可 | Allow camera |
| 確認中… | Confirming… |
| コードの有効期限が切れました | This code has expired |
| このコードは利用できません | This code is unavailable |
| コードは2分間有効です | This code is valid for 2 minutes |
| 更新すると前のコードは使えなくなります | Refreshing invalidates the previous code |
| 自分のコードは読み取れません | You cannot scan your own code |
| QR交換にはネット接続が必要です | Connect to exchange QR codes |
| コードを読み取れませんでした | Could not read this code |
| 確認後、すぐに表示されます | Confirmed exchanges appear immediately |
| iOSの設定を開く | Open iOS Settings |

### S10 Favorites

**Mockups:** [images/s10-favorites.png](images/s10-favorites.png) (相手 segment), [images/s10-favorites-saved-links.png](images/s10-favorites-saved-links.png) (保存したリンク segment)

**Purpose and entry:** Revisit favorite encounters and saved individual links. Reach from the Favorites chip on S06.

```text
[Back] Favorites
[Encounters] [Saved links]
Encounter cards, grouped by day
or
Saved link cards: source, title, preview, verification
  [Open original link] [View encounter] [Unsave link]
```

**Elements:** Two segments under a drafting default, current authorized cards, original-link and encounter-context actions. Favorites survive ordinary 30-day expiry for this viewer; saved links do so under the source default. Store references only, never persist other people's cards on the device; re-fetch on opening or foregrounding (`design.md`, **iOS app structure**). Removing the last favorite or saved-link retention after normal expiry removes that viewer's retained access (`design.md`, **Retention and deletion contract**).

**States:** Empty: explain how to favorite an encounter or save a link on S07. Loading: recheck access before showing cards. Error: Retry, without stale restricted content. Removed/blocked encounters disappear; private links disappear from this view. **DEFAULT:** ineligible retained encounters are hidden, including when the other person turns discovery off, and return if eligible again within their retention period; no shell stands in for an ineligible encounter. Discovery off uses S24 and suppresses other people's cards.

**Actions:** Encounter or View encounter → S07. Open original link → browser, return S10. Remove favorite/Unsave link stays on S10 and updates the list. Segment change/Retry stays on S10. Back → S06.

| Japanese | English |
|---|---|
| お気に入り | Favorites |
| 相手 | Encounters |
| 保存したリンク | Saved links |
| お気に入りはまだありません | No favorite encounters yet |
| 保存したリンクはまだありません | No saved links yet |
| 相手の画面でお気に入りやリンクを保存できます | Favorite encounters and save links from an encounter |
| 相手を見る | View encounter |
| 保存を解除 | Unsave link |

### S11 My card

**Purpose and entry:** Preview the user's card as an authorized viewer would see it. Open from the Profile tab.

```text
Profile
Preview your shared card
[Everyone eligible] [Compatible only]
[Initial] Display name
Introduction · Interests · Purposes (when authorized)
(Authorized contact detail)
Visible link cards
[Edit profile] [My links] [Visibility]
[Discover] [Profile] [Settings]
```

**Elements:** A preview of the owner's own profile, eligible/compatible audience selector under a drafting default and links to editing. **DEFAULT:** compute both previews on-device from own profile, visibility and own links under `design.md`, **Unit 4 and 5 contract**; no server preview RPC. Once discovery is on, purposes default to everyone eligible, like display name, self-introduction and interests, so both audience previews initially include them. Private fields are omitted from the shared preview; the owner's full data remains available in editors. Label this as a preview, not evidence that a particular person has access. When discovery is off, explain that the preview is what would be shared after activation.

**States:** Empty: missing basics or links show completion guidance. Loading: load the owner's profile and selected visibility preview. Error: Retry without claiming a preview is current. No encounter dates or invented encounter metadata appear on an own-card preview.

**Actions:** Edit profile → S12. My links → S13. Visibility → S17. Audience selection/Retry stays on S11. Open original link → browser, return S11. Tabs → S06, S11 or Settings list.

| Japanese | English |
|---|---|
| プロフィール | Profile |
| 公開カードのプレビュー | Preview your shared card |
| プロフィールを編集 | Edit profile |
| 自分のリンク | My links |
| 公開範囲 | Visibility |
| 発見をオンにすると、この内容が公開されます | This is what you will share when discovery is enabled |

### S12 Edit profile

**Purpose and entry:** Change the owner's profile, interests, purposes and optional contact detail. Reach from the Unit 3 Settings list, or later from S11, S06 interests and prerequisite guidance on S16/S24.

```text
[Cancel] Edit profile                         [Save]
Display name [                        ]  /30
Introduction [                        ]  /200
Interests [curated chips]
Purposes [Discovery] [Collaboration]
Contact detail [optional, one value]
[Visibility]
```

**Elements:** The same fields as onboarding, with the interim interest list under **Navigation**, plus one optional contact detail. Built validation and tunable limits belong in `design.md`, **Unit 3 contract**. Name, introduction, interests and purposes default to everyone eligible once discovery is on. Contact starts private. No chat, role, free-text interest or avatar uploader. Prerequisite-removal protection follows `design.md`, **Unit 3 contract**; link editing remains Unit 5.

**States:** **FACT:** S12 requires name/introduction/an interest only when discovery is on; purpose is still a screen requirement. Counters use trimmed code points with the limits in the server contract. Unsaved input and confirmed partial saves survive failures/retry, with stale-profile feedback when refresh fails. Writes narrow shared fields/selections before replacing them to avoid transient expansion. Empty: show missing-field guidance; optional contact may stay blank. Loading: load/save without losing unsaved edits. Error: field-level validation or save error with retained input. Visibility changes affect past cards as well as future ones.

**Actions:** Save after success, Cancel or Back → its origin (built Settings/S16, later S11/S06/S24), with discard confirmation for unsaved changes. Visibility → S17, then Back → S12. Missing discovery prerequisite guidance → S16. Editing/Retry stays on S12. Returning from S17 preserves other unsaved input.

| Japanese | English |
|---|---|
| プロフィールを編集 | Edit profile |
| 表示名 | Display name |
| 自己紹介 | Introduction |
| 興味のある分野 | Interests |
| 利用目的 | Purposes |
| 連絡先（任意） | Contact detail (optional) |
| 連絡先は初期設定で非公開です | Your contact detail is private by default |
| 変更を破棄 | Discard changes |
| 発見をオンにしている間は必須項目を空にできません | Required fields cannot be empty while discovery is on |

### S13 Links list

**Mockup:** [images/s13-links-list.png](images/s13-links-list.png)

**Purpose and entry:** Manage the owner's link cards. Reach from S11, S17 or missing-link guidance on S16/S24.

```text
[Back] My links
Your work stays on its original platform.
[Add a link]                           {count}/10
Cards: source, title, preview, tags, verification, visibility
  [Edit] [Open original link]
External links may reveal your identity, even with a nickname.
```

**Elements:** All owned links, including private ones, visibility pills, per-link verification, add/edit and original-link actions. Under the source default, the limit is 10 links. The identity warning remains visible; no content is hosted here.

**States:** Empty: Add a link guidance and the discovery prerequisite. Loading: neutral placeholders for owned links. Error: Retry loading; failed edits are handled on S15. At the drafting limit, disable adding and explain the limit.

**Actions:** Add → S14, returning through S15 to S13. Edit → S15 with S13 as origin. Original → browser, return S13. Back → S11 or S17, its origin; prerequisite callers can return to S16/S24 after editing. Retry stays on S13.

| Japanese | English |
|---|---|
| 自分のリンク | My links |
| リンクを追加 | Add a link |
| 編集 | Edit |
| リンクはまだありません | No links yet |
| リンクは10件まで追加できます | You can add up to 10 links |
| ニックネームでも、外部リンクから個人が特定されることがあります | External links may reveal your identity, even with a nickname. |
| 作品は元のサービスに保存されたままです | Your work stays on its original platform. |

### S14 Add link

**Purpose and entry:** Select an original source and import an editable preview. Reach from Add a link on S04 or S13.

```text
[Cancel] Add link
[GitHub] [Qiita] [Zenn] [Other page]
GitHub: [Connect GitHub] → own public repositories
Unit 5: Qiita / Zenn / Other page — Not yet available
Unit 8: Qiita / Zenn username and article selection
Unit 9: Other page URL and preview
```

**Elements:** Four eventual sources; **DEFAULT:** in Unit 5 only GitHub is enabled, Qiita/Zenn/Other page show Not yet available until Units 8/9 under `design.md`, **Unit 4 and 5 contract**. Connect GitHub as a verification identity for the already signed-in account, then select an owned public repository. Qiita and Zenn each remember the entered username after the first entry. Show only source-provided summaries and metadata. Other pages use a single title/preview fetch, never page-body scraping. **DEFAULT:** add one item at a time. All four sources are present for public release; the friends-test stage may have only GitHub, as specified in `decisions.md`, **Build, test and release path**.

**States:** Empty: source not selected, or the source has no public items; explain how to choose another source. Loading: connecting, loading items or reading a preview. Error: connection failure, unknown username, rejected URL, unavailable source or read failure; preserve input and allow retry. Empty source metadata can be filled manually on S15 after a successful source selection; a failed fetch is not silently treated as success.

**Actions:** Connect GitHub → system/browser authorization, return S14. Load items/Read preview → same while reading. Select an item or successful page fetch → S15 with the source and editable preview. Source change/Retry stays on S14. Cancel/Back → S04 or S13, its origin.

| Japanese | English |
|---|---|
| リンクを追加 | Add link |
| GitHubを連携 | Connect GitHub |
| 公開リポジトリ | Public repositories |
| ユーザー名 | Username |
| 記事を読み込む | Load items |
| 選択 | Select |
| その他のページ | Other page |
| プレビューを取得 | Read preview |
| 公開された項目がありません | No public items found |
| まだ利用できません | Not yet available |
| このURLは読み込めません | This URL cannot be read |

### S15 Edit link

**Purpose and entry:** Preview and edit every automatically filled field and choose visibility before saving. Reach from S14 or an existing link on S04/S13.

```text
[Cancel] Edit link                            [Save]
Original URL · Source [read-only source identity]
Title [                   ]
Description [             ]
Tags / Main language [source-dependent fields]
Opening text [            ]
Verified / Unverified
[Refresh from source]
Who can view this link?
( ) Everyone eligible  ( ) Compatible only  ( ) Private
Preview card · Identity warning
(Existing link: [Delete link])
```

**Elements:** All automatically filled fields are editable, including source-specific description, tags, language and opening text where present. Keep the actual source URL/reader identity read-only; only fetched title, description, language, tags and opening text are editable under `design.md`, **Unit 4 and 5 contract**. Verification itself is determined by the account/link rules, not an editable checkbox. A connected GitHub account verifies its repository links. Other links are verified under a website/social address on that verified GitHub profile; Qiita also qualifies if its linked GitHub ID matches. All others show Unverified. Only roughly the first 200 characters of opening or preview text are stored. **DEFAULT:** descriptions are also capped at 200 characters, following `design.md`, **Link readers**. GitHub uses name, description, main language and README opening; Qiita uses title, tags and opening; Zenn uses title and opening or page preview; other pages use title and preview description. No full article body is displayed. Show a preview and identity warning before saving. New links have three unselected visibility choices; existing links retain their explicit choice.

**States:** Empty: missing required title or visibility → inline guidance and unavailable Save; absent optional metadata is allowed. Loading: save or refresh progress. Error: save/refresh failure preserves the edited card. **DEFAULT:** refresh presents replacement values before they overwrite edits; confirm replacement or cancel. Prerequisite-removal protection follows `design.md`, **Unit 3 contract**; link editing remains Unit 5. Deleting the last link requires turning discovery off on S16 first.

**Actions:** Edit/select visibility stays on S15. Save → S04 or S13, its origin, after success. Refresh → S15 replacement confirmation/preview, then same. Delete existing link → confirmation → S13 (S04 if edited in onboarding); Cancel deletion stays S15. Removing a link removes in-app access, not the original or copied URLs. Cancel new link → S14; Cancel existing edit → S04/S13, its origin, with discard confirmation when needed. Discovery prerequisite guidance → S16. Retry stays S15.

| Japanese | English |
|---|---|
| リンクを編集 | Edit link |
| 元のURL | Original URL |
| 掲載元 | Source |
| タイトル | Title |
| 説明 | Description |
| タグ | Tags |
| 主な言語 | Main language |
| 冒頭のテキスト | Opening text |
| 掲載元から更新 | Refresh from source |
| このリンクを誰に公開しますか？ | Who can view this link? |
| 公開範囲を選んでください | Choose a visibility level |
| プレビュー | Preview |
| 編集した内容を置き換えますか？ | Replace your edits? |
| リンクを削除 | Delete link |
| 元のページやコピー済みのURLは削除されません | The original page and copied URLs are not removed |

### S16 Discovery and matching

**Mockup:** [images/s16-discovery-matching.png](images/s16-discovery-matching.png)

**Purpose and entry:** Control discovery and the conditions for compatible-only fields. Reach from the Settings list, feed status or S24/prerequisite guidance.

**FACT:** the built screen edits matching/threshold and permits turning discovery off, but activation is unavailable even after the S05 explanation; the full activation flow below waits for link flows. See **Navigation** for current entry/return.

```text
[Back] Discovery and matching
Discovery [off / on]
Required profile and link checklist
Purposes [Discovery] [Collaboration]
Shared-interest threshold [1]
Matching orders encounters; it does not hide them.
[Save matching settings]
```

**Elements:** Master discovery switch, missing-prerequisite links, purposes and adjustable shared-interest threshold following the binding interim range under **Navigation** (initial value remains 1). In Unit 3, activation remains unavailable under the owner account decision on `S01`; missing-link destinations await Unit 5. Display name, introduction, at least one interest and at least one link of any kind are necessary for activation. Purposes default to everyone eligible once discovery is on; change their visibility on S17. Show the S05 promise/limitations in concise help before activation if onboarding explanation was not completed. No background/foreground mode selector or location switch.

**States:** Empty: prerequisites missing, with precise completion links. Loading: load/update settings; do not claim activation until success. Error: save failure restores the last confirmed switch state; Bluetooth unavailable → S23. The final threshold range remains open; interim controls follow **Navigation**. Discovery off hides cards under S24 but does not erase them.

**Actions:** Enable discovery → stays on S16 after success; next Discover visit → S06/S25. Missing basics/interests → S12; missing link → S13. Bluetooth issue → S23. Disable discovery → S24 in Discover under a drafting default; current visibility immediately stops access in both directions. Save matching settings stays on S16 and reorders eligible encounters without removing incompatible ones. Back → whichever screen opened S16: Settings list, S06, S12, S15, S20, S23 or S24. Retry stays S16.

| Japanese | English |
|---|---|
| 発見・マッチング | Discovery and matching |
| 発見 | Discovery |
| 必要な情報を入力してください | Complete the required information |
| 利用目的 | Purposes |
| 共通の興味の条件 | Shared-interest threshold |
| 共通の興味が{count}件以上 | At least {count} shared interests |
| 条件は表示順と公開範囲に使われます。すれちがい自体は非表示になりません。 | Matching affects order and visibility. It does not hide encounters. |
| マッチング設定を保存 | Save matching settings |

### S17 Visibility

**Purpose and entry:** Control field visibility and explain its effect on all encounters. Reach from the Settings list, S11 or S12.

```text
[Back] Visibility
Display name       [Everyone eligible / Compatible only / Private]
Introduction       [same three choices]
Interests          [same three choices]
Purposes           [Everyone eligible initially; same three choices]
Contact detail     [Private initially]
[Link visibility → My links]
Changes also apply to past encounters and saved items.
[Save visibility]
```

**Elements:** Three-level selectors for profile fields; the link selector route on S15 will arrive in Unit 5 under **Navigation**. Display name, introduction, interests and purposes start at everyone eligible once discovery is on. Contact starts private. Links require an explicit selection with no default. Explain eligibility and compatibility beside the controls. Visibility updates apply in both directions to past cards, favorites and saved links.

**States:** Empty: optional contact is not set; keep its private choice available for future entry. Loading: load/save settings. Error: preserve choices with Retry; do not imply a failed write changed access.

**Actions:** Select choices/Retry stays S17. Save visibility stays S17 after success. Link visibility → S13 → S15; return via S13 to S17. Back → Settings list, S11 or S12, its origin; unsaved changes use the common discard confirmation.

| Japanese | English |
|---|---|
| 公開範囲 | Visibility |
| 表示名 | Display name |
| 自己紹介 | Introduction |
| 興味 | Interests |
| 利用目的 | Purposes |
| 連絡先 | Contact detail |
| リンクの公開範囲 | Link visibility |
| 過去のすれちがいや保存した項目にも適用されます | Changes also apply to past encounters and saved items |
| 公開範囲を保存 | Save visibility |

### S18 Daily report

**Purpose and entry:** Set the daily reveal time and notification preference. Reach from the Settings list.

```text
[Back] Daily report
Report time [21:00] · Local time
(If push is available: Notifications [current preference: off / on])
(System notification status / [Open iOS Settings])
(If push is unavailable: In this build, read your report in the app.)
Ambient encounters appear together at report time.
No report on days without encounters.
[Save report time]
```

**Elements:** Local-time picker defaulting to 21:00, notification toggle and iOS permission status. Turning notifications off does not stop daily reveal in the app. The notification uses up to two currently authorized display names and counts the remaining authorized names, with neutral report-ready text when no name is authorized; see **Daily report notification**. There is no weekly option or immediate ambient option in release. S05 requests permission just after discovery is enabled; this screen reflects that choice and lets the user change it later. If permission was not requested, enabling notifications here requests it. If denied, show the iOS Settings recovery action rather than repeatedly prompting. Skip requests and omit the nonfunctional toggle when push is unavailable.

**States:** Empty: permission may have been declined or not requested; explain in-app report access without implying discovery is broken. Loading: load/save or await permission. Error: save failure with Retry, or denied system permission with an iOS Settings link. The free-account friends test has no push; show in-app report behavior without a nonfunctional notification control.

**Actions:** Change time/Save report time stays S18 after success. Enable notifications → system permission sheet if not yet requested → S18; if denied, use iOS Settings. Disable notifications stays S18 without disabling reveal. Open iOS Settings → system, return S18. Back → Settings list. Retry → S18.

Scheduling follows the defaults in `design.md`, **Daily report delivery**: register a validated IANA time zone on sign-in, foregrounding and zone changes; the latest foreground registration wins across devices. Defer scheduling if no valid zone is available. Daylight-saving gaps use the first valid minute after the chosen time; repeated times use the first occurrence once. Travel uses local calendar dates: a backward zone change cannot repeat a completed date, and a forward change recomputes the next due date. At confirmation, assign the next report date, today before the cutoff or the next day otherwise. Time/zone changes move waiting encounters to the next future local report without immediate reveal. Late confirmations wait for their assigned next report and keep their original encounter dates; completed empty dates remain closed. Reveals are per viewer, and outages may delay delivery. These are source drafting defaults, not an exact push-delivery guarantee.

| Japanese | English |
|---|---|
| 毎日のレポート | Daily report |
| レポートの時刻 | Report time |
| 現地時間 | Local time |
| 通知 | Notifications |
| 通知には、あなたに公開されている名前が表示されます | Notifications show names shared with you |
| 時刻を変更しても、待機中のすれちがいはすぐには表示されません | Changing the time does not reveal waiting encounters immediately |
| このビルドでは、レポートはアプリ内で確認できます | In this build, read your report in the app |
| 通知がオフでも、アプリ内でレポートを確認できます | Your report is available in the app even with notifications off |
| すれちがいがない日は届きません | No report on days without encounters |
| レポートの時刻を保存 | Save report time |
| iOSの設定を開く | Open iOS Settings |

### S19 Blocked users

**Purpose and entry:** Review and remove blocks. Reach from the Settings list.

```text
[Back] Blocked users
Opaque block reference · Block placement day [Unblock]
Opaque block reference · Block placement day [Unblock]
Unblocking does not restore deleted encounters.
```

**Elements:** A minimal block list and unblock controls, showing only opaque block reference and the viewer-local block placement day, without encounter history, encounter dates/times/places, profile cards or link previews; exact wire output is in `design.md`, **Unit 4 and 5 contract**. How to identify a blocked account without bypassing visibility remains an open item; “Blocked account reference” is a layout placeholder, not final copy or a promise to retain the person's name.

**States:** Empty: No blocked users. Loading: neutral rows. Error: Retry loading or unblocking; keep the block effective until removal succeeds.

**Actions:** Unblock → confirmation → S19 after success; it does not restore an encounter removed by blocking. Cancel confirmation stays S19. Back → Settings list. Retry → S19. No blocked row opens S07.

| Japanese | English |
|---|---|
| ブロックした相手 | Blocked users |
| ブロックした相手はいません | No blocked users |
| ブロックを解除 | Unblock |
| ブロックを解除しますか？ | Unblock this user? |
| 削除されたすれちがいは復元されません | Deleted encounters are not restored |

### S20 Account

**Purpose and entry:** Sign out or permanently delete the account inside the app. Reach from the Settings list.

```text
[Back] Account
Sign-in: Apple (development may show Temporary account)
Linked identity: GitHub connected / Not connected
(When connected: [Disconnect GitHub])
[Sign out]
[Delete account] (destructive)
Deletion is immediate and permanent, with a disclosed safety exception.
```

**Elements:** Sign-in status, linked GitHub verification status, Disconnect GitHub, sign-out and in-app deletion. GitHub is not a replacement sign-in method. **DEFAULT:** after confirmation, Disconnect GitHub makes links verified through that GitHub account unverified and removes repository link cards read through it. If removal would delete the last link while discovery is on, the server rejects the change; turn discovery off first. A development temporary account warning explains that reinstalling is not a durable identity.

Deletion retains only a one-way hash of the Apple account identifier together with operator moderation outcomes and blocks other people placed on that account, for the period stated in the privacy policy, and re-applies them if the same Apple identity signs up again. Nothing else survives; the hash cannot be reversed and holds no name, profile field, link, token, encounter or contact detail. A block is dropped when the person who placed it deletes their own account. The privacy policy and the deletion confirmation both disclose this exception; the exact period is an open item to settle with the legal review.

**States:** Empty: GitHub not connected is valid. Loading: process disconnect/sign-out/deletion with repeated actions disabled. Error: retain the account screen and offer Retry; never claim deletion succeeded while offline or after a failed request. **DEFAULT:** while deletion is pending, suspend local participation/protected reads and offer actionable Retry; server deletion is transactional and a preflight/SQL failure never claims success. Exact failure handling is in `design.md`, **Unit 4 and 5 contract**, **Account deletion and cleanup**. On auth expiry, return S01 without claiming deletion.

**Actions:** **DEFAULT:** Disconnect GitHub → confirmation explaining verification loss and repository-card removal → S20 after success; prerequisite rejection → guidance to S16 to turn discovery off first. Sign out → confirmation → S01 after success; it does not delete the account. Delete account → destructive confirmation describing immediate, permanent deletion of personal data and the safety exception in the bilingual wording below → S01 after success, with no grace period or recovery flow. Cancel stays S20. Back → Settings list. Retry → S20. Sign-out stops local radio participation, clears local cards, receipts and token batches, and removes that installation's push association; deletion also removes all push associations and queued notifications (`design.md`, **Bluetooth transport**, **iOS app structure**, **Daily report delivery** and **Retention and deletion contract**). **DEFAULT:** active-session interruptions and trial/demo clearing follow `design.md`, **Unit 4 and 5 contract**, **Sessions** and **Account deletion and cleanup**; no continued signed-out access is displayed.

| Japanese | English |
|---|---|
| アカウント | Account |
| サインイン方法 | Sign-in method |
| 一時アカウント | Temporary account |
| GitHub連携 | GitHub connection |
| GitHub連携を解除 | Disconnect GitHub |
| 連携を解除すると、このアカウントで確認されたリンクは未確認となり、読み込んだリポジトリのリンクカードは削除されます。 | Disconnecting makes links verified through this account unverified and removes repository link cards read through it. |
| 未連携 | Not connected |
| サインアウト | Sign out |
| アカウントを削除 | Delete account |
| 個人データはすぐに完全削除され、元に戻せません。安全のための唯一の例外として、Appleアカウント識別子を元に戻せない一方向ハッシュにした値と、運営者の対応結果、他の人があなたに設定したブロックだけを、プライバシーポリシーに記載した期間保存します。同じAppleアカウントで再登録すると、対応結果とブロックを再適用します。それ以外は何も残りません。名前、プロフィール項目、リンク、トークン、すれちがい、連絡先は保存しません。ブロックした人が自分のアカウントを削除すると、そのブロックも削除します。 | Your personal data is deleted immediately and permanently. This cannot be undone. The only safety exception is that we keep a one-way hash of your Apple account identifier, operator moderation outcomes and blocks other people placed on your account for the period stated in the privacy policy. The hash cannot be turned back into your Apple identifier. If you sign up again with the same Apple identity, we re-apply those outcomes and blocks. Nothing else survives: no name, profile field, link, token, encounter or contact detail. A block is dropped when the person who placed it deletes their own account. |
| この一時アカウントは、再インストールすると維持できません | This temporary account does not survive reinstalling |

### S21 Legal and support

**Purpose and entry:** Read legal documents and find the operator's published support/moderation contact. Reach from the Settings list or legal links on S01, including before sign-in.

```text
[Back] Legal and support
[Terms]
[Privacy policy]
[Support]
Moderation contact: published address
Engineer Encounters · App version
```

**Elements:** Japanese and English legal/support pages, operator contact and app version. Explain no location collection, date-only encounter records, retention and deletion, including the S20 safety exception and its retention period, in the linked privacy policy. Do not present unfinished legal review or unresolved retention periods as settled. No other user's information appears here.

**States:** Empty: a public build must have working published URLs and contact; missing content is a release prerequisite, not an empty legal page. Loading: external page loading. Error: show the URL/contact and retry if a page cannot open.

**Actions:** Terms/privacy/support → browser, return S21. Contact → email composer or copy the published address, return S21; opening a composer never sends automatically. Back → Settings list or S01, its origin. Retry → S21/external page.

| Japanese | English |
|---|---|
| 法務・サポート | Legal and support |
| 利用規約 | Terms |
| プライバシーポリシー | Privacy policy |
| サポート | Support |
| 通報に関するお問い合わせ | Moderation contact |
| お問い合わせ | Contact support |
| アドレスをコピー | Copy address |
| アプリのバージョン | App version |

### S22 Diagnostics

**Purpose and entry:** **FACT:** S22 retains local radio diagnostics with Unit 3's diagnostics-only Sign out action. Build reachability and return routes are defined in **Navigation**. Release excludes the screen/resources/sharing; the event uses the release configuration and Apple sign-in after Unit 7.

```text
[Back] Diagnostics
Development build / Internal build
App version and build / iOS version / Device model
Bluetooth / Discovery / Own session (Unavailable)
(Participation paused for lack of a token / Storage unavailable)
Discovery [Off / On]
Presence approach [Held connection / Second exchange]
[Reset trial]  (Reset confirmed / Reset failed)
Elapsed values from trial start
  Trial number / Trial start reason (Reset / Participation switch / App launch)
  (Presence approach changed during trial)
  Discovery elapsed / Distinct peers observed
  Exchange entries dropped beyond limit / Evidence entries dropped beyond limit
  Exchange completion elapsed / Role / Exchange digest
  Two-minute evidence elapsed / Role / Exchange digest / Observed duration
  One-sided local evidence: the other device's evidence is unverified
  Server confirmation elapsed (Unavailable)
  Attempt end reason and elapsed
Recorded trials [date, trial number and start reason; expandable metadata and measurements]
Local diagnostic summary
  Pending receipt count / Valid token available / Recorded trials
  [Refresh] [Share trial log]
(Signed in: [Sign out])
(Sign-out failure: retry local cleanup)
Immediate ambient demo [Off / On]
(When on: Test only: reveals and notifies ambient encounters immediately)
```

**Elements:** **FACT:** the local participation switch is labelled 発見 / Discovery and defaults off. It permits no-account Development radio trials independently of product discovery; its first use creates the Bluetooth managers and triggers the Bluetooth permission prompt. The persisted flag recreates the runtime in App.init on relaunch when on, including state restoration. Own session is unavailable and the session flag source is false until sessions exist. Signed-in accounts use server tokens; signed-out Development uses local test tokens (12 hours of aligned 15-minute windows). Internal/Release cannot establish a new account before Unit 7. Issuer/upload integration follows `design.md`, **Unit 3 contract**.

S22 shows build/app/iOS/device status, Bluetooth availability, discovery status, storage/token status lines, the presence-approach selector, Reset result, trial number and start reason, first discovery elapsed and distinct-peer count. Each exchange has role, exchange digest and elapsed time; each evidence entry has role, exchange digest, elapsed time, observed duration and the one-sided-evidence note. The exchange digest is the first 8 hexadecimal characters of SHA-256 of the exchange nonce. Attempt endings include role, reason and elapsed time. Recorded trials expand to show their metadata, discovery state at start, battery level and measurements; a presence-approach-changed flag marks a change during the trial. The local summary shows pending receipt count, valid token availability and trial count. Limits are 200 exchanges and 200 evidence entries per trial, 200 trials and the newest 50 attempt endings; dropped-entry counters remain visible.

A trial starts when Reset succeeds, at the local participation switch, or at app launch with participation already on. Elapsed values count from that start. Only trials whose start reason is reset count for the radio check. The owner compares exchange digests and two-minute evidence on both screens; S22 cannot confirm the other device’s evidence. The two-receipt test check lives only in the test-support library, never linked into the app. Server receipt resolution is built, but S22 still has no server-confirmation elapsed measurement or on-device two-receipt harness. In second-exchange trials, the first exchange of each pair stays pending while the trial is open, because evidence is recorded under the second exchange digest; after closure an unmatched entry shows missing. Showing which first exchange an evidence entry completes is undecided and not built.

Share trial log uses the system share sheet with the local file. The source and shared log contain dates, elapsed values and exchange digests, without participant identities, raw tokens, receipts, credentials, encounter times or places. Accepted privacy risk: matching digests in two shared logs reveal that their owners met (Development/Internal only). **DEFAULT:** keep diagnostics 7 days. **FACT:** Unit 2 prunes on launch, writes and Refresh, protects files after first unlock and excludes the directory from backup; trial-log/demo clearing is specified but unbuilt under `design.md`, **Unit 4 and 5 contract**. Radio procedures belong in `design.md`, **Test plan**.

The demo toggle and test-only warning are built and persisted, but the setting has no reveal/notification consumer yet. **DEFAULT:** its planned consumer, local notifications and non-production server gate follow `design.md`, **Unit 4 and 5 contract**, **Daily reveal and demo**, preserving confirmation rules.

**States:** **FACT:** no open trial or no recorded trials shows No diagnostic data yet. Loading shows Loading… and disables repeated actions. A log/storage failure shows Cannot read or write local diagnostic data with Retry; storage and lack-of-token lines explain why participation is unavailable. Missing values in an open trial show Pending, in a closed trial Missing, and recorded measurements show elapsed seconds. Unavailable server confirmation and own-session status are never simulated as successful. Sharing is disabled until the log is ready and while an action is loading. Reset confirmed or Reset failed appears only after the operation returns.

**Actions:** **FACT:** the participation switch starts/stops local participation and closes the trial when turned off. Reset stops the engine, cancels connections, clears pending attempts, nonce state and receipts, verifies the queue is empty, starts the recorder’s new clock and restarts discovery if participation is on. Success includes durable trial recording; failure does not claim a clean next trial. Select the presence approach before Reset; changes affect new attempts and mark an existing trial as changed. Refresh prunes the log and refreshes engine/token deadlines and the local summary; Retry retries local diagnostics/storage. These actions, the recorded-trial disclosures and the demo toggle stay on S22. Share trial log → system share sheet, return S22; cancellation sends nothing. Back returns to the invoking root under **Navigation**. Sign out clears the current account and returns to S01; failed deletion shows a cleanup error and the durable marker prevents restoration until Retry completes deletion.

**FACT — implemented on 2026-10-12:** second exchange is the default and an earlier stored held connection choice is kept, so both S22 selectors must match before a trial.

**FACT — implemented on 2026-10-12:** after an exchange this phone started reaches two-minute evidence, it does not dial that peer for 15 minutes. Reset clears the pause on this phone only; turning the local participation switch off and on keeps it. S22 shows no indication that a pause is active: the change added no event or screen element.

**FACT — fake transport test, 2026-10-12:** under second exchange a Reset while the other phone is still waiting shows one attempt ending with an invalid frame and a first exchange about 10 seconds later.

Reset both phones as close together as possible; **UNVERIFIED:** sequential Reset can delay evidence, from code review and not tested; see `design.md`, **160-trial matrix and procedure**, step 2.

For the binding owner decisions of 2026-10-11, their reasons, the **DEFAULT** pause scope and **UNVERIFIED** background resumption, see `decisions.md`, **Bluetooth transport**; the static security review, verification of 2026-10-12 and open risks are recorded in `decisions.md`, **Retention and deletion contract**.

Labels below are verbatim from `ios/App/Diagnostics/ja.lproj/Diagnostics.strings` and `en.lproj/Diagnostics.strings`:

| Japanese | English |
|---|---|
| 診断 | Diagnostics |
| 開発ビルド | Development build |
| 内部テストビルド | Internal build |
| 診断データはまだありません | No diagnostic data yet |
| 更新 | Refresh |
| 試行をリセット | Reset trial |
| リセット完了 | Reset confirmed |
| リセット失敗 | Reset failed |
| 存在確認の方式 | Presence approach |
| 接続を維持 | Held connection |
| 2回目の交換 | Second exchange |
| 発見までの経過時間 | Discovery elapsed |
| 交換完了までの経過時間 | Exchange completion elapsed |
| 2分間の証拠取得までの経過時間 | Two-minute evidence elapsed |
| サーバー確認までの経過時間 | Server confirmation elapsed |
| 記録した試行 | Recorded trials |
| 試行ログを共有 | Share trial log |
| 通常のすれちがいを即時表示するデモ | Immediate ambient demo |
| テスト専用：通常のすれちがいをすぐに表示・通知します | Test only: reveals and notifies ambient encounters immediately |
| 利用できません | Unavailable |
| 再試行 | Retry |
| 読み込み中… | Loading… |
| 発見 | Discovery |
| オン | On |
| オフ | Off |
| ビルド | Build |
| アプリのバージョン・ビルド | App version and build |
| iOSのバージョン | iOS version |
| 端末モデル | Device model |
| Bluetooth | Bluetooth |
| 自分のセッション | Own session |
| 試行開始時の発見 | Discovery at trial start |
| トークンがないため発見を一時停止 | Participation paused for lack of a token |
| ストレージを利用できません | Storage unavailable |
| バッテリー残量 | Battery level |
| 試行開始からの経過時間 | Elapsed values from trial start |
| 発見した端末の数 | Distinct peers observed |
| 端末内の診断概要 | Local diagnostic summary |
| 保留中の受領記録の数 | Pending receipt count |
| 有効なトークン | Valid token available |
| 端末内の診断データを読み書きできません | Cannot read or write local diagnostic data |
| 保留中 | Pending |
| 未取得 | Missing |
| 記録済み | Recorded |
| 利用可能 | Available |
| 未確認 | Unknown |
| Bluetoothの使用が許可されていません | Bluetooth permission is denied |
| 役割 | Role |
| セントラル | Central |
| ペリフェラル | Peripheral |
| 交換のダイジェスト | Exchange digest |
| 観測した継続時間 | Observed duration |
| この端末の証拠のみ：相手側の証拠は未確認 | One-sided local evidence: the other device's evidence is unverified |
| 試行の終了理由・経過時間 | Attempt end reason and elapsed |
| 証拠取得 | Evidence reached |
| 接続待ち時間切れ | Connect timeout |
| 操作待ち時間切れ | Operation timeout |
| 失敗 | Failed |
| 無効なデータ | Invalid frame |
| 切断 | Disconnected |
| 期限切れ | Expired |
| 停止 | Stopped |
| トークンなし | No token |
| ストレージのエラー | Storage failure |
| 試行番号 | Trial number |
| 試行の開始理由 | Trial start reason |
| リセット | Reset |
| 発見スイッチ | Participation switch |
| アプリ起動 | App launch |
| 試行中に存在確認の方式を変更 | Presence approach changed during trial |
| リセットによる終了 | Ended by reset |
| 上限を超えて記録しなかった交換の数 | Exchange entries dropped beyond limit |
| 上限を超えて記録しなかった証拠の数 | Evidence entries dropped beyond limit |

### S23 Bluetooth off or permission denied

**Purpose and entry:** Explain why Bluetooth discovery cannot run and offer recovery or QR. Appear from S05, S06, S08 or S16 when Bluetooth is unavailable.

```text
Bluetooth is unavailable
(Bluetooth is off / Bluetooth permission is denied)
[Open iOS Settings] [Try again]
[QR exchange] (if discovery is on)
[Discovery settings]
(Authorized existing feed remains below in Discover)
```

**Elements:** Distinguish radio-off and permission-denied messages. Never claim the app can turn on Bluetooth directly. QR does not need Bluetooth; current profile and discovery eligibility still apply. Do not request location or imply an immediate encounter was missed.

**States:** Empty: no Bluetooth encounters, but use the same recovery guidance without candidate counts. Loading: checking current permission/radio status. Error: if status cannot be checked, show Retry; if denied, avoid repeatedly invoking the system permission prompt.

**Actions:** Open iOS Settings → system, return S23 and recheck. Try again → originating S05, S06, S08 or S16 when ready; otherwise stays S23. QR → S09 if discovery is on, otherwise S24. Discovery settings → S16. Back/dismiss → origin; in S06 the unresolved status remains visible. Tabs remain available outside onboarding.

| Japanese | English |
|---|---|
| Bluetoothを利用できません | Bluetooth is unavailable |
| Bluetoothがオフです | Bluetooth is off |
| Bluetoothの使用が許可されていません | Bluetooth permission is denied |
| iOSの設定を開く | Open iOS Settings |
| もう一度確認 | Try again |
| QR交換 | QR exchange |
| 発見の設定 | Discovery settings |

### S24 Discovery off

**Purpose and entry:** Make the master-off state clear and show how to enable it. Appear after Not now on S05, turning discovery off, or trying session/QR/favorites while off.

```text
Discovery is off
You are not taking part in encounters.
[Enable discovery]
(Missing basics: [Edit profile])
(Missing link: [My links])
You can still edit your profile and settings.
(New user: Sample encounter [View sample] [Dismiss sample])
[Discover] [Profile] [Settings]
```

**Elements:** An explicit off status and prerequisite guidance. Do not show another person's live or retained card, including favorites, while ineligible. Off does not erase existing encounters, pause their ordinary expiry, or silently turn into a session. Own-profile editing remains available. New users also see the clearly labelled local sample from S25 even if they defer discovery; this fictitious example is not another person's card.

**States:** Empty: the off explanation is the content; do not imply new encounters will arrive. Loading: checking own prerequisites/settings. Error: Retry reading settings; remain off until activation is confirmed.

**Actions:** Enable discovery → S16 for validation and explicit activation; Bluetooth issue there → S23. Edit profile → S12; My links → S13. View sample → S07 in sample mode, then Back → S24. Dismiss sample stays S24. Retry stays S24. Discover → S06 containing S24 until enabled; Profile → S11; Settings → plain list. After activation, Discover → S06/S25.

| Japanese | English |
|---|---|
| 発見はオフです | Discovery is off |
| すれちがいには参加していません | You are not taking part in encounters |
| 発見をオンにする | Enable discovery |
| プロフィールを編集 | Edit profile |
| 自分のリンク | My links |
| プロフィールと設定は編集できます | You can still edit your profile and settings |
| サンプルのすれちがい | Sample encounter |
| サンプルを見る | View sample |
| サンプルを閉じる | Dismiss sample |

### S25 Empty feed with the sample encounter

**DEFAULT:** fixture/dismissal lifecycle follows `design.md`, **Unit 4 and 5 contract**, **iOS client and navigation**; dismissal survives sign-out/account deletion for this installation.

**Purpose and entry:** Explain an empty revealed feed and provide one clearly labelled example. Appear within S06 for a new user or when no accessible revealed encounters remain.

```text
No encounters to show yet
Ambient encounters arrive in your daily report.
[Sample encounter]
  Fictional engineer · Example work
  [View sample] [Dismiss sample]
[Start session] [QR exchange]
```

**Elements:** Calm empty wording, daily-report explanation and one fictitious sample card. The source drafting default keeps the sample on the device and allows dismissal. It is not counted as an encounter or mixed into a real day group. Do not reveal waiting ambient candidates or report their number. If the sample has been dismissed, retain the guidance and session/QR actions without recreating it automatically.

**States:** Empty: this is the empty state; after dismissal, no sample card. Loading: S06's neutral loading view before declaring the feed empty. Error: S06's Retry rather than a misleading No encounters message. Sample data is local; it is not blocked by a failed network load of the real feed.

**Actions:** View sample → S07 in clearly labelled sample mode. Dismiss sample stays S25. Start session → S08; QR → S09, with prerequisites routed to S24/S23. Retry → S06. Bottom tabs follow S06.

| Japanese | English |
|---|---|
| 表示できるすれちがいはまだありません | No encounters to show yet |
| 通常のすれちがいは毎日のレポートで届きます | Ambient encounters arrive in your daily report |
| サンプルのすれちがい | Sample encounter |
| 架空のプロフィールです | This is a fictional profile |
| サンプルを見る | View sample |
| サンプルを閉じる | Dismiss sample |
| セッションを開始 | Start session |
| QR交換 | QR exchange |

### S26 Report and block

**Purpose and entry:** Report harmful content or block an encountered account. Open as a sheet from S07's safety action; link impersonation reports use the same screen with that link as context.

```text
[Cancel] Report or block
Report reason
( ) Spam  ( ) Harassment or inappropriate content
( ) Impersonation  ( ) Other
[Submit report]
Reported people are hidden from you immediately.
[Block user] (destructive confirmation)
Blocking removes the encounter for both people.
```

**Elements:** Report reasons from the source drafting default, a submit action and separate block action. **DEFAULT:** impersonation is available only with a visible link passed from S07’s per-link action; the general account sheet guides the user to that action rather than submitting without a link. Its exact request fields are in `design.md`, **Unit 4 and 5 contract**. Reporting hides the person from the reporter immediately; under `design.md`, **Matching and visibility**, three distinct unresolved reporters hide the profile from everyone pending operator review within 72 hours. The reporter's hide remains while the report record is retained, including after resolution; global suppression ends only through operator action (`design.md`, **Retention and deletion contract**). State the review window without revealing counts or identities of reporters. A block removes the encounter for both people, even if favorited. Do not add a message to the reported person or a moderation dashboard.

**States:** Empty: no reason selected, Submit report unavailable. Loading: submit/report/block progress with repeated taps disabled; immediately conceal the reported person's card while submission is pending. Error: retain the reason and offer Retry; do not show a success receipt for a failed report. **DEFAULT:** in-memory pending hiding/Retry and fresh-authorization reopening follow `design.md`, **Unit 4 and 5 contract**, **Block and report**; no success is claimed before server acceptance.

**Actions:** Select reason stays S26. Submit report → immediate hiding, then S10 if the encounter was opened there, otherwise S06, after success. Block user → confirmation → the same S10/S06 destination after successful removal; cancel confirmation stays S26. Cancel sheet → S07 if still accessible; if already reported/removed → S10/S06. Retry stays S26. No reversal is offered for encounter removal; blocks can be reviewed on S19.

| Japanese | English |
|---|---|
| 通報・ブロック | Report or block |
| 通報理由 | Report reason |
| スパム | Spam |
| 嫌がらせ・不適切な内容 | Harassment or inappropriate content |
| なりすまし | Impersonation |
| その他 | Other |
| 通報を送信 | Submit report |
| 通報した相手はすぐに非表示になります | Reported people are hidden from you immediately |
| この相手をブロック | Block user |
| ブロックすると、2人のすれちがいと保存した項目が削除されます。 | Blocking removes the encounter and saved items for both people. |
| 通報を受け付けました | Report submitted |
| 公開停止になったプロフィールは、運営者が72時間以内に確認します | The operator reviews suspended profiles within 72 hours |

## Surfaces outside the app

### Daily report notification

Send only after the viewer's due confirmed ambient encounters are revealed, at the configured local report time (21:00 by default), under `design.md`, **Daily report delivery** and the scheduling rules on S18. Skip days with nothing eligible to reveal. Late-confirmed encounters retain their original encounter dates, so a report may cover more than one day group. Notification preference off suppresses the push, not in-app reveal. The free-account friends test reads the report in S06 without push. See `decisions.md`, **Reveal and notifications**, and `specification.md`, **Reveal and notifications**.

Use the public product name as title and show names in the body. **DEFAULT:** use the wording below for one, two, or three or more people. Immediately before notification handoff, re-check current visibility, discovery, blocks, deletion and moderation (`design.md`, **Daily report delivery**). Use only display names currently authorized for this viewer from encounters revealed in this report, counting each person once. Show at most two names; `{count}` is the number of remaining authorized named people, excluding private names and unrevealed encounters. If no display name is authorized, use the neutral report-ready body. Push jobs retain references, never frozen names or cards. Never include a time, place, nearby-person prompt or unrevealed count. Tap → S06 at the report's revealed day groups; authentication if needed → S01 → S06 after successful sign-in. No new numbered report screen is added.

```text
Engineer Encounters
Your daily report: {name1}
(Two: Your daily report: {name1} and {name2})
(Three or more: Your daily report: {name1}, {name2} and {count} more)
(No authorized names: Your daily report is ready.)
```

| Japanese | English |
|---|---|
| すれちがいエンジニア | Engineer Encounters |
| 毎日のレポート：{name1}さん | Your daily report: {name1} |
| 毎日のレポート：{name1}さん、{name2}さん | Your daily report: {name1} and {name2} |
| 毎日のレポート：{name1}さん、{name2}さん、ほか{count}人 | Your daily report: {name1}, {name2} and {count} more |
| 毎日のレポートが届きました | Your daily report is ready. |

There are no weekly or immediate ambient notifications in release. The S22 demo switch alone permits immediate ambient reveal/notification in development and internal builds. If push fails, revealed content remains available on S06; the interface does not promise exact notification delivery.

### Session Live Activity

Display the user's own active session for up to 2 hours. **DEFAULT:** show the public name, Session active and time remaining, with a Stop session control where supported. A compact presentation shows the status and remaining duration. Never show another person's name, encounter counts, card, encounter time or place.

```text
Engineer Encounters · Session active
Time remaining 1:25:00                 [Stop session]
```

Tap the body → S08. Stop uses the same immediate local stop as S08: clear the local session flag, queue the server stop and end the activity, even offline (`design.md`, **iOS app structure**). A failed upload never restores an active activity; open S08 for the queued-stop status and Retry. Expiry ends the activity; it does not start another session. Live Activity availability does not change confirmation or daily-report rules. It is not a nearby-person alert.

| Japanese | English |
|---|---|
| セッション中 | Session active |
| 残り時間 | Time remaining |
| セッションを停止 | Stop session |

### One-tap session control

`decisions.md`, **Sessions** and **User interface**, require a one-tap start control as a widget or Control Center control. **DEFAULT:** use a Control Center control labelled Start session. It invokes the same 2-hour start action as S06, without a confirmation when the account, completed setup, discovery and Bluetooth prerequisites are ready. Only server acknowledgement makes a new session active and opens its Live Activity. Offline starts show the S08 connection guidance (`design.md`, **iOS app structure**). Opening the control's app context → S08.

```text
[Start session]
(Already running: [View session])
```

If already running, open S08 without restarting or extending it. If signed out, open S01; incomplete onboarding → the unfinished S02–S05 step; discovery off → S24; Bluetooth unavailable → S23; a start failure → S08 with Retry. The control never activates discovery without consent or skips permission. Do not expose identities, encounter counts or pending results on it. Behavior when the device requires authentication is an open platform item, not a promise of bypassing the lock screen.

| Japanese | English |
|---|---|
| セッションを開始 | Start session |
| セッションを見る | View session |

## Changes from the concept screens

See `proposal.pdf`, pages 3–5, and `decisions.md`, **User interface**. Keep the teal accent, card layout, initial avatars, large titles, short subtitles and original-link actions.

| Concept | Current interface |
|---|---|
| 01 Discovery feed | S06 groups revealed cards by day and adds Start session, QR exchange and Favorites. Discovery wording distinguishes the app-open promise from unproven background behavior. No encounter time/place is shown. |
| 02 Encounter detail | S07 keeps authorized profile/common-interest/link blocks, removes the connection-request button, and adds favorite, save-link, deletion and S26 safety actions. The concept's role line is omitted because it is not a profile field. |
| 03 My links | The former tab becomes Profile (S11). My links is S13 beneath it, with S14/S15 for adding and editing. Keep the original-platform and identity warnings. |
| 04 Link visibility | S15 includes three explicit radio choices and editable source-filled preview fields. The mutual connections level and Allow AI processing toggle are removed. S17 handles profile-field visibility. |
| 05 and 06 | Both AI screens are removed, with no replacement screen or settings toggle. Source readers supply editable previews in S14/S15. |
| Tab bar | Remove Connections; use Discover, Profile and Settings. The Settings list leads to S16–S22, with S22 absent in release. |
| Added flows | S01–S05 onboarding, S08 session, S09 QR, S10 favorites, settings screens and shared states S23–S26 complete the 26-screen map. |

## Defaults chosen during drafting

**FACT** entries record built Unit 2/3 screens; the remaining entries are proposed UI choices, not additional features or confirmed owner decisions. They apply wherever referenced above. Product defaults already fixed by the sources—discovery off, report at 21:00 local time, the specified profile levels and private contact—are not drafting choices. Links still have no default visibility.

| Area | DEFAULT |
|---|---|
| Source defaults carried forward | Name up to 30 characters; introduction up to 200; curated interests without free text; initial avatars; up to 10 links; shared-interest threshold starts at 1. |
| Source feed-card default | Display name, shared interests, first authorized link, per-link verification, kind and day. Omit unauthorized/absent fields rather than inventing replacements. |
| Source safety and retention defaults | Four report reasons; one dismissible on-device sample; saved links follow favorites and vanish when their encounter is removed; development and internal diagnostics kept 7 days (`design.md`, **Retention and deletion contract**). |
| Wording and order | Built S01/S02/S03/S05/S12/S16/S17/S22 labels are app strings except the explicitly omitted sketch content; remaining bilingual labels, subtitles, examples, control order and sketches are drafting wording. Keep English sentence case, concise natural Japanese and locale-formatted days. Proper names retain their spelling. |
| Appearance and accessibility | Off-white/navy/white light palette, adaptive system dark surfaces, thin rounded borders, system symbols, semantic destructive color, visible labels and accessible icon names, wrapping/scrolling for Dynamic Type. No exact custom font sizes are fixed. |
| Navigation | Independent tab stacks, pushed details/editors, S26 sheet, shared-state panels in Discover, no tab bar during onboarding. Preserve form values when returning from a subflow. Resume incomplete onboarding. |
| Forms | Inline field errors, neutral progress, disable duplicate writes, explicit saves, retained input on failure. Save buttons require required fields; unsaved edits prompt before discarding. Source-reader failure is not successful import. |
| Purposes | No preselection; require at least one purpose during onboarding and subsequent edits. Users may select both supported purposes. This requirement does not add a fifth discovery prerequisite. |
| Onboarding prerequisites | The completed product route requires name, self-introduction, an interest, a purpose and a first link before S05. Unit 3 has built the selected screens under **Navigation**; link completion waits for Unit 5. |
| Unit 3 | **FACT:** built server validation and client detail belong in `design.md`, **Unit 3 contract**; the scope and interim controls under **Navigation** and token prerequisite on `S01` are binding owner decisions. |
| Friends-test backend | Development builds use hosted non-production Supabase; planned hosted anonymous sign-in enabled only there, disabled on production and compiled out of release; local anonymous Auth is already enabled. Local Supabase is for automated checks and the owner's own development. |
| Activation and required data | Built controls/returns: S05/S12/S16. Later link mutation checks must reject removing the last link while discovery is on. The completed Discover flow uses S24 after disabling; Unit 3 stays in Settings. |
| Feed order | Newer day groups first; within a day, compatible cards first, then shared-interest count, then stable encounter ID (`design.md`, **Matching and visibility**). Ineligible retained encounters are hidden from feed/favorites and return if eligible again within retention. Only eligible all-private cards use a non-identifying shell. Never display encounter times. |
| Favorites | S10 uses Encounters and Saved links segments; star/bookmark actions on S07 toggle without a confirmation. Unavailable content is removed rather than frozen in a saved snapshot. |
| Own-card preview | S11 starts with an eligible-viewer preview and offers a compatible-viewer preview. No audience selector represents a real person's access. |
| Link editing | One link per import; source-specific editable fields; title required; existing visibility retained; refresh confirmation before replacing edits. Source label editing does not alter source identity or verification; description also capped at 200 characters. |
| GitHub disconnect | S20 confirmation; dependent verified links become unverified and imported repository cards are removed, subject to server rejection if discovery is on and the last link would be removed. |
| Confirmations | Later product flows confirm encounter deletion, link deletion, blocking, unblocking, S20 sign-out and account deletion. Built S22 sign-out acts immediately. No success claim before the operation completes; session stop confirms the local stop while its server sync may remain queued. Starting/stopping a session has no extra confirmation. |
| Notification permission | Request on S05 immediately after discovery is enabled, with “Your daily report arrives as a notification”. Declining leaves discovery enabled. S18 changes the preference later and provides OS denial recovery. Skip requests when push is unavailable, including free-account development builds; read the report in-app. Daily reveal is independent of permission and preference. |
| Notification content | Public product name as title; body shows up to two currently authorized display names and counts the remaining authorized named people, using the one/two/three-or-more bilingual wording in Daily report notification. Use neutral report-ready text only when no name is authorized. No time, place or unrevealed count. Tap opens S06's revealed day groups. |
| Session surfaces | Countdown is the user's session duration only. Live Activity shows own status and remaining duration, with Stop where supported. Server acknowledgement starts a new session; offline cannot start one. Local stop immediately clears the flag, queues the server stop and ends the activity (`design.md`, **iOS app structure**). Start does not extend an already active session. |
| One-tap control | Choose Control Center rather than a widget for v1. Prerequisite failures open the corresponding app screen; they never silently enable discovery. |
| QR | Show/scan segments, explicit refresh invalidating the previous code, 2-minute validity and one outstanding code; reject self-scans; issue/redeem online (`design.md`, **Confirmed encounter, security definition**). Progress until server confirmation and camera-denial recovery. No peer identity before reveal. |
| Sample | Fictitious fields and safe example links; label S25 and S07, and reuse the sample in S24 for new users who defer discovery. Omit favorites, saving, deletion and report/block in sample mode. Do not recreate a dismissed sample automatically. |
| Diagnostics | **FACT:** Unit 2 built S22 local participation switch, reset with confirmation, presence selector, trial number/start reason, role/exchange digest, one-sided two-minute evidence, observed duration, attempt endings, dropped-entry counters, approach-changed flag and receipt/token/storage summary. Built reachability follows **Navigation**; Release excludes diagnostics. Server confirmation unavailable; sharing exposes matching digests. **DEFAULT:** 7-day retention. The demo is currently a persisted setting with a warning, without a reveal consumer. **FACT:** the three binding 2026-10-11 presence decisions were implemented on 2026-10-12; see S22 and `decisions.md`, **Bluetooth transport**. |
| Support | Use public web pages and an email composer/copy action for the published operator address. Opening a composer does not send a message. |

## Open items

- **Owner — interests and threshold:** supply the real curated interest list and threshold range; the retained scope decision fixes interim values.
- **Owner — token prerequisite:** revisit requiring discovery once onboarding/link flows exist; see S01's retained account decision.
- **Legal/UI texts:** supply legal texts, links and final version strings, plus the two S05 sketch headings; those links/headings are omitted until supplied.
- **DEFAULT — Unit 4/5 specified, implementation pending:** feed deduplication, deletion races, physical cleanup and diagnostics/demo clearing are settled in `design.md`, **Unit 4 and 5 contract**; these are no longer open design choices.
- **Unit 4 — short session evidence:** early discard and the smaller evidence budget remain undecided and are not built by that contract.
- **Owner — GitHub OAuth setup:** supply the GitHub OAuth app and backend callback for each environment; see `design.md`, **Unit 4 and 5 contract**.
- **UNVERIFIED — hosted Auth SQL:** Auth user hard-deletion and GitHub identity unlinking need hosted validation; see that contract.
- **Internal demo limit:** Internal cannot establish sign-in before Unit 7; the contract's demo notification is local only and its runnable demonstration uses Development accounts.
- **Bluetooth status follow-up:** engine powered-off state is unavailable; S05/S16/S22 already distinguish it through the app side channel. Keep that distinction consistent.
- **UNVERIFIED — app/backend:** the app has never been run against a backend in the simulator or on a device.
- **UNVERIFIED — hosted Supabase:** no hosted project has been exercised, including the anonymous sign-in setting.
- **Accepted Unit 3 review risks:** callers can learn whether an overheard token is live for another account; paired receipts do not prove distance; a counterpart changing zone can cause a second same-day card until feed deduplication. See `design.md`, **Security requirements** and **Unit 3 contract**.
- **Owner — blocked-person identification:** the contract defines only block reference/placement day on S19. Identification beyond those values remains open; no retained name or link preview is promised.
- **DEFAULT — report failure specified, implementation pending:** use `design.md`, **Unit 4 and 5 contract**, **Block and report** for local pending hiding/Retry and server acceptance.
- **DEFAULT — session interruptions specified, implementation pending:** S08/S20/app/extension follow `design.md`, **Unit 4 and 5 contract**, **Sessions**; device/control availability still needs validation.
- **One-tap and Live Activity availability:** Verify the chosen Control Center start action, authentication requirements and interactive stop on supported devices. Define the unavailable/disabled surface wording without claiming the control bypasses device security.
- **Unproven discovery behavior:** **FACT:** the 2026-10-11 iPhone 15/iPad (10th generation) check with Development/local test tokens passed rungs 3 and 4 with both approaches in both orientations, with the held-connection/iPad-locked result only a continuation without Reset. Both-locked evidence required waking a device. **UNVERIFIED:** background-to-background discovery (first exchanges preceded locking), rung 2, token-window-boundary, real loss-of-contact-and-return and iPhone-with-iPhone trials. Rungs 1 and 2 remain unproven and never promised; S05 keeps “may also work” and rung 3 remains the public promise subject to the release gate.
- **Diagnostics follow-up:** **FACT:** the three binding 2026-10-11 presence decisions were implemented on 2026-10-12; see S22 and `decisions.md`, **Bluetooth transport**. Delayed second connection with `CBConnectPeripheralOptionStartDelayKey` is unverified, undecided and not built; showing which first exchange an evidence entry completes is also undecided. Current reachability is under **Navigation**, and trial-log clearing is listed separately above. Shared-digest privacy follows S22.
- **UNVERIFIED:** device verification remains open before the matrix; see `design.md`, **160-trial matrix and procedure**.
- **FACT — fake transport test, 2026-10-12:** the Reset retry still needs an undecided, not built protocol change; see S22 and `decisions.md`, **Build, test and release path**.
- **UNVERIFIED — code review, not tested:** sequential Reset can delay evidence; see S22 and `design.md`, **160-trial matrix and procedure**, step 2.
- **Reader metadata:** Verify whether Zenn provides opening text; otherwise use its page preview as specified in `decisions.md`, **Rules for links**. S15 must not invent article-body content.
- **Public support and policy content:** Publish the supplied legal/support content and moderation address for S01/S21 (texts/links are the item above); settle resolved-report retention and the exact account-deletion safety-record period with the legal review, disclose that period and the S20 exception in the privacy policy and deletion confirmation, verify managed-service backup/log deletion behavior, and complete the legal review. Internal diagnostics already follow the 7-day default in `design.md`, **Retention and deletion contract**. See `decisions.md`, **Compliance deliverables**, **Retention and deletion contract** and **Open and unverified items**. No final address or unresolved retention period is invented here.
- **Public names:** Complete the trademark registry searches before release as required by `decisions.md`, **Product**. The screens use the selected public names without claiming registry clearance.

**Changes in v0.5 — 2026-10-12:**

- Point planned Units 4/5 behavior and the dated owner confirmation/demonstration-first order to `design.md`, **Unit 4 and 5 contract**; resolve affected source/navigation/safety contradictions and distinguish specified work from remaining owner/legal/validation items.
