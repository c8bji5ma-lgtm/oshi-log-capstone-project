# Issue #31 MVP最終QA対応表

## 2026年10月26日の追記

追記更新日時：2026年10月26日17:39 JST（08:39 UTC）。この追記では既存の結果を読み取り、テスト・起動・seed・外部通信は再実行していない。

### 受入範囲と出典

中継担当がGitHubで確認した[#31監査コメント](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/issues/31#issuecomment-6384581377)の共有範囲では、判定対象は原文と個別Issueの受入条件であり、開発2の提出URL・本番実証は#32、DPro正式合格・最終提出はCIやコード監査と別である。本担当は#31本文・卒業要件原文・外部コメント全文を取得していないため、未読部分の正式必須判定は確定しない。全例外の網羅、本番負荷試験、全実機確認などの追加監査を無条件に卒業必須へ拡大しない。

### 統合・CIの現在地

- **ローカル確認：** `7d90754a5ef7753aaf47e0afb1d00e270c043e71`はPR #115のmergeで、PR #117の補完履歴を含む。406対応commit `803b47bc31c0d0f6224ed59fd6470d800ffeda9f`はその直系で、差分は406 HTMLと関連Specの3ファイルのみ。guest変更を含まないため、今回の文書基点に使用した。
- **親のGitHub確認報告：** [PR #115](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/pull/115)・[PR #117](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/pull/117)はmain統合済み、#111・#112・#113・#114はclosed。[PR #119](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/pull/119)もmainへmerge済み（`a6904ecc8230e7ab83677fdc4570fb9ee4b62bbd`）。[PR #118](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/pull/118)はPR #116のbranchへmerge済み（`508d6a3a15d5bcab5d16c6b953cc8b06a2f6ecb5`）。その後、本人承認を受け[PR #116](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/pull/116)もmainへmerge済み（`8bc3b500f0667d4d762c21b247c0751b35906cbc`）、#109はコード・テスト受入としてclosed。**本番guest有効化・deployは未実施。**
- **親のCI確認報告：** PR #118の[run 40277944271](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/actions/runs/40277944271)は4項目成功、PR #119の事前CIも成功（run IDは本担当へ未共有）。更新後PR #116の[run 40288148222](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/actions/runs/40288148222)も成功。これらはローカル検証件数とは別の証拠である。
- `a6904ecc...`・`508d6a3a...`・`8bc3b500...`は本担当のlocal objectでは参照できなかった。fetchは行っておらず、現在の文書基点とGitHubの最新mainが同一treeであるとは断定しない。

### 再利用するローカル証拠

- **main相当コード：** `ec1826d7...`とmain `7d90754a...`は同一tree。1539 examples・失敗0、RuboCop 192ファイル・違反0の記録がある。実行コードは`6b9e286c...`で、`ec1826d7...`との差は結果記録JSONのみ（[件数・検証記録](issue-110-seed-counts.json)）。
- **guestとの互換性確認：** `f56441ba92a7184886110cda21f734005a5b8b86`はmain `7d90754a...`と修正済みPR #116 `26df4961...`のローカル統合。focused 8／related 286／全RSpec 1558 examplesはすべて失敗0、exit 0。RuboCopは197ファイル・違反0。**406変更後のmain全体を実行した結果ではない。** 記録は`tmp/issue109-main-integration-verification.json`。
- **エラー時の代表レイアウト：** `ec1826d7...`で375px／1280pxの複数入力エラー・266文字通知を4 examples確認し、失敗0、横溢れなし、修正保存・通知後の遷移成功。これは担当の実行報告で、追跡Spec・専用ログファイルは残していない。
- **初回の追加QAは失敗を保持：** `f56441b...`の5 examplesは4成功・1失敗、exit 1。対応UAは200／日本語、未対応UAは406／英語、両guestのカード・統計・本人画像は200、他人画像は404。未知URLは404だったが英語で、日本語assertionが失敗した。`tmp/issue31-local-boundaries_spec.rb`と`tmp/issue31-local-boundaries-results.txt`を保持している。
- **404の切り分け追加試験：** 同じRails stackでrequest指定のみではtest既定の`rescuable`・詳細表示`true`が優先された。テストプロセス内の表示envだけを`all`・詳細表示`false`に一時指定し、404・日本語本文・トップ`/`へのリンク・例外詳細なしを1 exampleで確認、失敗0、exit 0。既定値の復元も確認した。設定ファイル・認証仕様は変更していない。証拠は`tmp/issue31-public-404_spec.rb`と`tmp/issue31-public-404-results.txt`。本番・proxy経由の実証ではない。
- **406の日本語化：** `803b47b...`でRequest 6 examples／System 2 examplesは失敗0、exit 0。対応UA200／未対応UA406を維持し、日本語案内・トップリンク・375px／1280pxのTab／Enter・横溢れなしを確認。RuboCop 2ファイル・違反0。`tmp/issue31-406-verification.json`にコマンド・SHA256・画像を記録し、独立readonly reviewはblockingなしとの親報告を受領した。初回QAの「406英語」は変更前の履歴であり、現在の406実装の説明ではない。

`tmp/`の証拠はGit管理外のローカル保管で、公開repo上のリンクではない。異なるSHA・環境・CIの件数を合算したり、未実施の公開受入へ読み替えたりしない。

### 完了した整理と残る判断

この追記で、#111〜#114および406のコード・Specの証拠、開発8・デザイン4/5・画面遷移4に関する代表条件の確認、初回失敗と補完結果を区別した。これを原文全条件の正式合格とは扱わない。

- **#109：コード受入完了（親確認）。** 本文DoDはコード・Spec・CI中心、後続コメント／PRは公開デモ受入を追加しているという共有範囲で、親が本文と照合してclosedを確認した。本担当は未読の細部を推測しない。未検証の公開デモ分離・有効化・公開URLでの実機確認は#32へ追記済みとの親報告を受領しており、コード受入と別工程で管理する。本番有効化・deployは未実施。
- **#110：** 既存計測はschema内14/15表が各5件以上、`ActiveStorage::VariantRecord`は0。正式な適用・除外解釈が未確定のため`UNVERIFIED`を維持する。修正済みPRへ旧seed問題が残っているとは扱わず、ダミーvariantを作らない。
- **別途未確認・保留：** 外部ER／テーブル定義書の業務12表への再同期・Sheets目視、実機・VoiceOver等、公開環境の受入、学校側の正式判断。外部API・AI連携は保留のまま。これらを根拠なく新しい#31必須条件へ追加しない。

以下は追記以前の履歴であり、「現行」「最新」や#60完了までcloseしないとの方針は各確認当時の記録を指す。#60の本番資源・時間上限等は別Issueの未確認事項として維持し、卒業原文の必須条件と自動的に同一視しない。

## 基準

- アプリQA確認日：2026年10月21日
- 外部設計資料照合日：2026年10月22日
- Issue：[#31 MVP最終QA・要件照合・README更新](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/issues/31)
- 当初の確認対象commit：`edba87140d2f5d13634942ac9006e63b0555d667`（PR #83 merge後の`main`）
- 現行実装との再照合対象commit：`64c54b286c3f840242ccc878449fd9f9b6469319`（PR #106 merge後の`main`、2026年10月24日）
- 過去の基準：PR #74のmerge commitと、そのPRに対するGitHub Actions。以下では過去の検証証拠としてのみ区別して記載する
- 正式仕様の優先順：GitHub Issues、READMEから参照する要件資料、ER図・テーブル定義、実装

この文書は確定仕様を変更するものではない。現行実装と要件資料の対応、既存の検証結果、外部設計資料の照合結果、残る確認事項を記録する。

## 要件と検証の対応

| Issue #31の確認項目 | 現在の根拠 | 状態・残る確認 |
|---|---|---|
| カタログ設計の高優先度機能 | 活動CRUD、履歴・絞り込み、集計・固定費のrequest/system spec | 代表導線をChrome/Seleniumで再確認済み |
| テーブル定義書とDB構造 | `db/schema.rb`、model spec、DB制約spec、test DBメタデータ、更新後の外部テーブル定義書 | 2026年10月22日の照合時点は業務11テーブル。現行schemaは全15テーブルからActive Storage 3テーブルを除く業務12テーブルで、後から追加された`oshi_common_images`を外部資料へ再同期する必要がある。Sheetsネイティブ画面の目視も未実施 |
| ER図とモデル関連 | model、association/constraint spec、更新後の外部ER図 | 2026年10月22日の外部ER図は業務11テーブル・12コネクタとして確認済み。現行schemaの`oshi_common_images`とActive Storage関連を含む構造への再同期は未実施 |
| 主要画面遷移 | authentication、推し管理、活動・データ、固定費、プロフィール・カード、管理者のsystem spec | 今回のcommitでChrome/Seleniumの代表12 examplesを再確認済み |
| 主要画面・グローバルナビ | request/system spec、Issue #30の1280px/375px目視 | 主要幅で確認済み。全端末・支援技術の保証ではない |
| ログイン・ログアウト・管理者 | authentication、admin authorization/merging spec | 自動検証済み |
| バリデーション・エラー表示 | model、request、system spec | 正常系・主要異常系を自動検証済み |
| 画像添付 | image attachment、protected image、image library、card spec、PR #81・#82 | 10MiB・最大辺2560px・総500万画素、生成gate、クライアント縮小は実装済み。本番資源予算等は未決 |
| テストスイート・CI | 全RSpec 1423 examples、System spec 63 examples、PR #83 CI | 今回の代表12 examplesとは別の既存検証証拠として、いずれも失敗0・CI成功を確認済み |
| RuboCop等 | PR #83のlint・security checks | CI成功。今回のQA記録更新では再実行していない |
| README | リポジトリ名、起動・検証手順 | Issue #31ブランチで更新 |
| 将来機能の表記 | README、`docs/future-features/` | 公開URL・QR・交流・装飾案を将来機能として区別 |
| デバッグコード・サンプルデータ | 静的検索、development seedの環境ガード | 不要と断定できるものだけを削除対象とする。seedはdevelopment限定 |

## 承認済みIssueの資料反映履歴

初期資料の後に承認・実装された次の変更は、2026年10月22日に外部のテーブル定義書・ER図へ反映された。外部資料担当が更新内容を読戻し、ER図は画像でも確認した。

| 反映項目 | 根拠 | 現行資料・schema |
|---|---|---|
| 感情タグ | Issue #67、PR #69 | `emotions`、`activity_emotions`を含む業務11テーブルとして反映 |
| 推し画像ライブラリ | Issue #70、PR #71 | Active Storageによる代表画像・ライブラリ画像、合計30枚上限を注記。独自業務テーブルの追加なし |
| 推し共通画像 | Issue #86、PR #87 | 現行schemaへ`oshi_common_images`を追加。全15テーブル、Active Storage 3テーブルを除く業務12テーブルとなった。2026年10月22日に確認した外部テーブル定義書・ER図は追加前のため再同期が必要 |
| 楽観ロック | Issue #61、PR #72 | `activities.lock_version`、`subscriptions.lock_version`を反映 |
| 制約・将来機能 | 現行schema、Issue #26 | 複合UNIQUEの列組、NN、公開・URL・QR共有が将来機能であることを反映 |

Whimsicalのワイヤーフレーム・画面遷移図・ER図は原本を更新し、更新前コピーをバックアップとして保持した。READMEの外部リンク先は変更していない。ER図の更新時刻は2026年10月22日00:33:22 UTCである。SheetsはAPIで読戻して一致を確認したが、ネイティブ画面の目視は未実施である。

READMEには2026年10月22日時点のER図を上・中・下の3枚、画面遷移図を左・中央・右の3枚として反映した。手動配置されたZIPはSHA-256とサイズ、格納パス、symlink・暗号化・CRCを検証してから専用一時領域へ展開した。ER図は透過背景を白背景へ合成しただけで、寸法・図の内容・文字・相対配置は変更していない。6枚は明暗背景での可読性とREADME内の参照先を確認し、旧画像は削除せず保持している。READMEの分割画像には補助注記や全接続を含まないため、全体確認は既存のWhimsical原本を基準とする。

## 再利用する検証結果

- Issue #30最終調整前：非System 1327 examples + System 56 examples、失敗0
- Issue #30最終調整後：関連9 examples成功、対象3ファイルのRuboCop指摘なし、`git diff --check`成功
- PR #73：lint / scan_js / scan_ruby / test がすべて成功
- PR #83 merge前：全RSpec 1423 examples（うちSystem spec 63 examples）、失敗0、pending 0
- PR #83：最新headに対するCI全項目が成功
- PR #84：QA記録のみの変更に対するCI全項目が成功し、merge commit `0ee4a792fae2f014aad2c58c033d313514280aa1`でマージ済み
- PR #106 merge後の現行main `64c54b286c3f840242ccc878449fd9f9b6469319`：全RSpec 1486 examples、失敗0。main CIのlint / scan_js / scan_ruby / testとGHCR publishが成功。これは上記の2026年10月21日の1423 examplesとは別の検証証拠である
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

## 最終ブラウザ一巡

確認対象commit `edba87140d2f5d13634942ac9006e63b0555d667` に対し、`BUNDLE_FROZEN=true RAILS_ENV=test`、既存Chrome/Selenium、synthetic fixturesだけを使い、主要フロー11 examplesと誤パスワード1 exampleの合計12 examplesを実行して失敗0だった。全RSpec 1423 examples、System spec 63 examples、PR #83 CIは、この一巡とは別に実施済みの検証証拠である。System testのloopbackサーバー以外への通信、実メール、外部API、development DB・画像は使用していない。

### 保存画像を目視した画面

- ホーム：1280px / 375px
- 活動履歴・絞り込み：375px
- 推し一覧・画像管理：1280px / 375px
- カードの画像選択：1280px / 375px

目視証拠10枚は、Git管理外の`tmp/issue31_qa_20261021/screenshots/`に保存した。秘密情報、実利用者データ、実画像は含めていない。

保存画像では横はみ出し、部品の重なり、文字切れ、操作不能な導線は見つからなかった。

### 自動assertionで確認した導線

- ログインからマイページ
- 推し登録、管理者承認、別利用者による追加
- 活動登録、履歴絞り込み、編集、集計更新
- 固定費登録、編集、推し関連変更、可視化更新
- プロフィール保存、写真カード、思い出カード、データカードの生成・download
- 一般利用者の管理者画面拒否とlogout後の認証要求

これらはWSL上のChrome/Selenium確認であり、物理スマートフォンや各ブラウザの実機確認ではない。

Issue #60のiPhone Safari確認では、保存後の画像表示が遅いとの報告と、透過PNGが灰色に見える事象があった。遅延の実測区間・透過保持の保存後検査は完了しておらず、ユーザー判断で今回保留した既知リスクであるため、解消済みとは扱わない。

## 限定アクセシビリティQA

2026年10月22日、検証commit `2cc1de93d37c25d83b370e3f6dcc52191f962337` に対し、MSI上の既存Chrome 151・Selenium・Chrome Accessibility Treeを使って追加確認した。前記の主要12フロー、全RSpec 1423 examples、System spec 63 examplesは別日に取得した証拠であり、今回は再実行していない。

- ホーム、推し一覧、活動一覧、固定費、プロフィール、カード作成の6画面で、ログインを含むTab移動80観測を記録した。フォーカストラップはなく、Enterによるナビ遷移、カードのラジオ選択に対するSpace・右矢印、視認可能な3pxフォーカス枠を確認した。
- 6画面のChrome Accessibility Treeで、表示中コントロールの名前欠落は0件だった。`main`、グローバルナビゲーション、見出し、profile/cardのstatus・alert領域を確認した。
- solid background上で測定可能な通常文字96要素は基準未達0件で、最低値は5.61:1（通常文字の基準4.5:1）だった。画像・gradient・非テキスト境界・全hover状態の数値保証ではない。
- 1280px画面に対してChrome CDPで640/320 CSS px・DPR 2/4を設定し、200%/400%相当のreflowを6画面12条件で確認した。横溢れ検出は0件で、代表4画面は保存画像でも文字欠落・部品重なり・横スクロールがないことを目視した。
- 証拠はGit管理外の`tmp/issue31_accessibility_20261022/`に保存した。専用test DBへ作成した合成4レコードはID照合後に削除し、専用loopbackサーバーも停止した。Git追跡ファイル、developmentデータ・画像、本番、外部サービスには触れていない。

CDPによるreflow確認はheaded Chromeで`Ctrl`+`+`を操作した結果ではなく、Chrome Accessibility Treeの確認もiPhone VoiceOver等の実支援技術の成功を意味しない。

### iPhone Safariでの限定報告

2026年10月22日、合成データの確認用画面をiPhone Safariで確認した本人から「問題なさそう」と報告があった。初回は一時Pumaの停止により接続できず、同じiPhone限定設定で再起動後に確認した。

この報告は、VoiceOver、個別手順の全項目、保存後の画像表示遅延・透過、または本番環境を確認済みとするものではない。

2026年10月24日、本人からiPhoneでの確認は完了しており作業を進めてよいとの追加報告があった。これは本人申告による完了記録であり、エージェントが独立して端末画面・操作結果を検証したものではない。確認した個別操作は列挙されていないため、PNGの実寸一致、VoiceOver、Safariの全機能、画像表示遅延・透過表示まで確認済みとは扱わない。

## 公開前の追加Chrome一巡

2026年10月22日、最新mainのcommit `34d130c9e5d83b8e9ed9388fb5f4a571a54b27c6` に対し、`BUNDLE_FROZEN=true RAILS_ENV=test`、専用`my_app_test`、`tmp/storage`、合成データだけを使って追加確認した。

- 初回の検索ゼロから本人用pending推しを登録し、選択済みの最初の活動を保存する導線
- 活動の登録・編集、集計更新、集計から条件付き活動一覧へのドリルダウンと戻り先
- 保存済みプロフィールを使った写真・思い出・データの3テンプレート、プレビュー、PNG保存
- 375px / 1280pxの推し検索、活動編集、集計、カード作成画面

既存system spec 5 examplesは失敗0だった。追加のスクリーンショット用harnessは、初回にCapybaraが未対応の`full:`引数で1件失敗したが、製品処理へ到達する前の検証コード不備だった。引数を除いた同harness 1 exampleは成功した。直前の全RSpec 1458 examples（System spec 68 examples）、失敗0、pending 0と、main CI全4項目成功は同一内容の別証拠として再利用し、全件を再実行していない。

Git管理外の`tmp/issue31_release_readiness/screenshots/`へ8枚を保存し、375×669pxと1280×757pxの画像を実際に開いて確認した。確認した4画面では文字切れ、部品の重なり、横スクロールを検出しなかった。これはChromeのスマートフォン相当幅であり、iPhone実機確認ではない。

今回の合成レコードはRSpecのtransaction内、画像は分離された一時領域で扱い、追加のRailsサーバーは起動していない。developmentデータ・原画像、既存localhost:3000、本番、外部APIには触れていない。

## 独立PoCバックアップとの照合

指定された非公開バックアップは、Issue #68のAIプロフィール帳PoCを保存した独立スナップショットである。Rails本体・DBを含まず、現在の本体へPoCコードは移植されていない。

- オフラインの合成データを使ったPoC検証と、当時のカード関連回帰結果は履歴上の補助根拠として参照できる
- 実API、実キー、実費、実画像の意味理解、Rails本体の全system specは検証範囲外
- 固定キャンバスの配置・crop・文字描画に関する結果であり、Issue #60が求める入力画像の寸法・総画素数・デコード資源・並列負荷の上限測定には代用できない
- コードと環境が異なるため、PoCの成功件数を現在の本体commitの合格結果として合算しない

バックアップの資料本文、画像、接続情報、個人パス、認証情報はこの公開文書へ転載しない。

## 残る確認と優先順位

1. `oshi_common_images`追加後の業務12テーブルを外部テーブル定義書・ER図へ同期し、Sheetsをネイティブ画面で目視してAPI読戻しでは判別できない表示上の欠落がないことを確認する
2. 本人申告で完了したiPhone確認の範囲を必要に応じて特定し、Chrome以外の実ブラウザとVoiceOver等の実支援技術を確認する
3. 実メール・外部API・本番環境、およびIssue #60の本番資源予算・複数worker・native hard timeoutを確認する
4. iPhone Safariで保留した保存後表示遅延と透過表示を、原ファイル・保存blob・表示CSSを区別して再確認する

## Issue #60と本番環境の分離

Issue #60ではPR #81・#82により、既存10MiB制約に加えて最大辺2560px・総500万画素のサーバー側検査、プロセス内カード生成同時1件のgateと503 `Retry-After: 5`、対応画像のクライアント側コピー縮小が実装済みである。既存保存画像の原本・通常表示を維持し、カード利用時に制限する方針も実装済みである。

ローカルではJPEG・PNG・WebP、EXIF・ICC・16bit等の代表ケースと実レンダラを隔離測定し、5MP画像4枠の代表値も取得済みである。ただし本番EC2でOS・PostgreSQL等と同居した際の資源予算、複数worker間の同時実行制御、実HTTP並列生成、native処理のhard timeoutは未確定である。寸法・画素制限だけでCPU・時間・本番可用性を保証するものではない。

Issue #60の未達をIssue #31の検証済み事項に含めず、既知の可用性リスクとして分離する。完了条件を満たすまでIssue #31をcloseしない。
