# DPro卒業要件：是正・提出準備記録（2026年10月26日）

> **用途：** 新子さんのOshiLogを、DProの正式な卒業要件39項目と優先度「高」の機能に照らして再検証するための記録。
>
> **原文：** [オリジナルアプリケーションの課題説明](https://github.com/divic-corp/cdp_web_text/blob/master/text/ja/ruby_original_application_development/dep_original_application.md)。
> **監査基準：** [main `97e2778e9559da3f1d51ef6887a1a3e220c2cef4`](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/commit/97e2778e9559da3f1d51ef6887a1a3e220c2cef4)。
> **初回監査時点の状態：** `WORKING_DRAFT`。コードの修正案・Pull Requestは**未マージ／未リリース**です。DProの公式提出・合格を表すものではありません。

## 2026年10月26日の追記

追記更新日時：17:39 JST（08:39 UTC）。第1〜6節はmain `97e2778e...`時点の監査・提出準備履歴として残し、以下の更新と区別する。今回は文書のみの照合で、テスト・外部通信・提出を実行していない。

- PR #115・#117はmain `7d90754a...`へ統合済み。#111・#112・#113・#114 closedは親のGitHub確認報告であり、下表の当初不足が現在も未修正という意味ではない。
- 406対応commit `803b47bc31c0d0f6224ed59fd6470d800ffeda9f`はローカル確認済み。Request 6／System 2 examples・失敗0、RuboCop 2ファイル・違反0、独立review blockingなし（reviewは親報告）。PR #119はmainへmerge済みという親報告を受領した（`a6904ecc8230e7ab83677fdc4570fb9ee4b62bbd`）。このmerge objectは手元未取得のため、今回の文書基点は`803b47b...`とした。
- PR #118はPR #116のbranchへmerge済み（`508d6a3a15d5bcab5d16c6b953cc8b06a2f6ecb5`、objectは手元未取得）。PR #118／#119の事前CI、更新PR #116の[CI 40288148222](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/actions/runs/40288148222)成功は親確認の情報である。その後、本人承認を受けPR #116もmainへmerge済み（`8bc3b500f0667d4d762c21b247c0751b35906cbc`、objectは手元未取得）、#109はコード・テスト受入としてclosedと親が確認した。本番有効化・deployは未実施。
- ローカル統合`f56441b...`の全RSpec 1558 examples・失敗0／lint 197ファイル・違反0は、main `7d90754a...`＋修正済みPR #116のコードを対象とする。最新remote main全体の再実行結果とは扱わない。初回追加QAの5例4成功1失敗と、表示envを切り分けた404追加1例成功も別証拠として保持した。
- #109のコード受入は完了（親確認）。公開デモ分離・有効化・公開URLでの実機確認は未検証として#32へ追記済みとの親報告を受領し、公開工程とコード受入を分ける。#110は14/15表が各5件以上・VariantRecord 0、正式な要件解釈未確定の`UNVERIFIED`である。外部ER／Sheets、実機・VoiceOver、公開環境・学校側判断は未確認、外部API・AI連携は保留。

親が確認した[#31監査コメント](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/issues/31#issuecomment-6384581377)の共有範囲に従い、原文と個別Issueの受入条件だけを判定対象とし、開発2の提出URL・本番実証は#32、正式合格・最終提出はコード／CIと別に管理する。本担当は原文・コメント全文を取得しておらず、未読部分の正式判定や全例外・本番試験等の新しい必須化は行わない。対象SHA、コマンド、ローカル証拠の所在・限界は[Issue #31 QA対応表](../issue-31-qa.md)を参照。

## 1. 監査の結論

mainの[GitHub Actions #40058803144](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/actions/runs/40058803144)では、RSpec **1,497件、失敗0件**です。一方で、以下の卒業要件に不足を確認しました。CIの成功だけで不足を合格扱いにはしません。

## 2. 未達9項目と実装対応

| 要件 | 監査時点の判定 | 是正対象 | 認定前に必要な検証 |
| --- | --- | --- | --- |
| 開発5：独自404・500 | NOT MET | #111／Draft PR #115：独自日本語エラー画面 | 実際のHTTP 404・500時の表示・ステータス |
| 開発9：各テーブル5件以上のseed | NOT MET | #110／Draft PR #115：別名・感情リンク・共通画像などを補完 | 12業務表の件数と冪等性、残る運用表の課題解釈 |
| デザイン3：公用語表示 | NOT MET | #111／Draft PR #115：400・404・422・500を日本語化 | 利用者に見える主要エラー状態の日本語表示 |
| デザイン8：ヘッダーとフッター | NOT MET | #112／Draft PR #115：共通footerを追加 | 未認証・認証済み画面の実表示 |
| デザイン9：ヘッダー最上部・フッター最下部 | NOT MET | #112／Draft PR #115：縦方向のflexレイアウト | 短いページ・長いページ・375px／1280pxの表示 |
| 機能3：管理者・一般利用者のゲストログイン | NOT MET | #109：安全な公開ゲスト環境の設計・実装を別作業として維持 | 管理者・一般利用者のログイン／ログアウト、一般の管理操作拒否、実データの隔離 |
| System Spec2：各モデルのCRUD | NOT MET（後発の管理CRUD） | #113／Draft PR #115：推し共通画像の登録・一覧・編集・削除のブラウザテスト | PRのテスト実行結果と既存のCRUD対応 |
| Model Spec1：全バリデーション | NOT MET | #114／Draft PR #115：`OshiCommonImage`の宣言済みvalidationの正常・異常テスト | 全validationとSpecケースの対応、CI成功 |
| Model Spec2：使用scope | NOT MET（厳格解釈） | #114／Draft PR #115：`OshiCommonImage.active`の包含・除外テスト | Model Spec成功、scopeの使用状況と原文解釈 |

## 3. 証拠不足5項目

| 要件 | 状態 | 確認・提出すべき記録 |
| --- | --- | --- |
| 開発2：HerokuまたはEC2へデプロイ | UNVERIFIED | [#32](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/issues/32)で公開URL・配備先・コミット・HTTPS・認証・画像保存の実測を確認する。GHCRの公開だけでは代替不可 |
| 開発8：利用中の例外抑止 | UNVERIFIED | [#31](https://github.com/c8bji5ma-lgtm/oshi-log-capstone-project/issues/31)で通常利用の主要フロー・異常系の結果を記録する |
| デザイン4：エラー時のレイアウト維持 | UNVERIFIED | フォームの複数エラー・長いFlashを実ブラウザで確認。スクロール幅と入力操作を記録 |
| デザイン5：未完成画面なし | UNVERIFIED | 公開する全画面・エラー画面の一覧と実際の見た目を確認。未確認を「問題なし」としない |
| 画面遷移4：不適切な遷移なし | UNVERIFIED | 未認証・認証済み・一般利用者・管理者の主要遷移と拒否後の戻り先を確認 |

## 4. 優先度「高」の機能

[カタログ設計（正本）](https://docs.google.com/spreadsheets/d/1hWaamzG78rVdf1tu79aZMsmti1YSxQMKiD_1AjhuCVg/edit)での高優先度は、①推し・推し活記録、②履歴・振り返り、③データ可視化の3機能です。主要実装とRSpecはありますが、①に含まれる推し共通画像の追加テストを完了条件として扱います。

## 5. 提出の状態と手順

- **未確認：** 前課題「要件定義」の学校側合格、変更した設計資料の再投稿・メンター連絡、公開アプリURL、DProの最終提出完了。
- **この記録で実施したこと：** コード・RSpec・Issueと提出説明の準備。学校への投稿、本人になり代わる提出、メンターの正式受入は行っていません。
- **必要な実作業：** 未充足Issueの完了証拠を確認 → 現行main/公開アプリへ統合・配備 → 公開URLと代表操作を記録 → 本人がDProで提出し完了画面を保存。

## 6. 記述規範と禁止事項

[CDS統括正本 #4253992](https://diveintocode.docbase.io/posts/4253992)、[CDS日本語 #4253986](https://diveintocode.docbase.io/posts/4253986)、[CDS品質 #4253990](https://diveintocode.docbase.io/posts/4253990)、[CDS適用台帳 #4253991](https://diveintocode.docbase.io/posts/4253991)（2026-10-26に確認）。未実施のテスト・本番配備・提出・学校合格をPASSと記載しません。OshiLog独自の画面をDIVICの企業色に無断変更しません。
