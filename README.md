# StateLens : Gaze (JINS MEME Logger 互換版)

`StateLens : Gaze` は、MEMEデバイスからBLEで取得したセンサーデータを可視化・記録するiOSアプリです。
公式アプリ「JINS MEME Logger」と同等の4タブ（接続・ロガー・CSV・設定）構造に、従来の「Gaze（視線トラッキング・較正）」機能を統合した5タブ構成へと進化しました。

## アプリ構成（5タブ）

1. **🔗 接続 (Connect)**
   - BLEスキャン、接続、切断
   - Logger連携モード（Macでの受信データをブリッジ）
   - BLE通信の診断情報やパケット受信ステータスの表示
2. **📝 ロガー (Logger)**
   - リアルタイムデータ表示（まばたき、視線移動、加速度、角度など6セクション構成）
   - 各種値の推移を示すミニチャート表示
   - バックグラウンドでのCSVデータ記録の開始・停止
3. **📂 CSV**
   - デバイス内に保存された記録済みCSVファイルの一覧表示
   - OS標準の共有シートを利用した外部アプリへのファイル出力・共有
   - ファイルの個別削除および複数ファイルの一括削除
4. **⚙️ 設定 (Settings)**
   - データの自動保存、保存周期、ジャイロ・加速度取得のON/OFF
   - UserDefaultsを利用したアプリ設定の永続化
5. **👁 Gaze**
   - 視線データの2Dマップ表示（現在点 + 軌跡）
   - 精度の高い視線推定を行うための9点キャリブレーション機能

## 最新のアップデート（2026-03-29）

### 1. JINS MEME Logger 互換UIへの刷新
- 単一Scroll画面からTabViewを用いたモダンな5タブ構成に全面リニューアル。
- `CSVRecorder` を新規実装し、取得したセンサーデータ（`SensorFrame` および拡張データ）のCSVファイル保存機能を追加。

### 2. BLE接続安定化とデータ更新問題の抜本的改修
一時的に発生していた「接続直後の切断（error=nil）」および「データ未更新」問題を解決するための通信層アップデートを実施しました：
- **自動再接続の有効化**: 意図しない切断時に自動で再試行（最大3回）とストール復旧を行うようViewModelを設定変更。
- **ストリーム開始の即時稼働**: JINS MEMEの切断タイムアウトを防ぐため、Notify有効化後のコマンド送信遅延を0.35秒から0.1秒へ短縮。
- **維持パルスの無条件送信**: ストリーム確立前でも定期的に通信維持コマンドを送信し、不要な接続ドロップを抑制。
- **データ更新の即時反映**: 1秒サイクルのタイマー更新依存から脱却し、接続直後の初回フレーム受信時には直ちにUI描画へ反映させる処理を追加。

## 開発環境

- macOS / Xcode 17+
- iOS 17.0 以降
- Swift / SwiftUI

## ビルド手順

```bash
xcodebuild \
  -project ios/JinsMemeIOS/JinsMemeIOS.xcodeproj \
  -scheme JinsMemeIOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build
```

## プロジェクト主要ファイル

- **UI / Views**
  - `ContentView.swift` (5タブのルートコンテナ)
  - `ConnectTab.swift`, `LoggerTab.swift`, `CSVTab.swift`, `SettingsTab.swift`, `GazeTab.swift`
  - `MiniLineChartView.swift` (ロガー画面のチャート部品)
- **ViewModel / Core Logic**
  - `DashboardViewModel.swift` (UIバインディング、記録制御、BLEイベントハンドリング)
  - `CSVRecorder.swift` (CSVのフォーマット生成・ファイル書き込み周りの管理)
  - `SensorSources.swift` (JINS MEME用BLEパーサ、デバイス通信の根幹)
  - `GazeEstimator.swift` (アフィン変換ベースの視線推定と較正)
- **Models**
  - `Models.swift` (SensorFrame拡張、アプリ内設定用構造体)

## 今後の課題 (Next Steps)

1. **BLEパーサの機能拡張**: ロガータブで現在0表示となっている「加速度 / ジャイロ」等の追加データをMemeバイナリフレームから抽出する処理の実装。
2. **実機デプロイテスト**: iPhone実機での接続テスト、および10分以上の連続CSV保存安定性チェック。
