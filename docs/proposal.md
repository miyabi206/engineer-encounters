> **Superseded (2026-10-10).** This document and `proposal.pdf` are superseded by `decisions.md` v0.3 as the authoritative record, together with `specification.md` v0.3, `design.md` v0.3 and `ui.md` v0.1. Both are kept for history. Pages 3 to 5 of `proposal.pdf` remain the visual starting point for `ui.md`. Main differences:
>
> - Public names Engineer Encounters / すれちがいエンジニア; 18+ launch, Apple sign-in, free v1 and Japan-first release.
> - Discovery and Collaboration only; three visibility levels; no connection requests. Editable source previews replace AI processing.
> - A five-rung ladder promises One open; ambient encounters require two minutes, while sessions and QR encounters reveal immediately.
> - A daily report, with immediate reveal for session and QR encounters, replaces the configurable notifications of the proposal.
> - Favorites, saved links, reporting, blocking and account deletion are in v1, with defined retention and moderation rules. A 160-trial matrix and staged friends, event and legal gates replace the proposed pilot path.

# Proposal - Engineer StreetPass

**Version:** 0.1  
**Date:** 9 October 2026  
**Status:** Proposal for feasibility-first development  
**Basis:** Supplied design.md v0.2 and specification.md v0.2  
**Platforms:** iOS first; Android later  
**Product languages:** Japanese and English

> Discover people, projects and opportunities you were not looking for.

This proposal synthesizes the supplied drafts. All UI screens in the accompanying PDF are conceptual, with fictional people and sample content; they are not screenshots of a working application. Additional pilot sizes, trial counts and release gates below are planning suggestions. Current platform behavior, model availability, prices and provider terms have not been independently verified for this proposal.

## 1. Executive proposal

### The idea

Engineer StreetPass turns physical encounters into opportunities to discover technical work, collaborators and careers. The proposed iOS app attempts to recognize nearby participating users, then reveals only the profile fields and external links each owner permits. Its mission is to help people discover people, projects and opportunities they were not looking for.

### The starting point

Start with engineering students and software developers in a small, opt-in community. Users add existing GitHub, Qiita, Zenn or personal-site links, select interests and purposes, and review relevant discoveries later. Reading someone's work is valuable even when neither person sends a connection request.

### The investment decision

Fund and build a Bluetooth proof of concept first. Continue to the product beta only after device testing establishes what the experience can reliably promise. Automatic discovery between two locked devices remains a research objective, not an established capability.

> Proposed outcome: meaningful technical discovery with minimal effort, voluntary connection and owner-controlled sharing.

## 2. Why this product should exist

### Problem hypothesis

People may share a campus, hackathon or engineering community without learning what those around them build. Introducing yourself takes effort, while searching a portfolio platform usually requires knowing whom or what to look for. This is a product hypothesis to validate through interviews and a pilot, not a measured market claim.

### Primary users and value

Engineering students can find approachable projects, collaborators and internship-related links. Software developers, open-source contributors and technical writers can surface work to people with shared interests. Researchers, community organizers, recruiters and startup founders are secondary audiences; they should not dominate the first pilot.

### Three purposes, one controlled profile

Discovery: explore projects and technical writing. Collaboration: meet people interested in hackathons, research or open-source work. Opportunity: discover professional profiles and owner-shared company, job or research links. Users can enable several modes and change them later.

### Positioning

The distinctive proposal is the combination of physical encounter context, explicit matching preferences and links to work that already exists. It avoids asking users to build another portfolio. It also avoids making a social connection a prerequisite for receiving value. Existing websites remain the authoritative source of each work.

### Initial launch hypothesis

Recruit one opt-in engineering community where participants are likely to encounter one another repeatedly. Explain discovery limits and visibility settings before participation. Expand only if users report useful discoveries and the device tests support the intended experience. No market-size, growth or revenue claims are assumed.

> Example journey: register a project link, carry the phone, review an eligible encounter, open the original work, optionally request a connection.

## 3. Discover work at your own pace

**PDF UI images:** 01 / Discovery feed; 02 / Authorized encounter detail.

### Experience

The feed highlights shared interests and technical works. The detail screen explains the common ground, opens the original source, and offers a voluntary connection request. An encounter itself never creates a connection.

### Product behavior

Use coarse recency rather than precise encounter timestamps; show no encounter map or exact location. Discovery status must acknowledge possible delay. When no eligible encounters exist, explain the state and offer settings without suggesting that nobody is nearby.

> Concept UI with fictional people and sample content. Connection requests belong to the extension stage.

## 4. Share links with clear boundaries

**PDF UI images:** 03 / Link-based profile; 04 / Per-link visibility.

### Ownership and control

Users add supported HTTPS links, titles, descriptions and interests. Each profile field and link has an independent visibility policy: all eligible encountered users, only compatible encountered users, mutual connections, or private. Sensitive contact details start private.

### Consent is specific

Explain that external links can identify their owners even when an in-app nickname is used. Sharing permission never implies AI-processing permission. Removing a link revokes in-app access and hides or invalidates its cached summaries; the external original remains unchanged.

> Concept UI. The backend enforces visibility; hidden fields are never sent to an unauthorized app client.

## 5. AI summaries with your approval

**PDF UI images:** 05 / Approve exact source input; 06 / Review the generated draft.

### Two deliberate approvals

First, the owner reviews the exact public technical excerpt to be sent for summarization. Second, the owner approves, edits or rejects the resulting draft before authorized viewers can see it. Changed source content requires renewed input approval before regeneration.

### Optional from end to end

The source documents propose Gemini 3.1 Flash-Lite through the Gemini Developer API; model availability, provider terms and any free-tier limits must be checked before integration. If AI is disabled or unavailable, the original link and user-written description remain usable. AI does not rank people or assess their competence.

> Concept UI. Encounter records, Bluetooth identifiers, locations, contacts, tokens and private content never go to Gemini.

## 6. A focused MVP, backed by trust

### P0 / Prove the mechanism

Build Core Bluetooth discovery and diagnostic logging. Test foreground, background and locked-device behavior, latency, duplicate events, false positives and battery usage before committing to ambient discovery claims.

### P1 / Make discovery useful

Deliver authentication, onboarding, connection purposes, technical interests, link registration, profile and per-link visibility, encounter history, rule-based matching, original-link opening and notification preferences. Japanese and English are the target product languages; the concept screens show English.

### P2 / Extend after the core works

Add optional AI summaries, saved links and connection requests. The specification groups reporting and blocking in P2; this proposal brings both forward as requirements for any beta with unrelated participants. Private messaging, Android, organization verification, recruiting dashboards, semantic recommendations and event-specific features remain future work. Portfolio hosting and document uploads are outside scope.

### Implementation approach

Use SwiftUI and Swift for the iOS app, Core Bluetooth for discovery, and SwiftData or SQLite for local records. Supabase Auth, PostgreSQL and Edge Functions provide authentication, storage and server-side rules. APNs supports notification delivery when available. The backend handles HTTPS metadata retrieval and optional Gemini calls; API keys stay on the server.

### Authorization and safety

Resolve encounters only after verification, mutual discovery permission, block checks and rule compatibility. Then evaluate each field and link separately. Investigate rotating temporary BLE identifiers and replay resistance within iOS constraints; never broadcast permanent account IDs or identifying links. Enforce access using restricted APIs and database policies. Validate retrieval destinations and redirects to resist SSRF; treat fetched text as untrusted data.

### User safeguards

Provide pause and disable controls, blocking, reporting, encounter deletion, account deletion and configurable notifications with quiet hours. Notifications must omit exact encounter times and locations. Define retention periods and deletion behavior before beta; do not expose a permanent movement history.

> Data path: minimal BLE exchange > local candidate > backend verification and eligibility > authorized profile fields and links.

## 7. Validate before promising automation

### Device experiment

Begin with iPhone 15 and iPad 10th generation running development builds. Test foreground/foreground, locked/foreground, foreground/locked, locked/locked, both backgrounded for more than 10 minutes, and both force-quit. Repeat each condition at encounter durations of 10, 30 and 120 seconds. Force-quit trials characterize a limitation; they are not a promise of continued operation.

### Measurement protocol - proposed

Before testing, define a repeatable encounter scenario and a negative control with no intended encounter. Run at least 20 trials per state-duration condition, record OS and app versions, distance and orientation, and report each condition separately. Compare idle battery use with discovery enabled and disabled over matched observation windows. The proposed trial count is a planning baseline, not a statistical guarantee.

### Evidence to collect

Measure detection success rate as confirmed eligible encounters divided by scripted eligible encounters, and report detection latency, duplicate and false-positive rates, plus incremental battery use. Keep raw BLE detections separate from verified encounters. Obtain two modern iPhones for a second test round: successful iPhone-to-iPad experiments do not establish phone-to-phone reliability.

### Gate A / Technical feasibility

Pre-register acceptable success, delay and battery thresholds for the intended use case before evaluating results. Continue with ambient discovery only if repeated iPhone-to-iPhone trials meet them. If locked-device performance is inadequate, narrow the product claim and explicitly propose a foreground-assisted pilot for review; do not silently substitute it for the desired experience.

### Gate B / Privacy and product readiness

Verify unauthorized field and link access is denied, block relationships prevent exposure, AI has both approvals, source changes invalidate consent, removed links and summaries are unavailable, and deletion behavior matches the published policy. Resolve release-blocking privacy failures before inviting unrelated users.

### Open decisions

Select the minimum supported OS, finalize the BLE identifier and verification protocol, define retention and notification defaults, and clarify the distinction between baseline eligibility and preference compatibility. These must be explicit before implementing matching and visibility policies.

> Core uncertainty: both-locked background discovery. Avoid claims of guaranteed encounters, deterministic wake-ups or immediate notifications.

## 8. Delivery and success criteria

### Milestone 1 / Bluetooth proof of concept

Produce a reproducible device test report, battery observations and a feasibility decision. This is the first commitment; later milestones depend on the evidence.

### Milestones 2-3 / Product foundation and discovery

Build navigation, authentication, onboarding, interests and settings; then link management, visibility, encounter history and matching. Demonstrate the complete journey with controlled participants. Bring forward blocking, reporting and core privacy tests before an external beta.

### Milestones 4-5 / Optional AI and beta

Add source preview, explicit AI consent, summary review and caching after the non-AI journey works. Run a small opt-in beta, refine notification preferences and evaluate voluntary connections. AI can be deferred without blocking core validation. Set dates after the proof of concept and confirmation of developer capacity.

### Resources and operating model

Plan for an iOS developer with backend capability, design and test time, the existing iPhone/iPad pair, and access to a second modern iPhone. Budget categories are developer distribution access, backend usage, optional AI calls and QA devices. Establish spending caps and observe usage; no current provider prices or guaranteed free operation are assumed. Monetization is an open decision and is outside the MVP commitment.

### Pilot and success measures - proposed

Recruit 15-30 consenting students or developers for a two-week pilot after the release gates pass. Use useful discoveries reported per active participant as the primary product signal, supported by relevant-link opens, saved links and voluntary accepted connections. Measure link-open rate as encounters with an original-link open divided by encounters viewed; report sample sizes and feature availability. Do not treat raw encounter volume as success.

### What the pilot must answer

Do users discover work they would otherwise have missed? Do they understand who can see each link? Does discovery feel unobtrusive? Review aggregate, consented feedback without exposing precise movement histories. Proceed only when technical evidence, privacy checks and user feedback support the next investment.

### Recommendation

Approve Milestone 1 and preparation of a controlled pilot cohort. Revisit the product promise after the Bluetooth evidence is available. Keep link ownership, independent visibility and optional AI approval as non-negotiable product principles.

> Basis: supplied design.md v0.2 and specification.md v0.2. Pilot sizes, trial counts, release gates and UI layouts are proposal additions, not validated results.

## Source traceability

| Proposal topic | Specification v0.2 | Design v0.2 |
|---|---|---|
| Vision, users and modes | Sections 1-3 | Sections 1-3 |
| External links and visibility | Sections 4, 7 | Sections 5-6, 10-11 |
| Bluetooth research and devices | Sections 5, 10-11 | Sections 8-9 |
| Optional AI and consent | Section 8 | Section 7 |
| Notifications and scope | Sections 9-10 | Sections 11, 13 |
| Success, delivery and security | Sections 7, 12 | Sections 9, 12-14 |

The source specification and design remain the detailed requirements and architecture references. Proposed changes, particularly moving reporting and blocking ahead of external beta, should be reconciled with those drafts when accepted.
