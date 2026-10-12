# Engineer Encounters

Engineer Encounters (Japanese: **すれちがいエンジニア**) is an iPhone app that helps engineers discover each other's work through chance encounters in the real world.

When two people who use the app spend a couple of minutes near each other, for example at a meetup, on campus or on a train, and at least one of them has the app open, their phones notice each other over Bluetooth. It may also work with the app in the background, but that is not promised. Later, each of them can see the other's profile and the links that person chose to share, such as GitHub repositories or articles. Nobody has to talk, an encounter only counts when both phones report it, and the app never records where you were.

> **Status:** early development. Nothing is on the App Store yet. Today the repository contains the Bluetooth encounter engine, accounts and profiles, the onboarding and settings screens, and a diagnostics screen for testing. The encounter feed, link sharing and the daily report are still being built.

The repository is still named `engineer-streetpass`, an early working name. It contains:

- `ios/`: the iPhone app, written in Swift and SwiftUI
- `supabase/`: the backend for [Supabase](https://supabase.com), with its database tables, access rules and tests
- `docs/`: what the product should do and how it is designed

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

The simulator has no Bluetooth: you can look around the app there, but detecting another phone needs two real iPhones. Without a backend the app still starts, but you cannot sign in; see **Run the backend locally** below.

### Run on a real iPhone

Copy the example settings file. The copy is ignored by git, so your values stay on your Mac.

```sh
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
```

In the copy, set `DEVELOPMENT_TEAM` to your Apple developer Team ID (the 10-character ID under Membership details at [developer.apple.com/account](https://developer.apple.com/account)) and `APP_BUNDLE_IDENTIFIER` to an identifier of your own. Then connect an iPhone that runs iOS 26.0 or later with Developer Mode turned on, pick it in Xcode and press **Run**.

## Run the backend locally (optional)

You also need [Docker Desktop](https://www.docker.com/products/docker-desktop/) and the Supabase CLI, which you install with `brew install supabase/tap/supabase`. Start Docker Desktop, then run these from the repository root:

```sh
supabase start      # starts the local backend; the first run downloads several images
supabase db reset   # creates the database tables and loads placeholder data
supabase status     # shows the API URL and the keys
```

To connect the Development build to it, put these two lines in `ios/Config/Local.xcconfig`. Create the file if it does not exist; if you copied it from the example, replace the two empty lines that have the same names. Use the publishable key that `supabase status` prints (older versions call it the anon key):

```
DEVELOPMENT_BACKEND_URL = http:/$()/127.0.0.1:54321
DEVELOPMENT_BACKEND_PUBLIC_KEY = <publishable key>
```

Write `/$()/` instead of `//` in the address, because the settings file treats `//` as the start of a comment. `127.0.0.1` works from the simulator; a real iPhone needs an address it can reach. Stop the backend with `supabase stop`.

## Run the checks

Run these from the repository root:

```sh
swift test --package-path ios/Packages/EncounterDomain   # also EncounterBluetooth, EncounterStorage, EncounterBackend
sh ios/Scripts/typecheck-app.sh Development              # type-checks the app without a full Xcode build
supabase test db                                         # database tests; needs the local backend running
deno test supabase/functions                             # backend smoke test; needs Deno (brew install deno)
```

The full list, including the simulator tests, is in [docs/design.md](docs/design.md) under **Terminal checks and owner's tools**.

## Learn more

- [docs/specification.md](docs/specification.md): what the product does and for whom
- [docs/ui.md](docs/ui.md): the screens
- [docs/design.md](docs/design.md): how it is built
- [docs/decisions.md](docs/decisions.md): the product decisions, which win when documents disagree

## License

[Apache License 2.0](LICENSE)
