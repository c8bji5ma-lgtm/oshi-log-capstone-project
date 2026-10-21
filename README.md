# OshiLog（仮）

## アプリケーション概要

OshiLog（仮）は、推し活を「記録する・振り返る・可視化する」ためのWebアプリケーションです。

推し活の履歴を蓄積し、活動回数・支出・推し歴・活動傾向などを可視化することで、自分がどのような推し活をしてきたかを振り返れるサービスを目指します。

MVPの中心は「記録・振り返り・可視化」とし、プロフィール・名刺生成は付加価値として位置づけます。

外部公開、URL・QRコードによる共有、ユーザー同士の交流機能については将来機能として検討します。

## 開発環境

- Ruby 4.0.6（`.ruby-version`）
- Ruby on Rails 8.1系（正確なバージョンは`Gemfile.lock`を参照）
- PostgreSQL 18系
- libvips

システムテストを実行する場合は、Chrome / ChromeDriverと日本語フォントも必要です。

## 実行手順

PostgreSQLを起動し、このリポジトリを取得します。

```bash
git clone https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project.git
cd oshi-log-capstone-project
```

ロックファイルで確定したGemをインストールします。

```bash
BUNDLE_FROZEN=true bundle install
```

開発用データベースを準備します。

```bash
bin/rails db:prepare
```

初期データが必要な場合だけseedを実行します。development環境ではローカル確認用のデモデータも作成されるため、既存データがある環境では内容を確認してから実行してください。

```bash
bin/rails db:seed
```

Railsサーバーを起動し、`http://localhost:3000`へアクセスします。

```bash
bin/rails server
```

テストはdevelopment DBと分離された`my_app_test`と`tmp/storage`を使用します。

```bash
BUNDLE_FROZEN=true RAILS_ENV=test bundle exec rspec
```

静的チェックは次のコマンドで実行できます。

```bash
BUNDLE_FROZEN=true bin/rubocop
BUNDLE_FROZEN=true bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
BUNDLE_FROZEN=true bin/bundler-audit
BUNDLE_FROZEN=true bin/importmap audit
```

実装状況とIssue #31の最終QA対応は[Issue #31 QA対応表](docs/issue-31-qa.md)を参照してください。

## 要件定義資料

初回の要件定義後、実装前の再検討および画面設計の見直しを行い、画面構成・画面遷移・グローバルナビゲーション等を更新しています。

実装時は、本READMEおよび以下に掲載している最新の要件定義資料・画面遷移図・ワイヤーフレームを基準とします。

### チェックシート

[チェックシートを確認する](https://docs.google.com/spreadsheets/d/1hWaamzG78rVdf1tu79aZMsmti1YSxQMKiD_1AjhuCVg/edit#gid=1321893864)

### カタログ設計

[カタログ設計を確認する](https://docs.google.com/spreadsheets/d/1hWaamzG78rVdf1tu79aZMsmti1YSxQMKiD_1AjhuCVg/edit#gid=697294974)

### テーブル定義書

[テーブル定義書を確認する](https://docs.google.com/spreadsheets/d/1hWaamzG78rVdf1tu79aZMsmti1YSxQMKiD_1AjhuCVg/edit#gid=1645989784)

### ワイヤーフレーム

[Whimsicalでワイヤーフレームを確認する](https://whimsical.com/yuki-atarashi/oshilog-kpi-4JZqsPQdZ6TfN7LoLxQJbw)

## ER図

文字が確認しやすいよう、ER図を3枚に分けて掲載しています。

![ER図 1](docs/images/er_diagram1.png)

![ER図 2](docs/images/er_diagram2.png)

![ER図 3](docs/images/er_diagram3.png)

[WhimsicalでER図を確認する](https://whimsical.com/yuki-atarashi/oshilog-er-mvp-PDbRKWDyLu1fJfbJxNVMP6)

## 画面遷移図・ワイヤーフレーム

最新の画面設計を、内容ごとに分けて掲載しています。

### 全体

![画面遷移図・全体](docs/images/01_画面遷移図_全体.png)

### タイトル・凡例・グローバルナビゲーション

![タイトル・凡例・グローバルナビゲーション](docs/images/02_タイトル_凡例_グローバルナビ.png)

### 推し管理

![推し管理](docs/images/03_推し管理.png)

### 活動記録

![活動記録](docs/images/04_活動記録.png)

### 認証・共通画面

![認証・共通画面](docs/images/05_認証_共通画面.png)

### データ・プロフィール

![データ・プロフィール](docs/images/06_データ_プロフィール.png)

### 画面遷移に関する補足

![画面遷移に関する補足](docs/images/07_画面遷移に関する補足.png)

[Whimsicalで画面遷移図を確認する](https://whimsical.com/yuki-atarashi/oshilog-BXfu4fkBrWUUJmT5NJb2Qi)
