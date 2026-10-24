# Issue #60 画像リソース制限の測定根拠

## 現行実装との対応

- merge commit: `4c47a1f`（PR #81）
- 実装commit: `5bf3751`（寸法制限・描画同時実行制御）、`62f1f20`（最大辺2560px・総500万画素へ調整）
- 現行main照合commit: `64c54b286c3f840242ccc878449fd9f9b6469319`（PR #106 merge後、2026年10月24日）
- `ImageAttachmentInspector`に形式・容量・最大辺・総画素数・単一ページ・非animationの検査を集約し、upload時とカード利用時の双方で適用する
- `Cards::RenderGate`でカード生成をprocess内同時1件にし、使用中は`503 Service Unavailable`と`Retry-After: 5`を返す
- libvipsのprocess内cacheを無効化し、利用者のprivate画像をrequest間で保持しない

公開Issue本文のAs-Isと未チェック欄は実装前commitを基準としており、この文書に記録した現行実装とは一致していない。Issue本文自体の更新・closeはこの文書更新の対象外とする。

## 条件

- 実行日: 2026-10-21
- 環境: MSI / Ubuntu WSL2、Ruby 4.0.6、Rails 8.1.4、libvips 8.16.1
- 隔離: Docker、networkなし、swapなし、CPU 1、同時コンテナ1、read-only root
- 素材: 専用一時領域で生成した合成JPEG・PNG・WebPのみ
- 実画像、開発DB、本番DB、AWSには接触していない

記録値はローカルの代表実測であり、本番性能やhard timeoutを保証しない。

## 代表結果

| ケース | cgroup memory.peak | wall / CPU |
|---|---:|---:|
| Photo1・12.2MP JPEG・zoom1 | 約92.6MB | 0.754 / 0.756秒 |
| Photo4・12.2MP JPEG/PNG/WebP混在・zoom3 | 約291.8MB | 2.127 / 2.113秒 |
| Memory3・12.2MP JPEG/PNG/WebP混在・zoom3 | 約235.7MB | 1.746 / 1.740秒 |
| Photo4・12.2MP WebP×4・zoom3 | 約528.2MB | 3.584 / 3.578秒 |
| Photo4・24MP WebP×4・zoom3 | 約793.6MB | 1.738 / 1.743秒 |
| Rails preload + Photo4・12.2MP WebP×4・zoom3 | 約614.1MB | 3.564 / 3.508秒 |
| Rails preload + Photo4・8MP WebP×4・zoom3 | 約517.9MB | 2.353 / 2.333秒 |
| Rails preload + Photo4・5MP WebP×4・zoom3 | 約366.7MB | 1.763 / 1.759秒 |

Rails込み代表ケースの sampled process VmRSS peak は626,028KiB、VmHWMは626,384KiBだった。process RSSとcgroup値は共有ページ・ページキャッシュ・課金方法が異なるため同一指標として比較しない。

候補測定はいずれも同一画像4枚の保守的な代表ケースで、入力SHA-256不変と正常出力を確認した。12.2MPケースに対して5MPはcgroup peakが約247MB（約40%）低く、安全余裕を優先して5MPを選択した。

EXIF orientation=6、588-byte sRGB ICC、true 16-bit PNGもactual `Cards::Photo` のzoom3で正常終了し、入力SHA-256が不変であることを確認した。Photo1の16:9・zoom3も既存の表示範囲を維持して正常終了した。

### 2026年10月24日の限定再測定

現行mainと同じlibvips 8.18.0を使い、平坦な合成WebP 1枚をdecodeし、800×600へ縮小して1600×1000 canvasへ合成し、PNGへencodeした。逐次2ケースだけを実行し、DB・実画像・本番環境は使用していない。

| ケース | process最大RSS | wall |
|---|---:|---:|
| 1,000×1,000（1MP） | 約82.6MiB | 0.56秒 |
| 2,500×2,000（5MP） | 約143.5MiB | 0.83秒 |

これは平坦な合成画像1枚の軽量な再確認であり、上記の写真相当・複数画像・Rails preload込みの隔離測定を置き換えない。本番性能、同時実行、hard timeoutの保証にも使用しない。

## 採用する入力制限

- 既存の1画像10MiB以下を維持
- 最大辺2560px以下
- 総画素数5,000,000以下
- JPEG・PNG・WebP、単一ページ、非animationという既存条件を維持
- 新規uploadとカード利用時の両方で共通検査
- 原画像を加工・上書き・削除しない
- 既存の上限超過画像は通常表示を維持し、カード利用時に理由付き422

2560pxだけでは2560×2560（約6.55MP）を許すため、最大辺と総画素数を同時に適用する。固定の中間画素数上限は設けず、既存のzoom 1〜3と16:9 zoom3に必要な内部拡大を維持する。

## 同時実行

カード生成はprocess内gateで同時1件とし、使用中は `503 Service Unavailable` と `Retry-After: 5` を返す。これは利用者単位のrate limitではなく、サーバー処理枠が使用中であることを示す。

gateは複数Puma worker・複数ホストをまたがない。本番では当面 `WEB_CONCURRENCY=1` が前提候補だが、この変更では本番設定を変更しない。

## 未解決・別段階

- Rubyのthread timeoutはnative libvips処理を安全に強制停止する保証にならない
- hard timeoutには子process・job等の隔離設計が必要
- t3.small上でPostgreSQLを同居させた実メモリ予算
- 実HTTP並列負荷
- 24MPをRails込みで処理する安全性
- 複数worker・複数host間の同時実行制御

## 現行検証証拠

- `spec/services/image_attachment_inspector_spec.rb`：最大辺・総画素数、EXIF orientation、ICC、16bit PNG、破損画像等
- `spec/services/cards/render_gate_spec.rb`：同時実行拒否、lock解放、例外時解放
- `spec/requests/cards_spec.rb`：制限超過の安全な応答、生成中の`503`と`Retry-After`
- 2026年10月24日の関連RSpec 86 examples、失敗0
- PR #106 merge後のmain CIはlint / scan_js / scan_ruby / testが成功。Issue #60実装時のPR #81の検証証拠とは区別する

現行の寸法・画素数制限とprocess内gateは実装済みだが、PostgreSQL同居の本番資源予算、実HTTP並列負荷、複数worker・複数host、native処理のhard timeoutは未確認であり、解消済みとは扱わない。
