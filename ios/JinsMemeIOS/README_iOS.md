# JinsMemeIOS

JINS MEME ES の受信を iPhone ネイティブアプリ寄りで進めるための SwiftUI ベース実装です。

## 含めたもの

- SwiftUI の視線ダッシュボード
- 9点キャリブレーション
- 視線点とヒートトレイル表示
- `CoreBluetooth` ベースの受信レイヤ
- `MultipeerConnectivity` による近距離共有
- `mock` 入力で UI 単体検証可能
- Mac 受信アプリのターゲット

## 重要な前提

JINS MEME の公開 SDK / Web API は公式案内で `2024-05-20` に終了しています。そのため、現時点のコードでは以下を分けています。

- iPhone アプリ本体: 実装済み
- JINS MEME ES の BLE 通知フォーマット解釈: 要差し替え

`JinsMemeBLESource` は以下までは入っています。

- Bluetooth 初期化
- 周辺機器スキャン
- `JINS MEME` 名を含むデバイス探索
- 接続
- Service / Characteristic 探索
- Notify 購読

ただし、公開状態では JINS MEME ES の GATT 仕様と通知ペイロード形式を確定できないため、`BLEConfiguration` の UUID と `parseFrame(_:)` の中身は、手元の社内資料や既存ブリッジに合わせて埋める前提です。

## ディレクトリ

- `project.yml`: XcodeGen 用設定
- `JinsMemeIOS/`: アプリ本体
- `JinsMemeMacReceiver/`: Mac 側の受信アプリ

## Mac での立ち上げ

1. `brew install xcodegen`
2. `cd ios/JinsMemeIOS`
3. `xcodegen generate`
4. 生成された `JinsMemeIOS.xcodeproj` を Xcode で開く
5. Signing の Team と Bundle Identifier を設定
6. `JinsMemeIOS` を実機 iPhone へインストール
7. `JinsMemeMacReceiver` を Mac で起動

## Mac 共有の使い方

1. Mac で `JinsMemeMacReceiver` を起動
2. iPhone で `JinsMemeIOS` を起動
3. 近くにある同一 Apple ID / 同一ローカル環境の端末同士で `MultipeerConnectivity` により接続
4. iPhone 側で受信した `SensorFrame` が Mac にもそのまま届く

Mac 側では最新フレーム、座標、簡易トレイルを確認できます。

## 差し替えポイント

### 1. Service UUID / Characteristic UUID

`Models.swift` の `BLEConfiguration` に設定します。

### 2. Notify データの解釈

`SensorSources.swift` の `parseFrame(_:)` を、実際のペイロードに合わせて更新します。

今は以下を仮対応しています。

- `SensorFrame` JSON
- `Float32 x 3` の Little Endian

## 共有

`MultipeerConnectivity` により、近くの iPhone / iPad / Mac に `SensorFrame` を共有できます。まずは Apple デバイス間共有を優先しています。

## 次にやると良いこと

1. 実機の Characteristic UUID を確定
2. 生データ形式を 1 サンプル取得
3. `parseFrame(_:)` を実データに合わせる
4. 必要なら CSV 保存や録画同期を追加
