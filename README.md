# すれちがいエンジニア（Engineer Encounters）
日本語 | [English](README.en.md)

**すれちがったエンジニアの作品を見つけよう。** 身近ですれちがったエンジニアの作品に出会えるiPhoneアプリです。

すれちがいエンジニアは、日常の偶然のすれちがいを通じて、エンジニア同士がお互いの作品を見つけるためのアプリです。たとえば勉強会や学校、電車の中で、アプリの利用者2人が数分間近くにいて、少なくともどちらかがアプリを開いていれば、端末同士がBluetoothでお互いを検知します。あとから、相手のプロフィールと、GitHubリポジトリや技術記事など相手が公開しているリンクを見ることができます。会話をしなくても作品を読むだけで価値があるので、話しかける必要はありません。

18歳以上のエンジニアを対象とした無料のアプリで、広告もアプリ内課金もありません。

## 使い方

1. **自分のカードを作ります。** 短い自己紹介を書き、興味のある分野を選んで、作品へのリンクを追加します。項目ごとに、誰に公開するかを自分で決められます。
2. **いつもどおりに過ごします。** あなたとほかの利用者が、少なくともどちらかがアプリを開いた状態でBluetoothの届く範囲に2分以上いると、両方の端末にすれちがいが記録されます。アプリがバックグラウンドにあるときも、記録される場合があります。
3. **自分のペースで作品を見ます。** 1日1回、毎日のレポートで、すれちがったエンジニアと、その人が公開している作品を確認できます。

イベントでは、2人ともセッションを開始するか、片方が相手のQRコードを読み取るQR交換で、お互いの情報をすぐに見ることもできます。

## プライバシーを守る設計

- **位置情報を使いません。** どこにいたかを尋ねたり保存したりすることはありません。すれちがいは日付だけを記録し、時刻は記録しません。
- **Bluetoothで個人を特定できる情報を送りません。** 端末間で交換するのは、有効期間の短いランダムな値だけです。あなたを表すトークンは15分ごとに変わります。名前、アカウント、リンクを無線で送ることはありません。
- **両方の端末からの報告が必要です。** サーバーは、両方の端末が報告した場合にだけすれちがいを確認します。通常のすれちがいで2分に満たないものは破棄するため、通り過ぎるだけでカードを集めることはできません。
- **「近くに誰かがいる」という通知はありません。** 通常のすれちがいは、リアルタイムでは表示せず、あとから毎日のレポートで届きます。
- **公開範囲を自分で決められます。** プロフィールの各項目やリンクは、すれちがった相手全員、利用目的と興味のある分野が合う相手のみ、非公開のいずれかを選べます。この選択どおりに公開されるよう、サーバーが制御します。

## 使用技術

| 分野 | 技術 |
|---|---|
| iOSアプリ | Swift 6、SwiftUI、iOS 26以降 |
| 近くの端末の検知 | Core Bluetooth。各端末がセントラルとペリフェラルの両方として動作します |
| 端末内の保存 | すれちがいの受領記録にはSwiftData、トークンとセッションにはKeychainを使用します |
| バックエンド | [Supabase](https://supabase.com)：Authと、アクセス制御されたSQL関数経由でのみアクセスするPostgreSQL |
| テスト | XCTest、pgTAP、Deno |
| ツール | XcodeGen、Swift Package Manager |
| 対応言語 | 日本語、英語 |

## プロジェクト構成

- `ios/App`：各パッケージをつなぐアプリのエントリーポイントです。
- `ios/Packages/EncounterDomain`：すれちがいのエンジンです。交換プロトコル、2分ルール、トークンの更新を扱います。Bluetoothのコードを含まないため、無線通信をシミュレートしてテストします。
- `ios/Packages/EncounterBluetooth`：Core Bluetoothによる通信を担います。
- `ios/Packages/EncounterStorage`：SwiftDataによる受領記録のキューと、Keychainによるトークンの保存を担います。
- `ios/Packages/EncounterBackend`：サインイン、トークンの発行、受領記録のアップロードを行うバックエンドクライアントです。
- `ios/Packages/EncounterUI`：SwiftUIの画面です。
- `supabase/`：データベースのマイグレーションとそのテストです。
- `docs/`：仕様、設計、画面定義です。

## 必要なもの

- 「アプリケーション」フォルダに**Xcode 27.0**をインストールしたMacが必要です。SwiftはXcodeに含まれています。初めて起動するときに、iPhoneシミュレータを含むiOSプラットフォームをインストールしてください。アプリにはiOS 26.0以降が必要です。
- ほかのツールをインストールするために、[Homebrew](https://brew.sh)が必要です。
- Xcodeのプロジェクトファイルを生成する**XcodeGen** 2.46.0以降が必要です。`brew install xcodegen`でインストールできます。

## アプリのビルドと実行

1. コードを取得します。

   ```sh
   git clone https://github.com/miyabi206/engineer-streetpass.git
   cd engineer-streetpass
   ```

2. Xcodeのプロジェクトを生成します。プロジェクトは`ios/project.yml`から生成され、gitには保存されていません。`git pull`のあとや、`ios/`内のファイルを追加、削除、名前変更したときは、その都度このコマンドを実行してください。

   ```sh
   xcodegen generate --spec ios/project.yml
   ```

3. `open ios/EngineerEncounters.xcodeproj`でプロジェクトを開きます。
4. Xcodeのウィンドウ上部で**EngineerEncounters**スキームとiPhoneシミュレータを選び、**Run**（⌘R）を押します。

アプリを起動せずに、ターミナルからビルドできることを確認するには、次のコマンドを実行します。

```sh
xcodebuild -project ios/EngineerEncounters.xcodeproj -scheme EngineerEncounters -configuration Development -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

シミュレータではBluetoothを使えません。アプリの画面を見ることはできますが、別の端末を検知するには実機のiPhoneが2台必要です。サインインにはバックエンドが必要です。下の**バックエンドをローカルで実行する**を参照してください。

### 実機のiPhoneで実行する

設定ファイルのサンプルをコピーします。コピーしたファイルはgitの管理対象外なので、設定値は自分のMacにだけ保存されます。

```sh
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
```

コピーしたファイルで、`DEVELOPMENT_TEAM`にAppleのチームID（[developer.apple.com/account](https://developer.apple.com/account)の「メンバーシップの詳細」にある10文字のID）を、`APP_BUNDLE_IDENTIFIER`に自分の識別子を設定してください。その後、iOS 26.0以降でデベロッパモードをオンにしたiPhoneを接続し、Xcodeでその端末を選んで**Run**を押します。

## バックエンドをローカルで実行する

[Docker Desktop](https://www.docker.com/products/docker-desktop/)とSupabase CLIも必要です。Supabase CLIは`brew install supabase/tap/supabase`でインストールできます。Docker Desktopを起動し、リポジトリのルートで次のコマンドを実行してください。

```sh
supabase start      # ローカルのバックエンドを起動します。初回は複数のイメージをダウンロードします
supabase db reset   # データベースのテーブルを作成し、シードデータを読み込みます
supabase status     # APIのURLとキーを表示します
```

アプリを接続するには、`ios/Config/Local.xcconfig`に次の2行を記入します。ファイルがなければ作成してください。サンプルをコピーして使っている場合は、同じ名前の空欄の2行を置き換えてください。`supabase status`が表示するpublishable keyを使います（古いバージョンではanon keyと呼ばれています）。

```
DEVELOPMENT_BACKEND_URL = http:/$()/127.0.0.1:54321
DEVELOPMENT_BACKEND_PUBLIC_KEY = <publishable key>
```

設定ファイルでは`//`がコメントの開始として扱われるため、アドレスには`//`の代わりに`/$()/`と書きます。シミュレータからは`127.0.0.1`で接続できます。実機のiPhoneでは、その端末からアクセスできるアドレスが必要です。バックエンドは`supabase stop`で停止できます。

## テストの実行

リポジトリのルートで次のコマンドを実行してください。

```sh
swift test --package-path ios/Packages/EncounterDomain   # EncounterBluetooth、EncounterStorage、EncounterBackendも同様です
sh ios/Scripts/typecheck-app.sh Development              # Xcodeでの完全なビルドを行わずにアプリの型をチェックします
supabase test db                                         # データベースのテストです。ローカルのバックエンドを起動しておく必要があります
deno test supabase/functions                             # Denoのテストです。Denoが必要です（brew install deno）
```

## ドキュメント

ドキュメントは英語で書かれています。

- [docs/specification.md](docs/specification.md)：プロダクトの要件です。
- [docs/ui.md](docs/ui.md)：画面の定義です。
- [docs/design.md](docs/design.md)：アーキテクチャ、Bluetoothプロトコル、データモデルです。

## ライセンス

[Apache License 2.0](LICENSE)
