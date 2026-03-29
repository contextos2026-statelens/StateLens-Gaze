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

final class LoggerBridgeSource: SensorSource {
    var onFrame: ((SensorFrame) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var onConnectionStateChange: ((BLEConnectionState) -> Void)?
    var onRawPacket: ((BLEPacketSnapshot) -> Void)?
    var onDiagnosticInfo: ((String) -> Void)?

    private var endpointURL: URL
    private var pollingTask: Task<Void, Never>?
    private var hasConnected = false
    private var consecutiveFailureCount = 0
    private var didEmitFailure = false
    private let failureThreshold = 4

    init(endpointURL: URL = URL(string: "http://192.168.4.33:8765/api/state")!) {
        self.endpointURL = endpointURL
    }

    func setEndpointURL(_ endpointURL: URL) {
        self.endpointURL = endpointURL
    }

    func start() {
        stop()
        hasConnected = false
        consecutiveFailureCount = 0
        didEmitFailure = false
        onStatusChange?("Logger連携サーバーへ接続中: \(endpointHostPortText)")
        onConnectionStateChange?(.scanning)
        onDiagnosticInfo?("Logger endpoint: \(endpointURL.absoluteString)")

        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        hasConnected = false
        consecutiveFailureCount = 0
        didEmitFailure = false
        onStatusChange?("停止中")
        onConnectionStateChange?(.idle)
    }

    private func pollOnce() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: endpointURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }

            guard
                let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let latest = payload["latest"] as? [String: Any],
                let raw = latest["raw"] as? [String: Any]
            else {
                consecutiveFailureCount = 0
                if !hasConnected {
                    onStatusChange?("Logger待機中（Loggerで記録を開始してください）")
                    onConnectionStateChange?(.connecting(deviceName: "Logger Bridge"))
                }
                return
            }

            guard
                let horizontal = raw["horizontal"] as? Double,
                let vertical = raw["vertical"] as? Double
            else {
                return
            }

            let blink = raw["blinkStrength"] as? Double ?? 0
            let timestamp = (latest["timestamp"] as? Double).map {
                Date(timeIntervalSince1970: $0)
            } ?? .now
            let source = (raw["source"] as? String) ?? "logger/currentData"

            consecutiveFailureCount = 0
            didEmitFailure = false
            if !hasConnected {
                hasConnected = true
                onConnectionStateChange?(.connected(deviceName: "Logger Bridge"))
            }

            onStatusChange?("Loggerデータ受信中")
            onFrame?(
                SensorFrame(
                    timestamp: timestamp,
                    horizontal: horizontal,
                    vertical: vertical,
                    blinkStrength: blink,
                    source: source
                )
            )

            let rawData = (try? JSONSerialization.data(withJSONObject: raw)) ?? Data()
            onRawPacket?(
                BLEPacketSnapshot(
                    receivedAt: .now,
                    byteCount: rawData.count,
                    hexPreview: rawData.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " ")
                )
            )
        } catch {
            consecutiveFailureCount += 1
            let failure = loggerFailure(from: error)
            onDiagnosticInfo?("Logger poll error: \(error.localizedDescription)")
            onStatusChange?(failure.reason)
            if consecutiveFailureCount >= failureThreshold, !didEmitFailure {
                didEmitFailure = true
                onConnectionStateChange?(.failed(failure))
            }
        }
    }

    private var endpointHostPortText: String {
        "\(endpointURL.host ?? "Loggerサーバー"):\(endpointURL.port ?? 80)"
    }

    private func loggerFailure(from error: Error) -> BLEConnectionFailure {
        let hostPort = endpointHostPortText
        guard let urlError = error as? URLError else {
            return BLEConnectionFailure(
                title: "Logger連携に失敗しました",
                reason: "\(hostPort) に接続できません。",
                recoverySuggestion: "iPhoneとMacを同じWi-Fiに接続し、Mac側で受信サーバーを再起動してください。"
            )
        }

        switch urlError.code {
        case .notConnectedToInternet:
            return BLEConnectionFailure(
                title: "Logger連携に失敗しました",
                reason: "ローカルネットワークへ到達できません（\(hostPort)）。",
                recoverySuggestion: "iPhoneとMacを同じWi-Fiに接続し、設定 > StateLens : Gaze > ローカルネットワーク をONにして再試行してください。"
            )
        case .cannotFindHost, .dnsLookupFailed:
            return BLEConnectionFailure(
                title: "Logger連携に失敗しました",
                reason: "ホスト名が解決できません（\(hostPort)）。",
                recoverySuggestion: "Hostの入力値を見直し、IPアドレスを指定してください（例: 192.168.x.x）。"
            )
        case .cannotConnectToHost, .timedOut, .networkConnectionLost:
            return BLEConnectionFailure(
                title: "Logger連携に失敗しました",
                reason: "\(hostPort) が応答しません。",
                recoverySuggestion: "Mac側で `python3 app.py --host 0.0.0.0 --port 8765` と `node tools/jins_logger_ws_receiver.js` を起動して再試行してください。"
            )
        default:
            return BLEConnectionFailure(
                title: "Logger連携に失敗しました",
                reason: "\(hostPort) への接続でエラーが発生しました（\(urlError.code.rawValue)）。",
                recoverySuggestion: "ネットワーク状態と受信サーバー起動状態を確認して再試行してください。"
            )
        }
    }
}

final class JinsMemeBLESource: NSObject, SensorSource {
    var onFrame: ((SensorFrame) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var onConnectionStateChange: ((BLEConnectionState) -> Void)?
    var onRawPacket: ((BLEPacketSnapshot) -> Void)?
    var onDiagnosticInfo: ((String) -> Void)?

    private let configuration = BLEConfiguration()
    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var hasStartedConnectionFlow = false
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var parser = MemeBinaryFrameParser()
    private var selectedNotifyCharacteristicID: CBUUID?
    private var selectedServiceID: CBUUID?
    private var characteristicObservations: [CBUUID: CharacteristicObservation] = [:]
    private var usingSavedUUIDs = false
    private var notificationCountSinceConnect = 0
    private var savedUUIDValidationWorkItem: DispatchWorkItem?
    private var didProbeWritableCharacteristics = false
    private var probedWriteCharacteristicIDs: Set<CBUUID> = []
    private var discoveredServiceIDs: [CBUUID] = []
    private var discoveredCharacteristicLines: [String] = []
    private var lastDiagnosticEmitAt: Date = .distantPast
    private var streamWriteCharacteristic: CBCharacteristic?
    private var writeCharacteristicCandidates: [CBCharacteristic] = []
    private var currentWriteCharacteristicIndex = 0
    private var lastNotificationAt: Date = .distantPast
    private var streamRestartWorkItem: DispatchWorkItem?
    private var streamKeepAliveWorkItem: DispatchWorkItem?
    private var inSessionCommandProbeWorkItem: DispatchWorkItem?
    private var streamRestartAttempts = 0
    private var inSessionCommandProbeAttempts = 0
    private var notifySubscriptionReady = false
    private var didSendInitialStartCommand = false
    private var connectedAt: Date?
    private var diagnosticEvents: [String] = []

    private static let diagnosticTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func start() {
        hasStartedConnectionFlow = true
        selectedNotifyCharacteristicID = nil
        selectedServiceID = nil
        characteristicObservations = [:]
        usingSavedUUIDs = configuration.isUsingPersistedUUIDFallback
        notificationCountSinceConnect = 0
        didProbeWritableCharacteristics = false
        probedWriteCharacteristicIDs = []
        discoveredServiceIDs = []
        discoveredCharacteristicLines = []
        lastDiagnosticEmitAt = .distantPast
        streamWriteCharacteristic = nil
        writeCharacteristicCandidates = []
        currentWriteCharacteristicIndex = 0
        lastNotificationAt = .distantPast
        streamRestartWorkItem?.cancel()
        streamRestartWorkItem = nil
        streamKeepAliveWorkItem?.cancel()
        streamKeepAliveWorkItem = nil
        inSessionCommandProbeWorkItem?.cancel()
        inSessionCommandProbeWorkItem = nil
        streamRestartAttempts = 0
        inSessionCommandProbeAttempts = 0
        notifySubscriptionReady = false
        didSendInitialStartCommand = false
        connectedAt = nil
        diagnosticEvents = []
        savedUUIDValidationWorkItem?.cancel()
        savedUUIDValidationWorkItem = nil
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
        characteristicObservations = [:]
        savedUUIDValidationWorkItem?.cancel()
        savedUUIDValidationWorkItem = nil
        didProbeWritableCharacteristics = false
        probedWriteCharacteristicIDs = []
        discoveredServiceIDs = []
        discoveredCharacteristicLines = []
        streamWriteCharacteristic = nil
        writeCharacteristicCandidates = []
        currentWriteCharacteristicIndex = 0
        lastNotificationAt = .distantPast
        streamRestartWorkItem?.cancel()
        streamRestartWorkItem = nil
        streamKeepAliveWorkItem?.cancel()
        streamKeepAliveWorkItem = nil
        inSessionCommandProbeWorkItem?.cancel()
        inSessionCommandProbeWorkItem = nil
        streamRestartAttempts = 0
        inSessionCommandProbeAttempts = 0
        notifySubscriptionReady = false
        didSendInitialStartCommand = false
        connectedAt = nil
        diagnosticEvents = []
        centralManager?.stopScan()
        if let connectedPeripheral {
            centralManager?.cancelPeripheralConnection(connectedPeripheral)
        }
        connectedPeripheral = nil
        onStatusChange?("停止中")
        notifyConnectionState(.idle)
    }

    private func handleNotification(_ data: Data) -> Bool {
        notificationCountSinceConnect += 1
        if notificationCountSinceConnect == 1 {
            inSessionCommandProbeWorkItem?.cancel()
            inSessionCommandProbeWorkItem = nil
            addDiagnosticEvent("最初の通知データを受信")
        }
        lastNotificationAt = .now
        streamRestartAttempts = 0
        scheduleStreamRestartWatchdog()
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
            return true
        } else {
            onStatusChange?("通知受信中: パーサ設定待ち")
            return false
        }
    }

    private func recordObservation(
        for characteristic: CBCharacteristic,
        byteCount: Int,
        parsed: Bool
    ) {
        var observation = characteristicObservations[characteristic.uuid] ?? CharacteristicObservation()
        observation.totalCount += 1
        if parsed {
            observation.parsedCount += 1
        }
        observation.packetLengthHistogram[byteCount, default: 0] += 1
        let now = Date()
        if observation.firstSeenAt == nil {
            observation.firstSeenAt = now
        }
        observation.lastSeenAt = now
        characteristicObservations[characteristic.uuid] = observation
    }

    private func shouldPromote(_ observation: CharacteristicObservation) -> Bool {
        guard observation.parsedCount >= 24 else { return false }
        guard let firstSeenAt = observation.firstSeenAt, let lastSeenAt = observation.lastSeenAt else { return false }
        let duration = max(0.1, lastSeenAt.timeIntervalSince(firstSeenAt))
        let parsedRate = Double(observation.parsedCount) / duration
        let dominantLengthCount = observation.packetLengthHistogram.values.max() ?? 0
        let dominantRatio = Double(dominantLengthCount) / Double(max(observation.totalCount, 1))
        return parsedRate >= 5.0 && dominantRatio >= 0.7
    }

    private func sendStreamStartCommand(
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        reason: String,
        announceStatus: Bool = true
    ) {
        let props = characteristic.properties
        let supportsWriteWithoutResponse = props.contains(.writeWithoutResponse)
        let supportsWriteWithResponse = props.contains(.write)
        guard supportsWriteWithoutResponse || supportsWriteWithResponse else { return }

        let writeType: CBCharacteristicWriteType = supportsWriteWithoutResponse ? .withoutResponse : .withResponse
        let command = configuration.selectedStreamStartCommand
        peripheral.writeValue(command, for: characteristic, type: writeType)
        let hex = command.map { String(format: "%02X", $0) }.joined(separator: " ")
        if announceStatus {
            onStatusChange?("\(reason): \(characteristic.uuid.uuidString) cmd[\(hex)]")
        }
        addDiagnosticEvent("CMD[\(hex)] -> \(characteristic.uuid.uuidString)")
    }

    private func sendInitialStartCommandIfReady(peripheral: CBPeripheral) {
        guard notifySubscriptionReady else { return }
        guard !didSendInitialStartCommand else { return }
        guard let writeCharacteristic = streamWriteCharacteristic else { return }
        didSendInitialStartCommand = true
        sendStreamStartCommand(
            peripheral: peripheral,
            characteristic: writeCharacteristic,
            reason: "通知有効化完了。ストリーム開始コマンドを送信"
        )
        scheduleInSessionCommandProbeIfNoData()
        schedulePeriodicStreamKeepAlive()
    }

    private func switchToNextWriteCharacteristicIfAvailable() -> Bool {
        guard currentWriteCharacteristicIndex + 1 < writeCharacteristicCandidates.count else { return false }
        currentWriteCharacteristicIndex += 1
        streamWriteCharacteristic = writeCharacteristicCandidates[currentWriteCharacteristicIndex]
        inSessionCommandProbeAttempts = 0
        if let streamWriteCharacteristic {
            addDiagnosticEvent("同一接続で書込Characteristic切替: \(streamWriteCharacteristic.uuid.uuidString)")
        }
        return streamWriteCharacteristic != nil
    }

    private func scheduleInSessionCommandProbeIfNoData() {
        inSessionCommandProbeWorkItem?.cancel()
        guard configuration.enableInSessionStreamCommandProbe else { return }
        guard hasStartedConnectionFlow else { return }
        guard let peripheral = connectedPeripheral else { return }
        guard streamWriteCharacteristic != nil else { return }

        let maxAttempts = max(0, configuration.streamStartCommandCandidates.count - 1)
        guard inSessionCommandProbeAttempts < maxAttempts || currentWriteCharacteristicIndex + 1 < writeCharacteristicCandidates.count else { return }

        let interval = configuration.inSessionStreamCommandProbeInterval
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard self.hasStartedConnectionFlow else { return }
            guard self.connectedPeripheral === peripheral else { return }
            guard self.notifySubscriptionReady, self.didSendInitialStartCommand else { return }
            guard self.notificationCountSinceConnect == 0 else { return }
            if self.inSessionCommandProbeAttempts >= maxAttempts {
                guard self.switchToNextWriteCharacteristicIfAvailable() else { return }
            }
            guard let writeCharacteristic = self.streamWriteCharacteristic else { return }

            let previous = self.configuration.selectedStreamStartCommand.map { String(format: "%02X", $0) }.joined(separator: " ")
            self.configuration.advanceStreamStartCommandCandidate()
            let next = self.configuration.selectedStreamStartCommand.map { String(format: "%02X", $0) }.joined(separator: " ")
            self.inSessionCommandProbeAttempts += 1
            self.addDiagnosticEvent("同一接続で開始コマンド切替: [\(previous)] -> [\(next)]")
            self.sendStreamStartCommand(
                peripheral: peripheral,
                characteristic: writeCharacteristic,
                reason: "データ未受信のため開始コマンド切替",
                announceStatus: false
            )
            self.scheduleInSessionCommandProbeIfNoData()
        }
        inSessionCommandProbeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func schedulePeriodicStreamKeepAlive() {
        streamKeepAliveWorkItem?.cancel()
        guard configuration.enablePeriodicStreamKeepAlive else { return }
        guard let peripheral = connectedPeripheral else { return }
        guard streamWriteCharacteristic != nil else { return }

        let interval = configuration.streamKeepAliveInterval
        let silenceThreshold = configuration.streamKeepAliveSilenceThreshold
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard self.hasStartedConnectionFlow else { return }
            guard self.connectedPeripheral === peripheral else { return }
            guard self.notifySubscriptionReady, self.didSendInitialStartCommand else { return }
            guard self.notificationCountSinceConnect > 0 else {
                self.schedulePeriodicStreamKeepAlive()
                return
            }
            guard let writeCharacteristic = self.streamWriteCharacteristic else { return }

            let silence = Date().timeIntervalSince(self.lastNotificationAt)
            if silence >= silenceThreshold {
                self.sendStreamStartCommand(
                    peripheral: peripheral,
                    characteristic: writeCharacteristic,
                    reason: "ストリーム維持コマンド送信",
                    announceStatus: false
                )
            }
            self.schedulePeriodicStreamKeepAlive()
        }
        streamKeepAliveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func scheduleStreamRestartWatchdog() {
        streamRestartWorkItem?.cancel()
        guard configuration.enableStreamSilenceRestart else { return }
        guard hasStartedConnectionFlow else { return }
        guard let peripheral = connectedPeripheral, let writeCharacteristic = streamWriteCharacteristic else { return }

        let threshold = configuration.streamSilenceRestartThreshold
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard self.hasStartedConnectionFlow else { return }
            guard self.connectedPeripheral === peripheral else { return }
            let silence = Date().timeIntervalSince(self.lastNotificationAt)
            guard silence >= threshold else {
                self.scheduleStreamRestartWatchdog()
                return
            }
            guard self.streamRestartAttempts < self.configuration.maxStreamRestartAttemptsPerSilence else { return }
            self.streamRestartAttempts += 1
            self.sendStreamStartCommand(
                peripheral: peripheral,
                characteristic: writeCharacteristic,
                reason: "通知停止を検知したためストリーム再開コマンド送信"
            )
        }
        streamRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + threshold, execute: workItem)
    }

    private func probeStreamStartIfNeeded(
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        guard configuration.enableStreamStartCommandProbe else { return }
        guard !probedWriteCharacteristicIDs.contains(characteristic.uuid) else { return }

        let props = characteristic.properties
        let supportsWriteWithoutResponse = props.contains(.writeWithoutResponse)
        let supportsWriteWithResponse = props.contains(.write)
        guard supportsWriteWithoutResponse || supportsWriteWithResponse else { return }

        probedWriteCharacteristicIDs.insert(characteristic.uuid)
        writeCharacteristicCandidates.append(characteristic)
        if let targetWrite = configuration.writeCharacteristicUUID.map({ CBUUID(nsuuid: $0) }),
           characteristic.uuid == targetWrite {
            currentWriteCharacteristicIndex = max(0, writeCharacteristicCandidates.count - 1)
            streamWriteCharacteristic = characteristic
        } else if streamWriteCharacteristic == nil {
            currentWriteCharacteristicIndex = max(0, writeCharacteristicCandidates.count - 1)
            streamWriteCharacteristic = characteristic
        }
        addDiagnosticEvent("WRITE候補追加: \(characteristic.uuid.uuidString) [\(characteristicPropertiesText(props))]")
        sendInitialStartCommandIfReady(peripheral: peripheral)
        scheduleStreamRestartWatchdog()
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

        if let serviceUUID = configuration.resolvedServiceUUID.map({ CBUUID(nsuuid: $0) }) {
            centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
        } else {
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    private func notifyConnectionState(_ state: BLEConnectionState) {
        onConnectionStateChange?(state)
    }

    private func addDiagnosticEvent(_ text: String) {
        let timestamp = Self.diagnosticTimeFormatter.string(from: Date())
        diagnosticEvents.append("\(timestamp) \(text)")
        if diagnosticEvents.count > 8 {
            diagnosticEvents.removeFirst(diagnosticEvents.count - 8)
        }
        emitDiagnosticSummaryIfNeeded(force: true)
    }

    private func emitDiagnosticSummaryIfNeeded(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastDiagnosticEmitAt) < 4.0 {
            return
        }
        lastDiagnosticEmitAt = now

        let observationLines = characteristicObservations
            .map { uuid, observation -> String in
                let duration = max(0.1, (observation.lastSeenAt ?? now).timeIntervalSince(observation.firstSeenAt ?? now))
                let totalRate = Double(observation.totalCount) / duration
                let parsedRate = Double(observation.parsedCount) / duration
                let dominantLen = observation.packetLengthHistogram.max(by: { $0.value < $1.value })?.key ?? 0
                return "\(uuid.uuidString) count=\(observation.totalCount) total=\(String(format: "%.1f", totalRate))Hz parsed=\(String(format: "%.1f", parsedRate))Hz len=\(dominantLen)"
            }
            .sorted()

        let serviceText = discoveredServiceIDs.map(\.uuidString).joined(separator: ", ")
        let charText = discoveredCharacteristicLines.joined(separator: " | ")
        let topObservationText = observationLines.prefix(3).joined(separator: " | ")
        let eventText = diagnosticEvents.suffix(3).joined(separator: " | ")
        onDiagnosticInfo?("S[\(serviceText)] C[\(charText)] OBS[\(topObservationText)] EVT[\(eventText)]")
    }

    private func characteristicPropertiesText(_ properties: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if properties.contains(.read) { parts.append("R") }
        if properties.contains(.write) { parts.append("W") }
        if properties.contains(.writeWithoutResponse) { parts.append("WNR") }
        if properties.contains(.notify) { parts.append("N") }
        if properties.contains(.indicate) { parts.append("I") }
        if properties.contains(.broadcast) { parts.append("B") }
        return parts.joined(separator: "/")
    }

    private func disconnectReasonText(_ error: Error?) -> String {
        guard let error else { return "接続後に切断されました（error=nil）" }
        if let cbError = error as? CBError {
            return "接続後に切断されました（CBError: \(cbError.code.rawValue) \(cbError.code)）"
        }
        let nsError = error as NSError
        return "接続後に切断されました（\(nsError.domain):\(nsError.code) \(nsError.localizedDescription)）"
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

private struct CharacteristicObservation {
    var totalCount: Int = 0
    var parsedCount: Int = 0
    var packetLengthHistogram: [Int: Int] = [:]
    var firstSeenAt: Date?
    var lastSeenAt: Date?
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
        connectedAt = .now
        lastNotificationAt = .now
        inSessionCommandProbeAttempts = 0
        notifySubscriptionReady = false
        didSendInitialStartCommand = false
        scheduleStreamRestartWatchdog()
        if usingSavedUUIDs {
            let validation = DispatchWorkItem { [weak self, weak peripheral] in
                guard let self, let peripheral else { return }
                guard self.connectedPeripheral === peripheral else { return }
                guard self.usingSavedUUIDs else { return }
                guard self.notificationCountSinceConnect < 20 else { return }
                self.configuration.clearResolved()
                self.onStatusChange?("保存UUIDが低頻度のため破棄しました（現在の接続は維持）")
            }
            savedUUIDValidationWorkItem = validation
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: validation)
        }
        if let serviceUUID = configuration.resolvedServiceUUID.map({ CBUUID(nsuuid: $0) }) {
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
        savedUUIDValidationWorkItem?.cancel()
        savedUUIDValidationWorkItem = nil
        streamRestartWorkItem?.cancel()
        streamRestartWorkItem = nil
        streamKeepAliveWorkItem?.cancel()
        streamKeepAliveWorkItem = nil
        inSessionCommandProbeWorkItem?.cancel()
        inSessionCommandProbeWorkItem = nil
        streamWriteCharacteristic = nil
        writeCharacteristicCandidates = []
        currentWriteCharacteristicIndex = 0
        streamRestartAttempts = 0
        inSessionCommandProbeAttempts = 0
        notifySubscriptionReady = false
        didSendInitialStartCommand = false
        connectedPeripheral = nil
        let receivedCount = characteristicObservations.values.map(\.totalCount).reduce(0, +)
        let connectionDuration = Date().timeIntervalSince(connectedAt ?? Date())
        let shouldAdvanceCandidate =
            receivedCount == 0
            || (connectionDuration <= configuration.streamCommandProbeDisconnectThreshold
                && receivedCount < 2)
        if shouldAdvanceCandidate {
            let previous = configuration.selectedStreamStartCommand.map { String(format: "%02X", $0) }.joined(separator: " ")
            configuration.advanceStreamStartCommandCandidate()
            let next = configuration.selectedStreamStartCommand.map { String(format: "%02X", $0) }.joined(separator: " ")
            let message = "早期切断のため開始コマンド候補を切替: [\(previous)] -> [\(next)]"
            onStatusChange?(message)
            addDiagnosticEvent(message)
        }
        connectedAt = nil
        if hasStartedConnectionFlow {
            let failure = BLEConnectionFailure(
                title: "接続が切断されました",
                reason: disconnectReasonText(error),
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
        discoveredServiceIDs = peripheral.services?.map(\.uuid) ?? []
        emitDiagnosticSummaryIfNeeded(force: true)

        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            onStatusChange?("Characteristic検出失敗: \(error.localizedDescription)")
            return
        }

        service.characteristics?.forEach { characteristic in
            let props = characteristicPropertiesText(characteristic.properties)
            let line = "\(service.uuid.uuidString):\(characteristic.uuid.uuidString)[\(props)]"
            if !discoveredCharacteristicLines.contains(line) {
                discoveredCharacteristicLines.append(line)
            }
        }
        emitDiagnosticSummaryIfNeeded(force: true)

        service.characteristics?.forEach { characteristic in
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
                onStatusChange?("通知待機中: \(characteristic.uuid.uuidString)")
            }
            probeStreamStartIfNeeded(peripheral: peripheral, characteristic: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            onStatusChange?("通知受信失敗: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        if let selectedNotifyCharacteristicID, characteristic.uuid != selectedNotifyCharacteristicID {
            return
        }
        let parsed = handleNotification(data)
        recordObservation(for: characteristic, byteCount: data.count, parsed: parsed)
        emitDiagnosticSummaryIfNeeded()

        guard parsed, selectedNotifyCharacteristicID == nil else { return }
        guard let observation = characteristicObservations[characteristic.uuid], shouldPromote(observation) else { return }
        selectedNotifyCharacteristicID = characteristic.uuid
        selectedServiceID = characteristic.service?.uuid
        configuration.saveResolved(serviceUUID: selectedServiceID, notifyUUID: selectedNotifyCharacteristicID)
        onStatusChange?("通知UUIDを固定: \(characteristic.uuid.uuidString)")

        guard let connectedPeripheral else { return }
        connectedPeripheral.services?.forEach { service in
            service.characteristics?.forEach { candidate in
                let isSelected = candidate.uuid == characteristic.uuid
                if (candidate.properties.contains(.notify) || candidate.properties.contains(.indicate)) && !isSelected {
                    connectedPeripheral.setNotifyValue(false, for: candidate)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            onStatusChange?("通知設定失敗: \(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying else { return }
        notifySubscriptionReady = true
        onStatusChange?("通知有効化完了: \(characteristic.uuid.uuidString)")
        sendInitialStartCommandIfReady(peripheral: peripheral)
    }
}
