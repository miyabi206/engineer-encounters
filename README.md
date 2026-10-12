# Engineer Encounters

**すれちがいエンジニア**: an iPhone app for discovering the work of the engineers you cross paths with.

Engineer Encounters helps engineers discover each other's work through chance encounters in the real world. When two people who use the app spend a couple of minutes near each other, for example at a meetup, on campus or on a train, with the app open on at least one phone, their phones notice each other over Bluetooth. Later, each of them can read the other's profile and the links that person chose to share, such as GitHub repositories and technical articles. Reading someone's work is valuable even when the two never talk, so nobody is ever asked to.

The app is free, with no ads and no purchases, and is for engineers aged 18 or older.

## How it works

1. **Make your card.** Write a short introduction, pick your interests and add links to your work. You decide who can see each item.
2. **Go about your day.** When you and another user stay within Bluetooth range for two minutes and at least one of you has the app open, both phones record the encounter. It may also work with the app in the background.
3. **Read at your own pace.** Once a day, a daily report shows the engineers you encountered and what they share.

At an event, two people can also see each other right away, by both starting a session or by one scanning the other's QR code.

## Privacy by design

- **No location.** The app never asks for or stores where you were, and it keeps the date of an encounter, not the time.
- **No identity over Bluetooth.** Phones exchange only short-lived random values, and the token that stands for you changes every 15 minutes. Names, accounts and links never travel over the air.
- **Both phones must agree.** The server confirms an encounter only when both phones report it, and everyday contacts shorter than two minutes are discarded, so nobody can collect cards by walking past.
- **No "someone is nearby" alerts.** Everyday encounters are revealed later, in the daily report, never in real time.
- **You control visibility.** Each profile field and link is shown to everyone you encounter, only to people whose purposes and interests match yours, or to nobody, and the server enforces that choice.

## Technologies

| Area | Technology |
|---|---|
| iOS app | Swift 6, SwiftUI, iOS 26 or later |
| Proximity detection | Core Bluetooth; every phone acts as both central and peripheral |
| On-device storage | SwiftData for encounter receipts, Keychain for tokens and sessions |
| Backend | [Supabase](https://supabase.com): Auth, and PostgreSQL reached only through access-controlled SQL functions |
| Tests | XCTest, pgTAP and Deno |
| Tooling | XcodeGen and Swift Package Manager |
| Languages | Japanese and English |

## Project structure

- `ios/App`: the app entry point, which wires the packages together
- `ios/Packages/EncounterDomain`: the encounter engine (exchange protocol, two-minute rule, token rotation), free of Bluetooth code so it is tested against a simulated radio
- `ios/Packages/EncounterBluetooth`: the Core Bluetooth transport
- `ios/Packages/EncounterStorage`: the SwiftData receipt queue and the Keychain token store
- `ios/Packages/EncounterBackend`: the backend client for sign-in, token issue and receipt upload
- `ios/Packages/EncounterUI`: the SwiftUI screens
- `supabase/`: the database migrations and their tests
- `docs/`: the specification, design and screen definitions

## What you need

- A Mac with **Xcode 27.0** in the Applications folder. It includes Swift; when it first opens, let it install the iOS platform, which provides the iPhone simulator. The app requires iOS 26.0 or later.
- [Homebrew](https://brew.sh), to install the other tools.
- **XcodeGen** 2.46.0 or later, which creates the Xcode project file. Install it with `brew install xcodegen`.

## Build and run the app

1. Get the code:

   ```sh
   git clone https://github.com/miyabi206/engineer-streetpass.git
   cd engineer-streetpass
   ```

2. Create the Xcode project. It is generated from `ios/project.yml` and is not stored in git, so run this again after every `git pull` and whenever files under `ios/` are added, removed or renamed:

   ```sh
   xcodegen generate --spec ios/project.yml
   ```

3. Open the project with `open ios/EngineerEncounters.xcodeproj`.
4. In Xcode, choose the **EngineerEncounters** scheme and an iPhone simulator at the top of the window, then press **Run** (⌘R).

To check from the terminal that the app builds, without running it:

```sh
xcodebuild -project ios/EngineerEncounters.xcodeproj -scheme EngineerEncounters -configuration Development -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The simulator has no Bluetooth: you can look around the app there, but detecting another phone needs two real iPhones. Signing in needs a backend; see **Run the backend locally** below.

### Run on a real iPhone

Copy the example settings file. The copy is ignored by git, so your values stay on your Mac.

```sh
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
```

In the copy, set `DEVELOPMENT_TEAM` to your Apple developer Team ID (the 10-character ID under Membership details at [developer.apple.com/account](https://developer.apple.com/account)) and `APP_BUNDLE_IDENTIFIER` to an identifier of your own. Then connect an iPhone that runs iOS 26.0 or later with Developer Mode turned on, pick it in Xcode and press **Run**.

## Run the backend locally

You also need [Docker Desktop](https://www.docker.com/products/docker-desktop/) and the Supabase CLI, which you install with `brew install supabase/tap/supabase`. Start Docker Desktop, then run these from the repository root:

```sh
supabase start      # starts the local backend; the first run downloads several images
supabase db reset   # creates the database tables and loads the seed data
supabase status     # shows the API URL and the keys
```

To connect the app to it, put these two lines in `ios/Config/Local.xcconfig`. Create the file if it does not exist; if you copied it from the example, replace the two empty lines that have the same names. Use the publishable key that `supabase status` prints (older versions call it the anon key):

```
DEVELOPMENT_BACKEND_URL = http:/$()/127.0.0.1:54321
DEVELOPMENT_BACKEND_PUBLIC_KEY = <publishable key>
```

Write `/$()/` instead of `//` in the address, because the settings file treats `//` as the start of a comment. `127.0.0.1` works from the simulator; a real iPhone needs an address it can reach. Stop the backend with `supabase stop`.

## Run the tests

Run these from the repository root:

```sh
swift test --package-path ios/Packages/EncounterDomain   # also EncounterBluetooth, EncounterStorage, EncounterBackend
sh ios/Scripts/typecheck-app.sh Development              # type-checks the app without a full Xcode build
supabase test db                                         # database tests; needs the local backend running
deno test supabase/functions                             # Deno tests; needs Deno (brew install deno)
```

## Documentation

- [docs/specification.md](docs/specification.md): the product requirements
- [docs/ui.md](docs/ui.md): the screens
- [docs/design.md](docs/design.md): the architecture, Bluetooth protocol and data model

## License

[Apache License 2.0](LICENSE)
