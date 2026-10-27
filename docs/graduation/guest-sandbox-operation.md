# 卒業課題：ゲストログインの安全な利用手順

> **対象：** OshiLog、卒業要件「管理者と一般ユーザーそれぞれのゲストログイン」／[Issue #109](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/issues/109)
>
> **状態：** 試験用の実装候補。公開デモへの反映・実運用・学校合格は未確認。

## 1. 実装すること

一般ユーザーと管理者の**二つのゲストログインボタン**を、専用デモ環境のトップページに表示します。専用データベースの5アカウントだけを参照し、両方のゲストは閲覧専用です。ゲストは登録・更新・削除を実行できません。

## 2. 起動前の必須確認

1. **実利用者と関係のないDB・ストレージだけ**を使用してください。既存の本番DB、個人情報、実利用者の画像が存在する環境では有効化しないでください。
2. 空の専用DBに、後述の `guest_demo:prepare` で5つの予約アカウントだけを作成します。本番でdevelopment seedを実行したり、実利用者のデータをコピーしたりしません。
3. 専用の公開デモ環境で、`OSHI_GUEST_SANDBOX=isolated` と `OSHI_GUEST_SANDBOX_PRODUCTION_ACK=true` を設定します。後者は、**運用者がDBとストレージの分離を確認済みの場合のみ**設定してください。
4. 実利用者アカウントがある、またはゲスト利用に必要なデモアカウントが欠けている場合、ゲストログインは表示・実行できません。

## 3. 安全上の制限

- 既存のデモアカウントの公開パスワードを使った通常ログインは、デモモード中は拒否します。
- デモ中の新規会員登録も拒否します。新規利用者が追加された場合、次のアクセスでゲストセッションを終了します。
- 書込み系のHTTPリクエストはサーバーで拒否します。通常ログアウトのみ例外です。
- 管理者ゲストはデモDBの管理画面を閲覧します。実際の学校・顧客データに接続した環境で有効化してはいけません。
- 本番へ無条件に公開する機能ではありません。**専用公開環境での実機検証と、URLの提出は別作業**です。

## 4. 受入確認

- [ ] 一般ゲストでログイン→マイページ閲覧→管理者画面拒否→ログアウトを確認。
- [ ] 管理者ゲストでログイン→管理画面閲覧→承認・削除拒否→ログアウトを確認。
- [ ] 実アカウントが1件でも存在するとゲストが利用できないことを確認。
- [ ] 公開デモのDB・ストレージ分離、テストの成功、公開URL・検証日時を記録。
- [ ] 卒業要件に照らして学校側の確認を受ける（実装PRの完成と公式合格は別）。

文章は[DIVIC CDS v1.0](https://diveintocode.docbase.io/posts/4253992)と[CDS日本語表記](https://diveintocode.docbase.io/posts/4253986)に従い、条件・検証状態を区別しています。

## 5. `/demo/` 専用デプロイの設定と初期化

以下は運用手順であり、DB・role・secret・公開設定の作成済み記録ではありません。通常版の設定とデータは維持します。

| 項目 | デモ専用の設定 |
| --- | --- |
| PostgreSQL role | `oshilog_demo`（LOGIN、NOSUPERUSER、NOCREATEDB、NOCREATEROLE、NOINHERIT。本番データへの権限なし） |
| primary / cache / queue / cable DB | `oshilog_demo` / `oshilog_demo_cache` / `oshilog_demo_queue` / `oshilog_demo_cable` |
| 接続設定 | `DATABASE_URL`、`CACHE_DATABASE_URL`、`QUEUE_DATABASE_URL`、`CABLE_DATABASE_URL`で各専用DBと専用roleを指定。値はsecretとして管理し、ログやGitへ出さない |
| 画像 | `OSHI_GUEST_STORAGE_ROOT=/rails/demo-storage`。例：専用host directory `/srv/oshilog-demo/storage`だけをこのパスへmount。通常版のvolumeを共有しない |
| 認証 | 通常版から独立して生成した`SECRET_KEY_BASE`。通常版のcredentials・master key・secretをコピーしない |
| cookie | `_oshilog_demo_session`、path `/demo`、Secure（production）、HttpOnly、SameSite=Lax |
| URL | `RAILS_RELATIVE_URL_ROOT=/demo`。Rackでも`/demo`へmountし、ルートの通常版へredirectしない |
| HTTPS host | `PUBLIC_APP_HOST=13.115.187.119`。既存のHTTPS hostを使用する |
| 有効化 | `OSHI_GUEST_SANDBOX=isolated`、`OSHI_GUEST_SANDBOX_PRODUCTION_ACK=true` |

1. 既存サーバーの容量とローカル待受の空きを確認します。別の課金資源、公開ポート、SG変更は不要です。例として別アプリを`127.0.0.1:3001`だけで待受けますが、このportの空きは未確認です。
2. 専用roleと4DBを準備し、既存の本番データ・schema・role継承等を経由した読取／更新権限がないことを運用者が確認します。既存PUBLIC権限などのため本番ACL変更が必要なら停止します。この手順では本番ACLを変更しません。
3. 専用storageとsecretを用意し、上記設定をデモ側だけへ渡します。DB名・role・storage・prefix・secretの設定が不足する場合、デモのproduction起動は拒否されます。実際のvolumeとsecretの独立性は運用確認が必要です。
4. 専用接続で`RAILS_ENV=production bin/rails db:prepare`を実行して4DBのschemaを準備し、その後`RAILS_ENV=production bin/rails guest_demo:prepare`を一度実行します。既存のdevelopment/test seedの環境ガードは変更していません。
5. 初期化は5アカウント（それぞれ新規ランダムパスワード）、5プロフィール、2推し、1ユーザー推し、1活動とその関連、既定の感情だけを作成します。画像はコピーせず、専用storageは空で開始します。管理者と一般ゲストは既存の閲覧専用制限に従います。
6. primaryの実接続DB名・roleを検査してから、アプリ用テーブルが空であることを確認します。既定の感情以外のデータがあれば、再実行も含めて上書き・削除せず拒否します。途中失敗はtransactionで今回分をrollbackし、既存データを削除してリセットしません。
7. ローカルで`/demo/up`、一般／管理者ゲストのlogin/logout、一般の管理画面403、管理者の更新403、assetとcookieを確認します。成功後だけ既存HTTPSの`/demo/`へproxyを追加します。`/demo`は`/demo/`へ正規化し、upstreamへはprefixを残して転送します（`proxy_pass http://127.0.0.1:3001;`のようにURI部分を付けない）。HostとHTTPS転送headerはproxyで上書きします。
8. 公開URLで再確認し、配備SHA・日時・結果を記録します。通常版のguestは無効のままです。容量、権限、prefixに問題がある場合は、その公開作業を止めて報告します。
