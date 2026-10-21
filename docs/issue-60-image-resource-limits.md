# Issue #60 画像リソース制限の測定根拠

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

Rails込み代表ケースの sampled process VmRSS peak は626,028KiB、VmHWMは626,384KiBだった。process RSSとcgroup値は共有ページ・ページキャッシュ・課金方法が異なるため同一指標として比較しない。

EXIF orientation=6、588-byte sRGB ICC、true 16-bit PNGもactual `Cards::Photo` のzoom3で正常終了し、入力SHA-256が不変であることを確認した。Photo1の16:9・zoom3も既存の表示範囲を維持して正常終了した。

## 採用する入力制限

- 既存の1画像10MiB以下を維持
- 最大辺4096px以下
- 総画素数12,500,000以下
- JPEG・PNG・WebP、単一ページ、非animationという既存条件を維持
- 新規uploadとカード利用時の両方で共通検査
- 原画像を加工・上書き・削除しない
- 既存の上限超過画像は通常表示を維持し、カード利用時に理由付き422

4096pxだけでは4096×4096（約16.8MP）を許すため、最大辺と総画素数を同時に適用する。

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
