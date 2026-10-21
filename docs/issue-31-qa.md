# Issue #31 MVP最終QA対応表

## 基準

- 確認日：2026年10月21日
- Issue：[#31 MVP最終QA・要件照合・README更新](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/issues/31)
- 実装基準：PR #73の最終commitと、そのcommitに対するGitHub Actions
- 正式仕様の優先順：GitHub Issues、READMEから参照する要件資料、ER図・テーブル定義、実装

この文書は確定仕様を変更するものではない。外部の要件資料やER図を更新せず、現行実装との対応、既存の検証結果、残る確認事項を記録する。

## 要件と検証の対応

| Issue #31の確認項目 | 現在の根拠 | 状態・残る確認 |
|---|---|---|
| カタログ設計の高優先度機能 | 活動CRUD、履歴・絞り込み、集計・固定費のrequest/system spec | 自動検証済み。主要フローの最終目視を残す |
| テーブル定義書とDB構造 | `db/schema.rb`、model spec、DB制約spec、test DBメタデータ | 基本9テーブルと承認済み追加差分を照合済み |
| ER図とモデル関連 | model、association/constraint spec | 基本関連は自動検証済み。追加差分の外部ER図反映確認を残す |
| 主要画面遷移 | authentication、推し管理、活動・データ、固定費、プロフィール・カード、管理者のsystem spec | Chrome headlessで自動検証済み。実ブラウザ一巡を残す |
| 主要画面・グローバルナビ | request/system spec、Issue #30の1280px/375px目視 | 主要幅で確認済み。全端末・支援技術の保証ではない |
| ログイン・ログアウト・管理者 | authentication、admin authorization/merging spec | 自動検証済み |
| バリデーション・エラー表示 | model、request、system spec | 正常系・主要異常系を自動検証済み |
| 画像添付 | image attachment、protected image、image library、card spec | 機能・認可は自動検証済み。Issue #60の資源上限は別課題 |
| テストスイート・CI | PR #73: lint / scan_js / scan_ruby / test | すべて成功 |
| RuboCop等 | PR #73のlint・security checks | 成功 |
| README | リポジトリ名、起動・検証手順 | Issue #31ブランチで更新 |
| 将来機能の表記 | README、`docs/future-features/` | 公開URL・QR・交流・装飾案を将来機能として区別 |
| デバッグコード・サンプルデータ | 静的検索、development seedの環境ガード | 不要と断定できるものだけを削除対象とする。seedはdevelopment限定 |

## 承認済みIssueによる仕様書との差分

外部テーブル定義書の「OshiLog独自業務テーブル9個」はMVP基本設計を示す。現在のschemaには、後から承認・実装された次の差分がある。

| 差分 | 根拠 | 現行schema |
|---|---|---|
| 感情タグ | 追加要件1、PR #69 | `emotions`、`activity_emotions`を追加 |
| 推し画像ライブラリ | Issue #70、PR #71 | Active Storageを使い、`UserOshi`の画像関連を拡張。独自業務テーブルの追加なし |
| 楽観ロック | Issue #61、PR #72 | `activities.lock_version`、`subscriptions.lock_version`を追加 |

これらは既存仕様との無断変更ではなく、後続Issueで承認された追加・修正である。外部テーブル定義書・ER図そのものの更新は、それぞれの管理元で別途確認する。

## 再利用する検証結果

- Issue #30最終調整前：非System 1327 examples + System 56 examples、失敗0
- Issue #30最終調整後：関連9 examples成功、対象3ファイルのRuboCop指摘なし、`git diff --check`成功
- PR #73：lint / scan_js / scan_ruby / test がすべて成功
- 1280px / 375px：横スクロール、重なり、文字切れなし
- プロフィールカードdownload待ちの既知の一過性失敗は再試行成功し、Issue #30では再発なし。原因修正済みとは扱わない

同じcommitに対する全件テストを理由なく繰り返さず、Issue #31の変更箇所と不足確認を先に検証する。

## Issue #31変更の検証

- `RAILS_ENV=test`が`my_app_test`へ接続することを確認し、テーブル16件・外部キー15件を読み取り照合した
- DB作成、schema load、migration、seedは実行していない
- カード設定変更のsystem spec：1 example、失敗0
- 変更specのRuboCop：1ファイル、指摘なし
- `git diff --check`：成功
- test storageは`tmp/storage`およびspecごとの一時ディレクトリを使用し、development画像には触れていない

## 独立PoCバックアップとの照合

指定された非公開バックアップは、Issue #68のAIプロフィール帳PoCを保存した独立スナップショットである。Rails本体・DBを含まず、現在の本体へPoCコードは移植されていない。

- オフラインの合成データを使ったPoC検証と、当時のカード関連回帰結果は履歴上の補助根拠として参照できる
- 実API、実キー、実費、実画像の意味理解、Rails本体の全system specは検証範囲外
- 固定キャンバスの配置・crop・文字描画に関する結果であり、Issue #60が求める入力画像の寸法・総画素数・デコード資源・並列負荷の上限測定には代用できない
- コードと環境が異なるため、PoCの成功件数を現在の本体commitの合格結果として合算しない

バックアップの資料本文、画像、接続情報、個人パス、認証情報はこの公開文書へ転載しない。

## 残る確認と優先順位

1. PC / スマートフォン幅で主要ユーザーフローを一巡し、画面遷移図・ワイヤーフレームとの重大な乖離がないことを確認
2. GitHub Actionsの全ジョブ成功を最終確認
3. Chrome以外の実ブラウザ、実端末、支援技術は未確認として記録

## Issue #60と本番環境の分離

Issue #60の画像デコード資源制限は未実装である。既存の10MiB・MIME制約では寸法、総画素数、CPU、処理時間、並列実行を制御できない。

AWSなしで行えるのは、ローカルの実レンダラでJPEG・PNG・WebP、EXIF、細長画像、高圧縮画像を測定し、境界・異常系をtest環境で確認するところまでである。本番インスタンス上の安全な上限、並列負荷、タイムアウト値は本番相当環境の実測を待つ。

Issue #60の未達をIssue #31の検証済み事項に含めず、既知の可用性リスクとして分離する。完了条件を満たすまでIssue #31をcloseしない。
