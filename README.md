# StateLens : Gaze

`StateLens : Gaze` は、MEMEデバイスからBLEで取得したセンサーデータをiPhone上で可視化するアプリです。  
リアルタイム表示、視線マップ表示、9点キャリブレーション、接続安定化（自動再試行）までを含みます。

## 構成

- iPhoneアプリ（メイン）: `ios/JinsMemeIOS/JinsMemeIOS`
- Mac受信用ターゲット（任意）: `ios/JinsMemeIOS/JinsMemeMacReceiver`
- 旧Webデモ（補助）: `app.py`, `static/`, `tests/`

## 現在の機能

- BLE接続（スキャン・接続・通知購読）
- 接続状態表示
  - 成功: 青
  - 失敗: 赤 + 理由ポップアップ
- センサーデータ表示（1秒更新）
  - 水平値
  - 垂直値
  - まばたき強度
  - 受信時刻 / 表示更新時刻 / 生データHEX
- 値が変化した項目の緑点滅表示
- 視線マップ（現在点 + 軌跡）
- 9点キャリブレーション
  - 開始 / 点記録 / リセット
  - 進捗表示
- 接続安定化
  - 接続失敗時の自動再試行
  - 受信停止検知時の再接続
  - 接続セッション単位での監視（前回受信時刻による誤検知を防止）

## 最新更新（2026-03-29）

- 9点キャリブレーション失敗対策
  - 記録時に直近フレームを平均化して保存
  - 係数計算で特異行列時に正則化フォールバックを追加
- 接続安定化の見直し
  - 停止判定は「この接続で受信実績がある場合のみ」実施
  - 停止しきい値を緩和（12秒）、再接続クールダウンを延長（30秒）
- UI調整
  - `StateLens : Gaze` のタイトルサイズを `MEME接続ステータス` と統一

## 重要な前提（MEMEデータ仕様）

JINS公開SDK終了（2024-05-20案内）により、公開された一次仕様は限定的です。  
そのため、現在のBLEバイナリパーサは実機挙動に基づく実装です。

- `SensorSources.swift` の `MemeBinaryFrameParser` で解釈
- 主に `Int16 LE` の系列として処理し、水平/垂直/まばたきを推定
- 実機ログに合わせて係数・マッピングを最終調整可能

## 画面デザイン方針

- 白カード + 濃色文字で可読性優先
- 配色トークンを `ContentView.swift` の `AppPalette` で管理
- タイトルは `StateLens : Gaze` に統一

## 開発環境

- macOS + Xcode 17系
- iOS 17+
- SwiftUI

## ビルド

```bash
xcodebuild \
  -project ios/JinsMemeIOS/JinsMemeIOS.xcodeproj \
  -scheme JinsMemeIOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build
```

## 実機実行（概要）

1. Xcodeで `ios/JinsMemeIOS/JinsMemeIOS.xcodeproj` を開く
2. Signing Teamを設定
3. iPhone実機を選択して Run
4. アプリ起動後、`MEMEに接続` を押して接続

## トラブルシューティング

### Xcodeで `SIGKILL` 表示になり黒画面に見える

- `dyld` で停止している場合、アプリ本体コードではなくデバッガ停止の可能性があります。
- いったん `Product > Clean Build Folder` 後に再実行してください。
- 必要に応じて `Run Without Debugging` でも起動確認してください。

### 9点記録後に較正が失敗する

- 各点で0.5秒以上視線を固定してから「この点を記録」を押してください。
- それでも失敗する場合は `リセット` 後に再実施し、中央→四隅の順でゆっくり記録してください。

## 主要ファイル

- モデル/状態: `ios/JinsMemeIOS/JinsMemeIOS/Models.swift`
- BLE/パーサ: `ios/JinsMemeIOS/JinsMemeIOS/SensorSources.swift`
- 画面状態管理: `ios/JinsMemeIOS/JinsMemeIOS/DashboardViewModel.swift`
- UI: `ios/JinsMemeIOS/JinsMemeIOS/ContentView.swift`
- 視線推定/較正: `ios/JinsMemeIOS/JinsMemeIOS/GazeEstimator.swift`

## 現在の既知事項

- デバイス固有の生データフォーマット差異がある可能性
- 画面回転警告（`All interface orientations must be supported...`）は現状非致命

## 次にやるべきこと

1. 実機ログ（30〜60秒）を取得し、パーサ係数を最終固定
2. キャリブレーションUX（自動遷移など）を改善
3. 接続安定化パラメータ（再試行間隔/回数）を実機で最適化
4. TestFlight向けの文言・メタデータ最終調整

## 関連ドキュメント

- iOS詳細: `ios/JinsMemeIOS/README_iOS.md`
- 実装仕様: `doc/MEME_iPhone実装仕様書.md`
