# MEME接続 iPhoneアプリ 実装仕様書

- 作成日: 2026-03-28
- 対象: `ios/JinsMemeIOS`（SwiftUI / iOS 17+）
- 参照した既存資料:
  - `README.md`
  - `ios/JinsMemeIOS/README_iOS.md`
  - `ios/JinsMemeIOS/JinsMemeIOS/*.swift`

## 1. 背景と目的

本リポジトリには、JINS MEME ESのデータを受信して視線を可視化する仕組みが2系統ある。

1. PythonサーバーにJSONをPOSTしてブラウザで表示する方式（`README.md`）
2. iPhoneネイティブでBLE受信し、SwiftUIで表示する方式（`ios/JinsMemeIOS`）

今回の目的は **2. iPhoneネイティブ方式を実運用可能にすること**。

## 2. 現状整理（既存実装でできていること）

### 2.1 実装済み

- iPhone側UI（視線点、軌跡、9点キャリブレーション）
- `CoreBluetooth` の初期化・スキャン・接続・Notify購読
- `mock` 信号で動作確認
- `MultipeerConnectivity` によるMac/iOSへのフレーム共有
- Bluetooth / ローカルネットワーク権限（Info.plist設定済み）

### 2.2 未確定 / 差し替え前提

- JINS MEME ESのService UUID
- Notify Characteristic UUID
- Notifyペイロードのバイナリ仕様
- `parseFrame(_:)` の実データ対応

この4点が埋まれば、既存アプリ構造で要件を満たせる。

## 3. ゴール定義

### 3.1 機能ゴール

- iPhoneがJINS MEME ESとBLE接続できる
- センサー通知から `SensorFrame(horizontal, vertical, blinkStrength)` を生成できる
- 生成データをリアルタイム表示できる（点 + 軌跡）
- 9点キャリブレーション後に視線座標が安定する

### 3.2 非機能ゴール

- 20Hz以上で更新（目安）
- 切断時に自動で再スキャン/再接続を試みる
- パース失敗時にアプリが落ちない

## 4. 実装方針

## 4.1 採用アーキテクチャ

- UI/状態管理: `DashboardViewModel`
- 推定: `GazeEstimator`
- 入力ソース: `SensorSource`プロトコル
  - `MockSensorSource`
  - `JinsMemeBLESource`（本件の主対象）

この抽象化は既に実装済みのため、BLE部分のみ実装を確定すればよい。

## 4.2 実装対象ファイル

- `ios/JinsMemeIOS/JinsMemeIOS/Models.swift`
  - `BLEConfiguration.serviceUUID`
  - `BLEConfiguration.notifyCharacteristicUUID`
- `ios/JinsMemeIOS/JinsMemeIOS/SensorSources.swift`
  - `parseFrame(_:)` の実データ対応
  - 切断時再接続・ログ強化（必要に応じて追加）

## 4.3 データ変換仕様

### 入力

- BLE通知ペイロード（生バイト列）

### 出力

```swift
SensorFrame(
  timestamp: Date,
  horizontal: Double, // -1.0 ... 1.0想定
  vertical: Double,   // -1.0 ... 1.0想定
  blinkStrength: Double,
  source: "bluetooth"
)
```

### 正規化ルール

- デバイス生値が整数レンジの場合、観測最小/最大から `[-1, 1]` に線形正規化
- 上下方向の符号は、UI上で自然な動き（上を見るとyが減る）になるよう合わせる
- `blinkStrength` が無い場合は `0` を暫定値とする

## 5. 実装ステップ

1. **BLE仕様確定**
- 実機/既存ブリッジから Service UUID と Characteristic UUID を取得
- 通知データ1〜2分をキャプチャしてフォーマット解析

2. **定数反映**
- `BLEConfiguration` にUUIDを実値で設定

3. **パーサ実装**
- `parseFrame(_:)` を実フォーマットに合わせて実装
- 例外パケット長/不正値の防御を実装

4. **接続安定化**
- `didDisconnectPeripheral` を実装し、再接続戦略を追加
- 状態表示文言を「スキャン中/接続中/受信中/再接続中」に統一

5. **表示・較正検証**
- mockモードとの挙動比較
- 9点キャリブレーションで中心/四隅を確認

6. **共有検証（任意）**
- Mac Receiverへ `SensorFrame` が中継されることを確認

## 6. テスト仕様

### 6.1 手動テスト

- Bluetooth権限拒否時にクラッシュしない
- MEMEが見つかる/見つからない両ケースで状態表示が正しい
- 接続後に5分以上データ受信が継続
- デバイス電源OFF→ONで再接続できる
- 9点較正後、注視位置とのズレが許容範囲内（体感）

### 6.2 ログ観点

- 受信パケット長
- パース成功率
- 毎秒フレーム数（FPS相当）
- 切断理由（Error内容）

## 7. 受け入れ基準（Definition of Done）

- 実機MEMEとiPhoneが接続し、リアルタイム表示できる
- `parseFrame(_:)` が実データで動作する
- 10分連続運転でクラッシュ/フリーズなし
- キャリブレーション後に視線移動が画面上で自然に追従
- （任意）Mac Receiverに中継される

## 8. リスクと回避策

- リスク: 公開SDK終了により公式仕様参照が困難
- 回避策: 既存ブリッジ/社内資料/実機キャプチャを一次情報として確定

- リスク: BLE通知形式が複数パターン存在
- 回避策: `parseFrame(_:)` を段階的デコーダ構成（ヘッダ判定→各デコーダ）にする

- リスク: ノイズで視線が跳ねる
- 回避策: `GazeEstimator.alpha` 調整、必要に応じて外れ値除去を追加

## 9. 代替実現案（BLE仕様未確定時）

BLE仕様が確定できない場合は、短期的に以下で実現可能。

- iPhoneアプリは `mock` ではなく「HTTP受信モード」を追加
- 既存ブリッジが `/api/ingest` へ送っているJSONをiPhone側でも受ける

ただし本要件「MEMEに接続して取得」に対しては直接BLE方式が本命。

## 10. 直近の実装TODO（優先順）

1. MEME実機からUUID・通知サンプル取得
2. `BLEConfiguration` 反映
3. `parseFrame(_:)` 実装
4. 再接続処理追加
5. 実機で10分連続テスト
6. 必要ならCSV保存を追加

