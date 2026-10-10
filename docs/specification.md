# Specification — Engineer StreetPass

**Version:** 0.2  
**Status:** Draft  
**Platforms:** iOS first, Android later  
**Language:** Japanese, English
**Name:** Engineer StreetPass

## 1. Product Vision

Engineer StreetPass is an ambient networking application that transforms unexpected physical encounters into opportunities to discover knowledge, people, and careers.

Users discover relevant technical works and people by carrying their smartphones during everyday activities.

The application does not host portfolios. Instead, users share links to content they have already published elsewhere.

**Mission:** Discover people, projects, and opportunities you weren't looking for.

### Core Principles

- Serendipitous discovery
- Minimal user effort
- User-controlled visibility
- Privacy by design
- No obligation to communicate
- Independent ownership of external content

## 2. Target Users

Primary users:

- Engineering students
- Software engineers
- Open-source contributors
- Technical writers
- Researchers

Secondary users:

- Recruiters
- Startup founders
- Research laboratories
- Engineering community organizers

The initial target is engineering students and software developers.

## 3. Connection Modes

Users select their purposes during onboarding. The app configures suitable initial settings.

Users may enable multiple modes and change their preferences later.

### Discovery Mode

Discover technical works published by encountered users.

Supported sources include GitHub, Qiita, Zenn, personal websites, technical blogs, and research publications.

### Collaboration Mode

Discover people interested in development projects, hackathons, research collaborations, or open-source contributions.

### Opportunity Mode

Discover internship, employment, startup, and research opportunities.

Students and engineers may share professional profile links. Recruiters may share approved company or job-posting links.

## 4. External Links

### 4.1 Link-Based Profiles

Users register links rather than uploading portfolios.

A user profile may contain:

- Display name
- Optional avatar
- Short biography
- Technical interests
- Connection purposes
- External links

### 4.2 External Link Data

Each link contains:

- URL
- Platform type
- Optional custom title
- Optional description
- Interest tags
- Visibility level
- AI summarization permission
- Display order

### 4.3 Supported Links

Initial support:

- GitHub profiles and repositories
- Qiita profiles and articles
- Zenn profiles and articles
- Personal websites
- Other HTTPS links

Additional platforms may be supported without fundamentally changing the data model.

### 4.4 No Portfolio Hosting

The application does not provide:

- Portfolio page builders
- Repository hosting
- Article publishing
- Document uploads
- Resume builders

Links open the original content on its external platform.

Users remain responsible for managing and updating their original works.

### 4.5 Link Previews

The application may display titles, source platform, descriptions, and optional AI summaries.

Previews must not disclose information beyond the owner's visibility permissions.

## 5. StreetPass Discovery

### 5.1 Desired Experience

When two compatible users pass near each other, the application attempts to recognize their encounter automatically, including when their devices are locked.

Neither person should need to manually open the app during the encounter.

### 5.2 Important Constraint

Automatic background discovery between two locked devices is a technical research objective.

Reliable detection cannot be guaranteed until real-device experiments demonstrate it.

### 5.3 Encounter History

An authorized encounter may display:

- Shared interests
- Approved profile information
- Shared external links
- Optional AI summaries
- Connection request action

An encounter does not automatically establish a social connection.

## 6. Matching

The initial matching system uses user-defined rules rather than AI recommendations.

Possible conditions:

- Enabled connection modes
- Minimum number of shared interests
- Preferred technology categories
- Participant categories
- Collaboration interests
- Visibility permissions

Users can modify these conditions through Settings.

Matching eligibility and authorization to view individual fields are evaluated separately.

## 7. Privacy and Visibility

### 7.1 Visibility Controls

Users determine the visibility of their profile fields and individual external links.

Supported levels:

1. All eligible encountered users
2. Only compatible encountered users
3. Mutual connections only
4. Private

Sensitive contact details are private by default.

### 7.2 Discovery Controls

Users may:

- Enable or disable background discovery
- Pause discovery temporarily
- Configure matching conditions
- Block other users
- Delete encounter records
- Delete their account

### 7.3 Location Privacy

The application must not publicly disclose precise encounter locations or timestamps.

Temporary discovery identifiers should be used where technically feasible.

Permanent personal identifiers must not be broadcast over Bluetooth.

### 7.4 External Link Privacy

A shared external link may identify its owner even if the in-app display name is anonymous.

Users must be informed about this before sharing personal websites or identifiable profiles.

## 8. AI Summaries

### 8.1 Model

Gemini 3.1 Flash-Lite through the Google Gemini Developer API.

The initial implementation may use the Google AI Studio free tier, subject to provider limits and data-processing terms.

### 8.2 Purpose

Provide short explanations of linked technical works.

Examples:

- What a GitHub project does
- Technologies used
- Key implementation features
- What readers might learn from an article

AI summaries must not be used to judge the personal worth or professional competence of a creator.

### 8.3 AI Privacy Policy

**Gemini must never receive information beyond what an ordinary authorized user is allowed to access.**

For the free-tier MVP, a stricter policy applies:

- Process only explicitly approved public content.
- Require the owner's consent for AI processing.
- Do not process private or restricted profiles.
- Do not process encounter histories, messages, locations, or contact details.
- Let the owner preview the exact content submitted for summarization.
- Let the owner approve, edit, or reject summaries.

Giving another user permission to view a link does not automatically authorize sending its contents to Gemini.

### 8.4 Summary Storage

Only the generated summary, relevant metadata, and authorization records need to be stored.

The original article or repository remains on its external platform.

Temporary source content should not be retained unnecessarily.

### 8.5 AI Availability

The core app must work without Gemini.

If summarization is unavailable or disabled, display the link and its manually supplied description.

## 9. Notifications

Users can configure:

- Immediate notifications when technically available
- Daily digest
- Weekly digest
- No notifications

Notification conditions may include shared interests, connection modes, and connection requests.

Exact encounter locations and timestamps must not appear in notifications.

## 10. MVP Features

### P0 — Technical Research

- Core Bluetooth discovery
- Foreground encounters
- Background encounters
- Locked-device experiments
- Encounter logging
- Reliability and battery measurements

### P1 — Core Application

- User authentication
- Purpose selection
- Technical interest selection
- External link registration
- Link-level visibility
- Profile visibility
- Encounter history
- Rule-based matching
- External link opening
- Notification preferences

### P2 — Extensions

- Gemini summaries
- Saved external links
- Connection requests
- Reporting and blocking

### Future

- Android application
- Private messaging
- Organization verification
- Recruiting dashboards
- Semantic recommendations
- Event-specific discovery features

## 11. Supported Devices

### Initial Platform

Native iOS application using Swift and SwiftUI.

The minimum supported operating-system version will be chosen for currently supported iPhone hardware and modern SwiftUI APIs.

Legacy support is not a project requirement.

### Development Test Devices

- iPhone 15
- iPad 10th generation

The iPad is used as a development and experimental peer device.

Successful iPhone-to-iPad tests do not prove identical performance between two iPhones.

Additional iPhone-to-iPhone verification will be required before guaranteeing the intended phone-to-phone experience.

## 12. Success Metrics

Technical:

- Encounter detection success rate
- Detection latency
- False-positive encounters
- Duplicate encounters
- Battery consumption

Product:

- Relevant links discovered
- External link opening rate
- Saved links
- Useful discoveries reported by users
- Connection requests
- Successful voluntary connections

**The main objective is meaningful discovery, not maximizing the number of encounters.**
