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
    private var probedWriteCharacteristicIDs: Set<CBUUID> = []
    private var discoveredServiceIDs: [CBUUID] = []
    private var discoveredCharacteristicLines: [String] = []
    private var lastDiagnosticEmitAt: Date = .distantPast
    private var streamWriteCharacteristic: CBCharacteristic?
    private var streamNotifyCharacteristic: CBCharacteristic?
    private var writeCharacteristicCandidates: [CBCharacteristic] = []
    private var currentWriteCharacteristicIndex = 0
    private var lastNotificationAt: Date = .distantPast
    private var startCommandProbeWorkItem: DispatchWorkItem?
    private var startCommandRetryWorkItem: DispatchWorkItem?
    private var startCommandProbeOrder: [Int] = []
    private var startCommandProbeCursor = 0
    private var activeStartCommandIndex: Int?
    private var currentProbeWriteType: CBCharacteristicWriteType?
    private var triedAlternateWriteTypeForCurrentCommand = false
    private var probeWindowPackets: [ProbePacketSample] = []
    private var isStreamingEstablished = false
    private var streamEstablishedAt: Date?
    private var packetsSinceStreamEstablished = 0
    private var streamMaintainWorkItem: DispatchWorkItem?
    private var streamSilenceWorkItem: DispatchWorkItem?
    private var streamReadPollingWorkItem: DispatchWorkItem?
    private var lastStreamCommandSentAt: Date = .distantPast
    private var lastFallbackAttemptAt: Date = .distantPast
    private var didExhaustStartCommandsInSession = false
    private var lastProbeMetrics: StartProbeMetrics?
    private var notifySubscriptionReady = false
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
        probedWriteCharacteristicIDs = []
        discoveredServiceIDs = []
        discoveredCharacteristicLines = []
        lastDiagnosticEmitAt = .distantPast
        streamWriteCharacteristic = nil
        streamNotifyCharacteristic = nil
        writeCharacteristicCandidates = []
        currentWriteCharacteristicIndex = 0
        lastNotificationAt = .distantPast
        startCommandProbeWorkItem?.cancel()
        startCommandProbeWorkItem = nil
        startCommandRetryWorkItem?.cancel()
        startCommandRetryWorkItem = nil
        startCommandProbeOrder = []
        startCommandProbeCursor = 0
        activeStartCommandIndex = nil
        currentProbeWriteType = nil
        triedAlternateWriteTypeForCurrentCommand = false
        probeWindowPackets = []
        isStreamingEstablished = false
        streamEstablishedAt = nil
        packetsSinceStreamEstablished = 0
        streamMaintainWorkItem?.cancel()
        streamMaintainWorkItem = nil
        streamSilenceWorkItem?.cancel()
        streamSilenceWorkItem = nil
        streamReadPollingWorkItem?.cancel()
        streamReadPollingWorkItem = nil
        lastStreamCommandSentAt = .distantPast
        lastFallbackAttemptAt = .distantPast
        didExhaustStartCommandsInSession = false
        lastProbeMetrics = nil
        notifySubscriptionReady = false
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
        probedWriteCharacteristicIDs = []
        discoveredServiceIDs = []
        discoveredCharacteristicLines = []
        streamWriteCharacteristic = nil
        streamNotifyCharacteristic = nil
        writeCharacteristicCandidates = []
        currentWriteCharacteristicIndex = 0
        lastNotificationAt = .distantPast
        startCommandProbeWorkItem?.cancel()
        startCommandProbeWorkItem = nil
        startCommandRetryWorkItem?.cancel()
        startCommandRetryWorkItem = nil
        startCommandProbeOrder = []
        startCommandProbeCursor = 0
        activeStartCommandIndex = nil
        currentProbeWriteType = nil
        triedAlternateWriteTypeForCurrentCommand = false
        probeWindowPackets = []
        isStreamingEstablished = false
        streamEstablishedAt = nil
        packetsSinceStreamEstablished = 0
        streamMaintainWorkItem?.cancel()
        streamMaintainWorkItem = nil
        streamSilenceWorkItem?.cancel()
        streamSilenceWorkItem = nil
        streamReadPollingWorkItem?.cancel()
        streamReadPollingWorkItem = nil
        lastStreamCommandSentAt = .distantPast
        lastFallbackAttemptAt = .distantPast
        didExhaustStartCommandsInSession = false
        lastProbeMetrics = nil
        notifySubscriptionReady = false
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
            addDiagnosticEvent("最初の通知データを受信")
        }
        lastNotificationAt = .now
        recordProbePacket(data)
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
            if !isStreamingEstablished {
                markStreamEstablished()
            } else {
                packetsSinceStreamEstablished += 1
            }
            return true
        } else {
            onStatusChange?("通知受信中: パーサ設定待ち")
            return false
        }
    }

    private func markStreamEstablished() {
        isStreamingEstablished = true
        streamEstablishedAt = .now
        packetsSinceStreamEstablished = 1
        didExhaustStartCommandsInSession = false
        lastProbeMetrics = nil
        startCommandProbeWorkItem?.cancel()
        startCommandProbeWorkItem = nil
        startCommandRetryWorkItem?.cancel()
        startCommandRetryWorkItem = nil
        if let activeStartCommandIndex {
            configuration.savePreferredStreamStartCommandIndex(activeStartCommandIndex)
            let command = configuration.streamStartCommandCandidates[activeStartCommandIndex]
            let hex = command.map { String(format: "%02X", $0) }.joined(separator: " ")
            onStatusChange?("ストリーム開始を確認: cmd[\(hex)]")
            addDiagnosticEvent("開始コマンド確定: [\(hex)]")
        } else {
            onStatusChange?("ストリーム開始を確認")
        }
        guard let connectedPeripheral else { return }
        scheduleStreamMaintainPulse(peripheral: connectedPeripheral)
        scheduleStreamSilenceWatchdog(peripheral: connectedPeripheral)
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
        commandIndex: Int,
        preferredWriteType: CBCharacteristicWriteType? = nil,
        reason: String,
        announceStatus: Bool = true
    ) -> Bool {
        let props = characteristic.properties
        let supportsWriteWithoutResponse = props.contains(.writeWithoutResponse)
        let supportsWriteWithResponse = props.contains(.write)
        guard supportsWriteWithoutResponse || supportsWriteWithResponse else { return false }
        guard commandIndex >= 0 && commandIndex < configuration.streamStartCommandCandidates.count else { return false }

        let writeType: CBCharacteristicWriteType
        if let preferredWriteType {
            switch preferredWriteType {
            case .withResponse:
                guard supportsWriteWithResponse else { return false }
                writeType = .withResponse
            case .withoutResponse:
                guard supportsWriteWithoutResponse else { return false }
                writeType = .withoutResponse
            @unknown default:
                guard supportsWriteWithResponse else { return false }
                writeType = .withResponse
            }
        } else {
            writeType = supportsWriteWithResponse ? .withResponse : .withoutResponse
        }
        let command = configuration.streamStartCommandCandidates[commandIndex]
        peripheral.writeValue(command, for: characteristic, type: writeType)
        lastStreamCommandSentAt = .now
        let hex = command.map { String(format: "%02X", $0) }.joined(separator: " ")
        let modeText = writeType == .withResponse ? "REQ" : "CMD"
        if announceStatus {
            onStatusChange?("\(reason): \(characteristic.uuid.uuidString) cmd[\(hex)] \(modeText)")
        }
        addDiagnosticEvent("CMD[\(hex)] \(modeText) -> \(characteristic.uuid.uuidString)")
        return true
    }

    private func buildStartCommandProbeOrder() -> [Int] {
        var order: [Int] = []
        if let preferred = configuration.preferredStreamStartCommandIndex {
            order.append(preferred)
        }
        for index in configuration.streamStartCommandCandidates.indices where !order.contains(index) {
            order.append(index)
        }
        return order
    }

    private func preferredProbeWriteType(for characteristic: CBCharacteristic) -> CBCharacteristicWriteType? {
        let props = characteristic.properties
        let supportsWNR = props.contains(.writeWithoutResponse)
        let supportsWR = props.contains(.write)
        if supportsWNR { return .withoutResponse }
        if supportsWR { return .withResponse }
        return nil
    }

    private func alternateProbeWriteType(for characteristic: CBCharacteristic, current: CBCharacteristicWriteType) -> CBCharacteristicWriteType? {
        let props = characteristic.properties
        let supportsWNR = props.contains(.writeWithoutResponse)
        let supportsWR = props.contains(.write)
        if current == .withoutResponse, supportsWR { return .withResponse }
        if current == .withResponse, supportsWNR { return .withoutResponse }
        return nil
    }

    private func beginLoggerLikeStartSequenceIfReady(peripheral: CBPeripheral) {
        guard notifySubscriptionReady else { return }
        guard configuration.enableStreamStartCommandProbe else { return }
        guard streamWriteCharacteristic != nil else { return }
        guard !isStreamingEstablished else { return }

        if startCommandProbeOrder.isEmpty {
            startCommandProbeOrder = buildStartCommandProbeOrder()
            startCommandProbeCursor = 0
        }
        guard !startCommandProbeOrder.isEmpty else { return }

        startCommandProbeWorkItem?.cancel()
        let delay = configuration.streamStartProbeInitialDelay
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard self.hasStartedConnectionFlow else { return }
            guard self.connectedPeripheral === peripheral else { return }
            self.sendCurrentProbeCommand(
                peripheral: peripheral,
                reason: "通知有効化完了。Logger手順で開始コマンド送信"
            )
        }
        startCommandProbeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func sendCurrentProbeCommand(peripheral: CBPeripheral, reason: String) {
        guard notifySubscriptionReady else { return }
        guard let writeCharacteristic = streamWriteCharacteristic else { return }
        guard startCommandProbeCursor < startCommandProbeOrder.count else { return }

        let index = startCommandProbeOrder[startCommandProbeCursor]
        activeStartCommandIndex = index
        if currentProbeWriteType == nil {
            currentProbeWriteType = preferredProbeWriteType(for: writeCharacteristic)
        }
        triedAlternateWriteTypeForCurrentCommand = false
        probeWindowPackets = []
        let sent = sendStreamStartCommand(
            peripheral: peripheral,
            characteristic: writeCharacteristic,
            commandIndex: index,
            preferredWriteType: currentProbeWriteType,
            reason: reason
        )
        guard sent else { return }
        scheduleStartCommandProbeEvaluation(peripheral: peripheral)
    }

    private func scheduleStartCommandProbeEvaluation(peripheral: CBPeripheral) {
        startCommandProbeWorkItem?.cancel()
        let interval = configuration.streamStartProbeEvaluationInterval
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard self.hasStartedConnectionFlow else { return }
            guard self.connectedPeripheral === peripheral else { return }
            guard self.notifySubscriptionReady else { return }
            guard !self.isStreamingEstablished else { return }
            self.evaluateProbeAndAdvanceIfNeeded(peripheral: peripheral)
        }
        startCommandProbeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func evaluateProbeAndAdvanceIfNeeded(peripheral: CBPeripheral) {
        guard let activeIndex = activeStartCommandIndex else { return }
        let metrics = currentProbeMetrics()
        lastProbeMetrics = metrics
        let activeCommand = configuration.streamStartCommandCandidates[activeIndex]
        let activeHex = activeCommand.map { String(format: "%02X", $0) }.joined(separator: " ")
        addDiagnosticEvent(
            "候補評価 cmd[\(activeHex)] rate=\(String(format: "%.1f", metrics.packetRateHz))Hz unique=\(metrics.distinctCount)"
        )

        if hasStableStreamInProbeWindow() {
            onStatusChange?("通知ストリームを確認: cmd[\(activeHex)]")
            addDiagnosticEvent("通知ストリーム確立: [\(activeHex)]")
            markStreamEstablished()
            return
        }

        if !triedAlternateWriteTypeForCurrentCommand,
           let writeCharacteristic = streamWriteCharacteristic,
           let currentType = currentProbeWriteType,
           let alternateType = alternateProbeWriteType(for: writeCharacteristic, current: currentType) {
            triedAlternateWriteTypeForCurrentCommand = true
            currentProbeWriteType = alternateType
            probeWindowPackets = []
            let fromMode = currentType == .withResponse ? "REQ" : "CMD"
            let toMode = alternateType == .withResponse ? "REQ" : "CMD"
            let message = "同一cmdでWriteType切替: \(fromMode) -> \(toMode)"
            onStatusChange?(message)
            addDiagnosticEvent(message)
            let sent = sendStreamStartCommand(
                peripheral: peripheral,
                characteristic: writeCharacteristic,
                commandIndex: activeIndex,
                preferredWriteType: alternateType,
                reason: "同一cmdを別WriteTypeで再試行"
            )
            if sent {
                scheduleStartCommandProbeEvaluation(peripheral: peripheral)
                return
            }
        }

        if startCommandProbeCursor + 1 < startCommandProbeOrder.count {
            let previous = activeHex
            startCommandProbeCursor += 1
            let nextIndex = startCommandProbeOrder[startCommandProbeCursor]
            let next = configuration.streamStartCommandCandidates[nextIndex].map { String(format: "%02X", $0) }.joined(separator: " ")
            let message = "Logger手順で開始コマンド切替: [\(previous)] -> [\(next)]"
            onStatusChange?(message)
            addDiagnosticEvent(message)
            currentProbeWriteType = nil
            triedAlternateWriteTypeForCurrentCommand = false
            sendCurrentProbeCommand(peripheral: peripheral, reason: "データ未確定のため開始コマンド再試行")
            return
        }

        if switchToNextWriteCharacteristicIfAvailable() {
            startCommandProbeOrder = buildStartCommandProbeOrder()
            startCommandProbeCursor = 0
            activeStartCommandIndex = nil
            currentProbeWriteType = nil
            triedAlternateWriteTypeForCurrentCommand = false
            addDiagnosticEvent("書込Characteristic切替後に開始コマンドを再試行")
            sendCurrentProbeCommand(peripheral: peripheral, reason: "書込Characteristic切替後の再試行")
            return
        }

        didExhaustStartCommandsInSession = true
        onStatusChange?("開始コマンド候補を全試行済み。通知待機中")
        addDiagnosticEvent("開始コマンド候補を全試行済み")
        scheduleReadPollingFallback(peripheral: peripheral)
        scheduleStartCommandProbeRetry(peripheral: peripheral)
    }

    private func scheduleStartCommandProbeRetry(peripheral: CBPeripheral) {
        startCommandRetryWorkItem?.cancel()
        let interval = configuration.streamStartProbeRetryInterval
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard self.hasStartedConnectionFlow else { return }
            guard self.connectedPeripheral === peripheral else { return }
            guard self.notifySubscriptionReady else { return }
            guard !self.isStreamingEstablished else { return }
            self.startCommandProbeOrder = self.buildStartCommandProbeOrder()
            self.startCommandProbeCursor = 0
            self.activeStartCommandIndex = nil
            self.currentProbeWriteType = nil
            self.triedAlternateWriteTypeForCurrentCommand = false
            self.sendCurrentProbeCommand(peripheral: peripheral, reason: "開始コマンド再試行")
        }
        startCommandRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func scheduleStreamMaintainPulse(peripheral: CBPeripheral) {
        streamMaintainWorkItem?.cancel()
        let interval = configuration.streamMaintainPulseInterval
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard self.hasStartedConnectionFlow else { return }
            guard self.connectedPeripheral === peripheral else { return }
            guard self.notifySubscriptionReady, self.isStreamingEstablished else { return }
            // 常時再送は切断要因になりうるため、無通信兆候がある時のみ維持パルスを送る。
            let silence = Date().timeIntervalSince(self.lastNotificationAt)
            let maintainThreshold = self.configuration.streamSilenceThreshold * 0.75
            if silence >= maintainThreshold {
                self.sendActiveStreamCommand(
                    peripheral: peripheral,
                    reason: "ストリーム維持コマンド送信",
                    minInterval: self.configuration.streamMaintainPulseInterval * 0.6
                )
            }
            self.scheduleStreamMaintainPulse(peripheral: peripheral)
        }
        streamMaintainWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func scheduleStreamSilenceWatchdog(peripheral: CBPeripheral) {
        streamSilenceWorkItem?.cancel()
        let interval = configuration.streamSilenceCheckInterval
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard self.hasStartedConnectionFlow else { return }
            guard self.connectedPeripheral === peripheral else { return }
            guard self.notifySubscriptionReady, self.isStreamingEstablished else { return }

            let now = Date()
            let silence = now.timeIntervalSince(self.lastNotificationAt)
            if silence >= self.configuration.streamSilenceThreshold {
                let earlyDrop = self.isEarlyStreamDrop(now: now)
                let cooldown = now.timeIntervalSince(self.lastFallbackAttemptAt) >= self.configuration.streamFallbackCommandCooldown
                if cooldown {
                    self.lastFallbackAttemptAt = now
                    if earlyDrop {
                        self.switchToNextStartCommandAndSend(
                            peripheral: peripheral,
                            reasonPrefix: "早期途絶のため開始コマンド切替"
                        )
                    } else {
                        self.sendActiveStreamCommand(
                            peripheral: peripheral,
                            reason: "通知途絶のため再開コマンド送信",
                            minInterval: 0.5
                        )
                    }
                }
            }
            self.scheduleStreamSilenceWatchdog(peripheral: peripheral)
        }
        streamSilenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func scheduleReadPollingFallback(peripheral: CBPeripheral) {
        guard configuration.enableReadPollingFallback else { return }
        guard let notifyCharacteristic = streamNotifyCharacteristic else { return }
        guard notifyCharacteristic.properties.contains(.read) else { return }

        streamReadPollingWorkItem?.cancel()
        let interval = configuration.readPollingInterval
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard self.hasStartedConnectionFlow else { return }
            guard self.connectedPeripheral === peripheral else { return }
            guard self.notifySubscriptionReady else { return }
            guard let notifyCharacteristic = self.streamNotifyCharacteristic else { return }
            guard notifyCharacteristic.properties.contains(.read) else { return }

            // 通知が流れない個体向けフォールバック: Readを定期実行して最新値を取得する。
            let silence = Date().timeIntervalSince(self.lastNotificationAt)
            if !self.isStreamingEstablished || silence >= self.configuration.streamSilenceThreshold {
                peripheral.readValue(for: notifyCharacteristic)
            }
            self.scheduleReadPollingFallback(peripheral: peripheral)
        }
        streamReadPollingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func isEarlyStreamDrop(now: Date) -> Bool {
        guard let streamEstablishedAt else { return false }
        let elapsed = now.timeIntervalSince(streamEstablishedAt)
        return elapsed <= configuration.streamEarlyDropWindow
            && packetsSinceStreamEstablished <= configuration.streamEarlyDropPacketThreshold
    }

    private func sendActiveStreamCommand(
        peripheral: CBPeripheral,
        reason: String,
        minInterval: TimeInterval
    ) {
        guard let writeCharacteristic = streamWriteCharacteristic else { return }
        let resolvedIndex = activeStartCommandIndex
            ?? configuration.preferredStreamStartCommandIndex
            ?? startCommandProbeOrder.first
        guard let activeIndex = resolvedIndex else { return }
        if activeStartCommandIndex == nil {
            activeStartCommandIndex = activeIndex
        }
        let now = Date()
        guard now.timeIntervalSince(lastStreamCommandSentAt) >= minInterval else { return }
        let sent = sendStreamStartCommand(
            peripheral: peripheral,
            characteristic: writeCharacteristic,
            commandIndex: activeIndex,
            preferredWriteType: currentProbeWriteType ?? preferredProbeWriteType(for: writeCharacteristic),
            reason: reason,
            announceStatus: false
        )
        if sent {
            lastStreamCommandSentAt = now
        }
    }

    private func switchToNextStartCommandAndSend(peripheral: CBPeripheral, reasonPrefix: String) {
        guard let writeCharacteristic = streamWriteCharacteristic else { return }
        if startCommandProbeOrder.isEmpty {
            startCommandProbeOrder = buildStartCommandProbeOrder()
        }
        guard !startCommandProbeOrder.isEmpty else { return }

        let currentIndex = activeStartCommandIndex ?? startCommandProbeOrder[0]
        guard let currentPosition = startCommandProbeOrder.firstIndex(of: currentIndex) else { return }
        let nextPosition = (currentPosition + 1) % startCommandProbeOrder.count
        guard nextPosition != currentPosition else { return }
        let nextIndex = startCommandProbeOrder[nextPosition]
        guard nextIndex != currentIndex else { return }

        startCommandProbeCursor = nextPosition
        activeStartCommandIndex = nextIndex
        currentProbeWriteType = nil
        triedAlternateWriteTypeForCurrentCommand = false

        let previousHex = configuration.streamStartCommandCandidates[currentIndex].map { String(format: "%02X", $0) }.joined(separator: " ")
        let nextHex = configuration.streamStartCommandCandidates[nextIndex].map { String(format: "%02X", $0) }.joined(separator: " ")
        let message = "\(reasonPrefix): [\(previousHex)] -> [\(nextHex)]"
        onStatusChange?(message)
        addDiagnosticEvent(message)
        let sent = sendStreamStartCommand(
            peripheral: peripheral,
            characteristic: writeCharacteristic,
            commandIndex: nextIndex,
            preferredWriteType: preferredProbeWriteType(for: writeCharacteristic),
            reason: "再開コマンド送信",
            announceStatus: false
        )
        if sent {
            lastStreamCommandSentAt = .now
        }
    }

    private func recordProbePacket(_ data: Data) {
        guard activeStartCommandIndex != nil else { return }
        let digest = data.prefix(20).map { String(format: "%02X", $0) }.joined(separator: "")
        probeWindowPackets.append(ProbePacketSample(timestamp: .now, digest: digest))
        let cutoff = Date().addingTimeInterval(-configuration.streamStartProbeWindow)
        probeWindowPackets.removeAll { $0.timestamp < cutoff }
    }

    private func currentProbeMetrics() -> StartProbeMetrics {
        let now = Date()
        let cutoff = now.addingTimeInterval(-configuration.streamStartProbeWindow)
        let recent = probeWindowPackets.filter { $0.timestamp >= cutoff }
        let duration = max(0.1, configuration.streamStartProbeWindow)
        let rate = Double(recent.count) / duration
        let distinctCount = Set(recent.map(\.digest)).count
        return StartProbeMetrics(packetRateHz: rate, distinctCount: distinctCount)
    }

    private func hasStableStreamInProbeWindow() -> Bool {
        let metrics = currentProbeMetrics()
        return metrics.packetRateHz >= configuration.streamStartProbeMinimumPacketRateHz
            && metrics.distinctCount >= configuration.streamStartProbeMinimumDistinctPackets
    }

    private func switchToNextWriteCharacteristicIfAvailable() -> Bool {
        guard currentWriteCharacteristicIndex + 1 < writeCharacteristicCandidates.count else { return false }
        currentWriteCharacteristicIndex += 1
        streamWriteCharacteristic = writeCharacteristicCandidates[currentWriteCharacteristicIndex]
        currentProbeWriteType = nil
        if let streamWriteCharacteristic {
            addDiagnosticEvent("同一接続で書込Characteristic切替: \(streamWriteCharacteristic.uuid.uuidString)")
        }
        return streamWriteCharacteristic != nil
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
            currentProbeWriteType = nil
        } else if streamWriteCharacteristic == nil {
            currentWriteCharacteristicIndex = max(0, writeCharacteristicCandidates.count - 1)
            streamWriteCharacteristic = characteristic
            currentProbeWriteType = nil
        }
        addDiagnosticEvent("WRITE候補追加: \(characteristic.uuid.uuidString) [\(characteristicPropertiesText(props))]")
        beginLoggerLikeStartSequenceIfReady(peripheral: peripheral)
    }

    private func shouldEnableNotification(for characteristic: CBCharacteristic) -> Bool {
        guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
            return false
        }
        if let selectedNotifyCharacteristicID {
            return characteristic.uuid == selectedNotifyCharacteristicID
        }
        if let configuredNotifyUUID = configuration.resolvedNotifyCharacteristicUUID.map({ CBUUID(nsuuid: $0) }) {
            return characteristic.uuid == configuredNotifyUUID
        }
        if let configuredServiceUUID = configuration.resolvedServiceUUID.map({ CBUUID(nsuuid: $0) }),
           characteristic.service?.uuid != configuredServiceUUID {
            return false
        }
        return true
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

    private func disconnectReasonText(
        _ error: Error?,
        receivedCount: Int,
        didExhaustStartCommands: Bool,
        lastProbeMetrics: StartProbeMetrics?
    ) -> String {
        if error == nil, receivedCount == 0 {
            if didExhaustStartCommands {
                if let lastProbeMetrics {
                    return "通知データ0件のまま切断されました（error=nil）。開始コマンド候補を全試行しましたが通知開始を確認できませんでした（rate=\(String(format: "%.1f", lastProbeMetrics.packetRateHz))Hz unique=\(lastProbeMetrics.distinctCount)）。"
                }
                return "通知データ0件のまま切断されました（error=nil）。開始コマンド候補を全試行しましたが通知開始を確認できませんでした。"
            }
            return "通知データ0件のまま切断されました（error=nil）。デバイス側でストリーム開始前に接続が終了した可能性があります。"
        }
        guard let error else { return "接続後に切断されました（error=nil）" }
        if let cbError = error as? CBError {
            return "接続後に切断されました（CBError: \(cbError.code.rawValue) \(cbError.code)）"
        }
        let nsError = error as NSError
        return "接続後に切断されました（\(nsError.domain):\(nsError.code) \(nsError.localizedDescription)）"
    }

    private func disconnectRecoverySuggestion(receivedCount: Int, didExhaustStartCommands: Bool) -> String {
        if receivedCount == 0, didExhaustStartCommands {
            return "JINS MEME Loggerなど他アプリを完全終了し、MEMEを再起動して装着状態で再接続してください。改善しない場合はLogger連携モードを利用してください。"
        }
        if receivedCount == 0 {
            return "MEMEを再起動し、端末を近づけて再接続してください。必要に応じて再接続を数回試してください。"
        }
        return "端末を近づけて、電池残量を確認し、再接続してください。"
    }
}

private struct MemeBinaryFrameParser {
    private var baseline = [Double](repeating: 0, count: 4)
    private var noiseFloor = [Double](repeating: 160, count: 4)
    private var baselineInitialized = false
    private var stableFrameCount = 0
    private var smoothedHorizontal = 0.0
    private var smoothedVertical = 0.0
    private var smoothedBlink = 0.0

    mutating func parse20BytePacket(_ data: Data) -> SensorFrame? {
        guard data.count >= 8, data.count % 2 == 0 else { return nil }

        let words: [Double] = stride(from: 0, to: data.count, by: 2).map { offset in
            let lo = UInt16(data[offset])
            let hi = UInt16(data[offset + 1]) << 8
            return Double(Int16(bitPattern: lo | hi))
        }
        guard words.count >= 4 else { return nil }
        // JINS MEME G2系の20byte通知は先頭4wordがEOG由来チャネルとして最も安定しやすい。
        let channels = Array(words.prefix(4))
        if !baselineInitialized {
            baseline = channels
            baselineInitialized = true
        }

        var deltas = [Double](repeating: 0, count: 4)
        for i in 0..<4 {
            let delta = channels[i] - baseline[i]
            deltas[i] = delta

            // 平常時のみベースラインに追従させ、眼球運動/瞬目イベント時は追従を抑制。
            let gate = max(noiseFloor[i] * 5.5, 900)
            if abs(delta) < gate {
                baseline[i] = baseline[i] * 0.985 + channels[i] * 0.015
            }
            noiseFloor[i] = noiseFloor[i] * 0.985 + abs(delta) * 0.015
        }
        stableFrameCount = min(stableFrameCount + 1, 9999)

        let horizontalRaw = deltas[1] - deltas[0]
        let verticalRaw = deltas[2] - deltas[3]
        let eogScale = max(600, noiseFloor.reduce(0, +) / 4.0 * 12.0)

        let horizontal = (horizontalRaw / eogScale).clamped(to: -1...1)
        let vertical = (verticalRaw / eogScale).clamped(to: -1...1)

        let blinkRaw = max(abs(deltas[0]), abs(deltas[1]))
        let blinkThreshold = max(120, max(noiseFloor[0], noiseFloor[1]) * 3.8)
        let blinkStrength = ((blinkRaw - blinkThreshold) / max(80, blinkThreshold)).clamped(to: 0...1)

        // 初期学習中は大きな跳ねを抑えて安定化。
        let alpha: Double = stableFrameCount < 12 ? 0.18 : 0.34
        smoothedHorizontal = smoothedHorizontal * (1 - alpha) + horizontal * alpha
        smoothedVertical = smoothedVertical * (1 - alpha) + vertical * alpha
        smoothedBlink = smoothedBlink * 0.70 + blinkStrength * 0.30

        return SensorFrame(
            horizontal: smoothedHorizontal.clamped(to: -1...1),
            vertical: smoothedVertical.clamped(to: -1...1),
            blinkStrength: smoothedBlink.clamped(to: 0...1),
            source: "bluetooth/g2-binary-\(data.count)b"
        )
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private struct ProbePacketSample {
    let timestamp: Date
    let digest: String
}

private struct StartProbeMetrics {
    let packetRateHz: Double
    let distinctCount: Int
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
        notificationCountSinceConnect = 0
        isStreamingEstablished = false
        startCommandProbeOrder = buildStartCommandProbeOrder()
        startCommandProbeCursor = 0
        activeStartCommandIndex = nil
        currentProbeWriteType = nil
        triedAlternateWriteTypeForCurrentCommand = false
        probeWindowPackets = []
        startCommandProbeWorkItem?.cancel()
        startCommandProbeWorkItem = nil
        startCommandRetryWorkItem?.cancel()
        startCommandRetryWorkItem = nil
        streamMaintainWorkItem?.cancel()
        streamMaintainWorkItem = nil
        streamSilenceWorkItem?.cancel()
        streamSilenceWorkItem = nil
        streamReadPollingWorkItem?.cancel()
        streamReadPollingWorkItem = nil
        streamEstablishedAt = nil
        packetsSinceStreamEstablished = 0
        lastFallbackAttemptAt = .distantPast
        lastStreamCommandSentAt = .distantPast
        didExhaustStartCommandsInSession = false
        lastProbeMetrics = nil
        notifySubscriptionReady = false
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
        let receivedCount = characteristicObservations.values.map(\.totalCount).reduce(0, +)
        let didExhaustStartCommandsAtDisconnect = didExhaustStartCommandsInSession
        let lastProbeMetricsAtDisconnect = lastProbeMetrics

        savedUUIDValidationWorkItem?.cancel()
        savedUUIDValidationWorkItem = nil
        startCommandProbeWorkItem?.cancel()
        startCommandProbeWorkItem = nil
        startCommandRetryWorkItem?.cancel()
        startCommandRetryWorkItem = nil
        streamMaintainWorkItem?.cancel()
        streamMaintainWorkItem = nil
        streamSilenceWorkItem?.cancel()
        streamSilenceWorkItem = nil
        streamReadPollingWorkItem?.cancel()
        streamReadPollingWorkItem = nil
        streamWriteCharacteristic = nil
        streamNotifyCharacteristic = nil
        writeCharacteristicCandidates = []
        currentWriteCharacteristicIndex = 0
        startCommandProbeOrder = []
        startCommandProbeCursor = 0
        activeStartCommandIndex = nil
        currentProbeWriteType = nil
        triedAlternateWriteTypeForCurrentCommand = false
        probeWindowPackets = []
        isStreamingEstablished = false
        streamEstablishedAt = nil
        packetsSinceStreamEstablished = 0
        lastFallbackAttemptAt = .distantPast
        lastStreamCommandSentAt = .distantPast
        didExhaustStartCommandsInSession = false
        lastProbeMetrics = nil
        notifySubscriptionReady = false
        connectedPeripheral = nil
        addDiagnosticEvent("切断: 受信パケット\(receivedCount)件")
        connectedAt = nil
        if hasStartedConnectionFlow {
            let failure = BLEConnectionFailure(
                title: "接続が切断されました",
                reason: disconnectReasonText(
                    error,
                    receivedCount: receivedCount,
                    didExhaustStartCommands: didExhaustStartCommandsAtDisconnect,
                    lastProbeMetrics: lastProbeMetricsAtDisconnect
                ),
                recoverySuggestion: disconnectRecoverySuggestion(
                    receivedCount: receivedCount,
                    didExhaustStartCommands: didExhaustStartCommandsAtDisconnect
                )
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
            if shouldEnableNotification(for: characteristic) {
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

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            addDiagnosticEvent("WRITE失敗: \(characteristic.uuid.uuidString) \(error.localizedDescription)")
            return
        }
        addDiagnosticEvent("WRITE成功: \(characteristic.uuid.uuidString)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            onStatusChange?("通知設定失敗: \(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying else { return }
        notifySubscriptionReady = true
        streamNotifyCharacteristic = characteristic
        selectedNotifyCharacteristicID = characteristic.uuid
        selectedServiceID = characteristic.service?.uuid
        configuration.saveResolved(serviceUUID: selectedServiceID, notifyUUID: selectedNotifyCharacteristicID)
        onStatusChange?("通知有効化完了: \(characteristic.uuid.uuidString)")
        beginLoggerLikeStartSequenceIfReady(peripheral: peripheral)
        scheduleReadPollingFallback(peripheral: peripheral)
        addDiagnosticEvent("READフォールバック待機: \(characteristic.uuid.uuidString)")
    }
}
