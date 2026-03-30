# StateLens : Gaze (JINS MEME Logger 互換 & 高精度視線計測版)

`StateLens : Gaze` は、JINS MEME からのセンサーデータを BLE（Bluetooth Low Energy）または公式アプリ「JINS MEME Logger」経由で取得し、リアルタイムに可視化・記録・視線推定を行う iOS アプリケーションです。

## 特徴

- **20Hz+ フルサンプリング記録**: 独自のキューシステムにより、JINS MEME の全データを欠損なくキャッチし、グラフ描画と CSV 保存を行います。
- **6軸IMU完全対応**: バイナリパケットを直接解析することで、加速度(Acc)およびジャイロ(Gyro)の全データを取得・表示します。
- **Logger 連携モード**: 公式アプリ「JINS MEME Logger」の WebSocket クライアント機能を利用し、Wi-Fi 経由でデータを受信するブリッジ機能を搭載。
- **高精度視線推定**: 9点キャリブレーション（較正）機能を備え、個々人の目の特性に合わせた 2D 視線トラッキングが可能です。

## アプリ構成（5つのタブ）

1. **🔗 接続 (Connect)**
   - BLE デバイスのスキャンと直接接続。
   - Logger 連携モード（ローカル WebSocket サーバーの起動と IP 表示）。
   - パケット受信数やバイナリデータの HEX ダンプ表示による診断機能。
2. **📝 ロガー (Logger)**
   - リアルタイム・マルチチャート（まばたき、視線移動、加速度、角度、ユーティリティ）。
   - 20Hz のパルスイベント（まばたき等）を逃さない高速バッチ描画。
   - バックグラウンド対応の CSV 記録（すべての受信フレームを保存）。
3. **📂 CSV**
   - 記録済みデータの管理、外部アプリへの共有・出力、一括削除。
4. **⚙️ 設定 (Settings)**
   - 記録間隔やセンサーの有効/無効の切り替え。
5. **👁 Gaze**
   - キャリブレーション済みの視線座標（x, y）のリアルタイムマッピング。
   - 9点キャリブレーションの実施と、アフィン変換による推定ロジック。

## 更新履歴（2026-03-30）

### 🚀 データ処理の高速化と安定化
- **1Hz サンプリング制限の撤廃**: これまで 1 秒に 1 回しか反映されていなかった描画・記録ロジックを刷新。キューイングシステムにより、毎秒約 20 個届く全データを漏れなく処理・保存するように修正しました。
- **まばたき・視線スパイクの確実な検知**: 高速なタイマー（0.1s/10Hz）によるイベントバッチ処理により、一瞬のまばたきや視線移動もグラフに反映されます。

### 🛠 Logger 連携フォーマットの拡張
- JINS MEME Logger アプリから送信される様々な JSON キー（`up`, `down`, `left`, `right`, `strength` 等）に対応し、連携時の互換性を向上させました。

## 開発・ビルド環境

- **OS**: macOS / iOS 17.0+
- **Tool**: Xcode 17+
- **Language**: Swift / SwiftUI

### プロジェクト構成

- `ios/JinsMemeIOS/JinsMemeIOS/SensorSources.swift`: 通信・パケット解析の核。
- `ios/JinsMemeIOS/JinsMemeIOS/DashboardViewModel.swift`: UI状態管理とデータバッファリング。
- `ios/JinsMemeIOS/JinsMemeIOS/GazeEstimator.swift`: 視線推定エンジンの実装。

## ビルド手順

```bash
xcodebuild \
  -project ios/JinsMemeIOS/JinsMemeIOS.xcodeproj \
  -scheme JinsMemeIOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build
```

---
**StateLens : Gaze** &copy; 2026 - Optimized for Research and High-speed sensor logging.
