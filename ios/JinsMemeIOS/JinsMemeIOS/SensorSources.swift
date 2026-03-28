import Combine
import CoreBluetooth
import Foundation

protocol SensorSource: AnyObject {
    var onFrame: ((SensorFrame) -> Void)? { get set }
    var onStatusChange: ((String) -> Void)? { get set }
    func start()
    func stop()
}

final class MockSensorSource: SensorSource {
    var onFrame: ((SensorFrame) -> Void)?
    var onStatusChange: ((String) -> Void)?

    private var timer: Timer?
    private var phase = 0.0

    func start() {
        onStatusChange?("Mock信号を生成中")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.06
            let horizontal = sin(self.phase) * 0.82
            let vertical = cos(self.phase * 0.7) * 0.74
            let blink = max(0.0, (sin(self.phase * 3.0) + 1) * 0.35 - 0.25)
            self.onFrame?(SensorFrame(horizontal: horizontal, vertical: vertical, blinkStrength: blink, source: "mock"))
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onStatusChange?("停止中")
    }
}

final class JinsMemeBLESource: NSObject, SensorSource {
    var onFrame: ((SensorFrame) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var onConnectionStateChange: ((BLEConnectionState) -> Void)?
    var onRawPacket: ((BLEPacketSnapshot) -> Void)?

    private let configuration = BLEConfiguration()
    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var hasStartedConnectionFlow = false
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var parser = MemeBinaryFrameParser()

    func start() {
        hasStartedConnectionFlow = true
        notifyConnectionState(.idle)

        if centralManager == nil {
            onStatusChange?("Bluetooth初期化中")
            centralManager = CBCentralManager(delegate: self, queue: nil)
            return
        }
        startScanIfPossible()
    }

    func stop() {
        hasStartedConnectionFlow = false
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        centralManager?.stopScan()
        if let connectedPeripheral {
            centralManager?.cancelPeripheralConnection(connectedPeripheral)
        }
        connectedPeripheral = nil
        onStatusChange?("停止中")
        notifyConnectionState(.idle)
    }

    private func handleNotification(_ data: Data) {
        onRawPacket?(
            BLEPacketSnapshot(
                receivedAt: .now,
                byteCount: data.count,
                hexPreview: data
                    .prefix(20)
                    .map { String(format: "%02X", $0) }
                    .joined(separator: " ")
            )
        )
        if let frame = parseFrame(data) {
            onFrame?(frame)
        } else {
            onStatusChange?("通知受信中: パーサ設定待ち")
        }
    }

    private func parseFrame(_ data: Data) -> SensorFrame? {
        if let decoded = try? JSONDecoder().decode(SensorFrame.self, from: data) {
            return decoded
        }

        if let g2Frame = parseG2BinaryFrame(data) {
            return g2Frame
        }

        return parseFloatFrame(data)
    }

    private func parseG2BinaryFrame(_ data: Data) -> SensorFrame? {
        parser.parse20BytePacket(data)
    }

    private func parseFloatFrame(_ data: Data) -> SensorFrame? {
        guard data.count >= 12 else { return nil }
        let horizontal = readFloat32LE(data, offset: 0)
        let vertical = readFloat32LE(data, offset: 4)
        let blink = readFloat32LE(data, offset: 8)
        guard horizontal.isFinite, vertical.isFinite, blink.isFinite else { return nil }
        guard abs(horizontal) <= 2.0, abs(vertical) <= 2.0, blink >= -0.1, blink <= 2.0 else { return nil }
        return SensorFrame(
            horizontal: horizontal.clamped(to: -1...1),
            vertical: vertical.clamped(to: -1...1),
            blinkStrength: blink.clamped(to: 0...1),
            source: "bluetooth/float"
        )
    }

    private func readFloat32LE(_ data: Data, offset: Int) -> Double {
        guard data.count >= offset + 4 else { return .nan }
        let value = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        return Double(Float(bitPattern: value))
    }

    private func startScanIfPossible() {
        guard hasStartedConnectionFlow else { return }
        guard let centralManager else { return }

        switch centralManager.state {
        case .poweredOn:
            break
        case .unauthorized:
            let failure = BLEConnectionFailure(
                title: "接続に失敗しました",
                reason: "Bluetooth権限が許可されていません。",
                recoverySuggestion: "設定アプリでこのアプリのBluetooth権限を許可してから再試行してください。"
            )
            onStatusChange?("Bluetooth権限がありません")
            notifyConnectionState(.failed(failure))
            return
        case .poweredOff:
            let failure = BLEConnectionFailure(
                title: "接続に失敗しました",
                reason: "iPhoneのBluetoothがオフです。",
                recoverySuggestion: "コントロールセンターまたは設定からBluetoothをオンにして再試行してください。"
            )
            onStatusChange?("Bluetoothがオフです")
            notifyConnectionState(.failed(failure))
            return
        default:
            let failure = BLEConnectionFailure(
                title: "接続に失敗しました",
                reason: "Bluetoothの状態が利用可能ではありません（state=\(centralManager.state.rawValue)）。",
                recoverySuggestion: "Bluetooth状態が安定してからもう一度接続してください。"
            )
            onStatusChange?("Bluetooth状態: \(centralManager.state.rawValue)")
            notifyConnectionState(.failed(failure))
            return
        }

        onStatusChange?("JINS MEME をスキャン中")
        notifyConnectionState(.scanning)

        connectionTimeoutWorkItem?.cancel()
        let timeoutTask = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.connectedPeripheral == nil else { return }
            self.centralManager?.stopScan()
            let failure = BLEConnectionFailure(
                title: "接続に失敗しました",
                reason: "JINS MEME が見つかりませんでした。",
                recoverySuggestion: "端末の電源ON・充電状態を確認し、iPhoneの近くで再試行してください。"
            )
            self.onStatusChange?("スキャンタイムアウト")
            self.notifyConnectionState(.failed(failure))
        }
        connectionTimeoutWorkItem = timeoutTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeoutTask)

        if let serviceUUID = configuration.serviceUUID.map({ CBUUID(nsuuid: $0) }) {
            centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
        } else {
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    private func notifyConnectionState(_ state: BLEConnectionState) {
        onConnectionStateChange?(state)
    }
}

private struct MemeBinaryFrameParser {
    private var baseline = [Double](repeating: 0, count: 4)
    private var baselineInitialized = false
    private var movementScale = 520.0
    private var blinkAverage = 150.0

    mutating func parse20BytePacket(_ data: Data) -> SensorFrame? {
        guard data.count >= 8, data.count % 2 == 0 else { return nil }

        let words: [Double] = stride(from: 0, to: data.count, by: 2).map { offset in
            let lo = UInt16(data[offset])
            let hi = UInt16(data[offset + 1]) << 8
            return Double(Int16(bitPattern: lo | hi))
        }
        guard words.count >= 4 else { return nil }

        let channels = selectChannels(from: words)
        if !baselineInitialized {
            baseline = channels
            baselineInitialized = true
        } else {
            for i in 0..<4 {
                baseline[i] = baseline[i] * 0.96 + channels[i] * 0.04
            }
        }

        let deltaLeft = channels[0] - baseline[0]
        let deltaRight = channels[1] - baseline[1]
        let deltaUp = channels[2] - baseline[2]
        let deltaDown = channels[3] - baseline[3]

        let horizontalRaw = deltaRight - deltaLeft
        let verticalRaw = deltaUp - deltaDown
        let movementMagnitude = max(abs(horizontalRaw), abs(verticalRaw))
        movementScale = max(220, movementScale * 0.985 + movementMagnitude * 0.015)

        let horizontal = tanh(horizontalRaw / (movementScale * 1.25)).clamped(to: -1...1)
        let vertical = tanh(verticalRaw / (movementScale * 1.25)).clamped(to: -1...1)

        let blinkRaw = abs(deltaLeft) + abs(deltaRight)
        blinkAverage = blinkAverage * 0.92 + blinkRaw * 0.08
        let blinkStrength = ((blinkRaw - blinkAverage * 0.9) / max(100, blinkAverage * 0.8)).clamped(to: 0...1)

        return SensorFrame(
            horizontal: horizontal,
            vertical: vertical,
            blinkStrength: blinkStrength,
            source: "bluetooth/g2-binary-\(data.count)b"
        )
    }

    private func selectChannels(from words: [Double]) -> [Double] {
        guard words.count > 4 else { return Array(words.prefix(4)) }
        let startCandidates = 0...(words.count - 4)
        let start = startCandidates.max { lhs, rhs in
            score(windowStart: lhs, words: words) < score(windowStart: rhs, words: words)
        } ?? 0
        return Array(words[start..<(start + 4)])
    }

    private func score(windowStart: Int, words: [Double]) -> Double {
        let window = Array(words[windowStart..<(windowStart + 4)])
        let meanAbs = window.map(abs).reduce(0, +) / 4.0
        if !baselineInitialized {
            return -meanAbs
        }
        let distance = zip(window, baseline).map { abs($0 - $1) }.reduce(0, +)
        return -(distance + meanAbs * 0.05)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension JinsMemeBLESource: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard hasStartedConnectionFlow else { return }
        switch central.state {
        case .poweredOn:
            startScanIfPossible()
        case .unauthorized:
            let failure = BLEConnectionFailure(
                title: "接続に失敗しました",
                reason: "Bluetooth権限が許可されていません。",
                recoverySuggestion: "設定アプリでこのアプリのBluetooth権限を許可してから再試行してください。"
            )
            onStatusChange?("Bluetooth権限がありません")
            notifyConnectionState(.failed(failure))
        case .poweredOff:
            let failure = BLEConnectionFailure(
                title: "接続に失敗しました",
                reason: "iPhoneのBluetoothがオフです。",
                recoverySuggestion: "コントロールセンターまたは設定からBluetoothをオンにして再試行してください。"
            )
            onStatusChange?("Bluetoothがオフです")
            notifyConnectionState(.failed(failure))
        default:
            let failure = BLEConnectionFailure(
                title: "接続に失敗しました",
                reason: "Bluetoothの状態が利用可能ではありません（state=\(central.state.rawValue)）。",
                recoverySuggestion: "Bluetooth状態が安定してからもう一度接続してください。"
            )
            onStatusChange?("Bluetooth状態: \(central.state.rawValue)")
            notifyConnectionState(.failed(failure))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let peripheralName = peripheral.name ?? ""
        let advertisedLocalName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let candidateName = advertisedLocalName.isEmpty ? peripheralName : advertisedLocalName
        let matched = configuration.peripheralNameHints.contains { hint in
            candidateName.localizedCaseInsensitiveContains(hint)
                || peripheralName.localizedCaseInsensitiveContains(hint)
                || advertisedLocalName.localizedCaseInsensitiveContains(hint)
        }
        guard matched else { return }

        let displayName = candidateName.isEmpty ? "JINS Device" : candidateName
        onStatusChange?("接続中: \(displayName)")
        notifyConnectionState(.connecting(deviceName: displayName))
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        connectedPeripheral = peripheral
        central.stopScan()
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onStatusChange?("接続済み: \(peripheral.name ?? "unknown")")
        notifyConnectionState(.connected(deviceName: peripheral.name ?? "JINS MEME"))
        if let serviceUUID = configuration.serviceUUID.map({ CBUUID(nsuuid: $0) }) {
            peripheral.discoverServices([serviceUUID])
        } else {
            peripheral.discoverServices(nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let failure = BLEConnectionFailure(
            title: "接続に失敗しました",
            reason: error?.localizedDescription ?? "BLE接続を確立できませんでした。",
            recoverySuggestion: "MEMEの電源・距離・ペアリング状態を確認して再試行してください。"
        )
        onStatusChange?("接続失敗")
        notifyConnectionState(.failed(failure))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedPeripheral = nil
        if hasStartedConnectionFlow {
            let failure = BLEConnectionFailure(
                title: "接続が切断されました",
                reason: error?.localizedDescription ?? "接続後に切断されました。",
                recoverySuggestion: "端末を近づけて、電池残量を確認し、再接続してください。"
            )
            onStatusChange?("切断されました")
            notifyConnectionState(.failed(failure))
        } else {
            onStatusChange?("停止中")
            notifyConnectionState(.idle)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            onStatusChange?("サービス検出失敗: \(error.localizedDescription)")
            return
        }
        peripheral.services?.forEach { service in
            if let uuid = configuration.notifyCharacteristicUUID.map({ CBUUID(nsuuid: $0) }) {
                peripheral.discoverCharacteristics([uuid], for: service)
            } else {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            onStatusChange?("Characteristic検出失敗: \(error.localizedDescription)")
            return
        }

        service.characteristics?.forEach { characteristic in
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
                onStatusChange?("通知待機中: \(characteristic.uuid.uuidString)")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            onStatusChange?("通知受信失敗: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        handleNotification(data)
    }
}
