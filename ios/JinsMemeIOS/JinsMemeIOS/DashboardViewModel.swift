import Foundation
import SwiftUI
import Combine

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var inputMode: InputMode = .bluetooth
    @Published var loggerHost: String {
        didSet {
            UserDefaults.standard.set(loggerHost, forKey: loggerHostDefaultsKey)
        }
    }
    @Published var loggerPort: String {
        didSet {
            UserDefaults.standard.set(loggerPort, forKey: loggerPortDefaultsKey)
        }
    }
    @Published var connectionState: BLEConnectionState = .idle
    @Published var statusText: String = "未接続"
    @Published var failureAlert: BLEConnectionFailure?
    @Published var bleDiagnosticText: String = "-"
    @Published var latestFrame: SensorFrame?
    @Published var latestPacket: BLEPacketSnapshot?
    @Published var receivedPacketCount = 0
    @Published var displayUpdatedAt: Date = .now
    @Published var latestPoint = GazePoint(x: 640, y: 360)
    @Published var gazeTrail: [GazePoint] = []
    @Published var horizontalBlinking = false
    @Published var verticalBlinking = false
    @Published var blinkStrengthBlinking = false
    @Published var calibrationState: CalibrationState = .idle
    @Published var calibrationTargetIndex = 0
    @Published var calibrationCompletedCount = 0

    // Logger tab properties
    @Published var loggerDataMode: LoggerDataMode = .realtime
    @Published var isRecording = false
    @Published var extendedData = ExtendedSensorData()
    @Published var csvFiles: [CSVFileInfo] = []
    @Published var pendingUploadCount = 0

    // History arrays for mini charts (last 120 samples)
    @Published var horizontalHistory: [Double] = []
    @Published var verticalHistory: [Double] = []
    @Published var blinkStrengthHistory: [Double] = []
    @Published var blinkSpeedHistory: [Double] = []
    @Published var accXHistory: [Double] = []
    @Published var accYHistory: [Double] = []
    @Published var accZHistory: [Double] = []
    @Published var gyroRollHistory: [Double] = []
    @Published var gyroPitchHistory: [Double] = []
    @Published var gyroYawHistory: [Double] = []
    @Published var tiltXHistory: [Double] = []
    @Published var tiltYHistory: [Double] = []
    @Published var isStillHistory: [Double] = []
    @Published var noiseHistory: [Double] = []

    private let bluetoothSource = JinsMemeBLESource()
    private let loggerBridgeSource = LoggerBridgeSource()
    private var estimator = GazeEstimator()
    private var updateTimer: AnyCancellable?
    private var bufferedLatestFrame: SensorFrame?
    private var bufferedLatestPacket: BLEPacketSnapshot?
    private var bufferedPacketCount = 0
    private var horizontalBlinkTask: Task<Void, Never>?
    private var verticalBlinkTask: Task<Void, Never>?
    private var blinkStrengthBlinkTask: Task<Void, Never>?
    private var autoRetryTask: Task<Void, Never>?
    private var autoRetryCount = 0
    private var lastStallRecoveryAt: Date?
    private var connectedAt: Date?
    private var packetCountAtConnect = 0
    private var lastPacketChangeAt: Date?
    private var recentFrames: [FrameSample] = []
    private var calibrationSamples: [CalibrationSample] = []
    private let loggerHostDefaultsKey = "stateLens.logger.host"
    private let loggerPortDefaultsKey = "stateLens.logger.port"
    private let csvRecorder = CSVRecorder()
    private let historyMaxCount = 120

    private let maxAutoRetryCount = 3
    private let enableAutomaticStallRecovery = true
    private let stallThreshold: TimeInterval = 15
    private let stallRecoveryCooldown: TimeInterval = 20
    private let stallMonitoringWarmup: TimeInterval = 30
    private let stallMinimumPacketsBeforeRecovery = 5

    let calibrationTargets: [GazePoint] = [
        GazePoint(x: 160, y: 120), GazePoint(x: 640, y: 120), GazePoint(x: 1120, y: 120),
        GazePoint(x: 160, y: 360), GazePoint(x: 640, y: 360), GazePoint(x: 1120, y: 360),
        GazePoint(x: 160, y: 600), GazePoint(x: 640, y: 600), GazePoint(x: 1120, y: 600),
    ]

    init() {
        loggerHost = UserDefaults.standard.string(forKey: loggerHostDefaultsKey) ?? "192.168.4.33"
        loggerPort = UserDefaults.standard.string(forKey: loggerPortDefaultsKey) ?? "8765"
        configureBluetoothCallbacks()
        configureLoggerBridgeCallbacks()
        startUpdateTimer()
        refreshCSVFiles()
    }

    func selectInputMode(_ mode: InputMode) {
        guard mode != .mock else { return }
        guard inputMode != mode else { return }
        disconnect()
        inputMode = mode
        connectionState = .idle
        statusText = mode == .bluetooth ? "未接続" : "Logger未接続"
        bleDiagnosticText = mode == .bluetooth ? "-" : "Logger endpoint: \(loggerEndpointDescription)"
        latestFrame = nil
        latestPacket = nil
        bufferedLatestFrame = nil
        bufferedLatestPacket = nil
        bufferedPacketCount = 0
        receivedPacketCount = 0
        gazeTrail = []
        latestPoint = GazePoint(x: 640, y: 360)
        estimator = GazeEstimator()
    }

    private func configureBluetoothCallbacks() {
        bluetoothSource.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.statusText = status
            }
        }

        bluetoothSource.onDiagnosticInfo = { [weak self] text in
            Task { @MainActor in
                self?.bleDiagnosticText = text
            }
        }

        bluetoothSource.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in
                self?.connectionState = state
                self?.syncStatus(for: state)
                switch state {
                case .connected:
                    self?.autoRetryCount = 0
                    self?.autoRetryTask?.cancel()
                    self?.lastStallRecoveryAt = nil
                    self?.connectedAt = Date()
                    self?.packetCountAtConnect = self?.bufferedPacketCount ?? 0
                    self?.lastPacketChangeAt = nil
                    // 前回接続時の受信時刻を参照して誤検知しないよう、接続セッション開始時にクリアする。
                    self?.latestPacket = nil
                    self?.bufferedLatestPacket = nil
                case .failed(let failure):
                    self?.connectedAt = nil
                    self?.handleConnectionFailure(failure)
                default:
                    if case .idle = state {
                        self?.connectedAt = nil
                    }
                    break
                }
            }
        }

        bluetoothSource.onRawPacket = { [weak self] packet in
            Task { @MainActor in
                self?.bufferedLatestPacket = packet
                self?.bufferedPacketCount += 1
                self?.lastPacketChangeAt = .now
            }
        }

        bluetoothSource.onFrame = { [weak self] frame in
            Task { @MainActor in
                self?.bufferedLatestFrame = frame
                self?.recentFrames.append(FrameSample(frame: frame, timestamp: .now))
                self?.trimRecentFrames()
                // 接続直後の最初のフレームはUIを即時更新（1秒タイマー待ちせず表示）
                if self?.latestFrame == nil {
                    self?.latestFrame = frame
                    self?.displayUpdatedAt = .now
                }
            }
        }
    }

    private func configureLoggerBridgeCallbacks() {
        loggerBridgeSource.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.statusText = status
            }
        }

        loggerBridgeSource.onDiagnosticInfo = { [weak self] text in
            Task { @MainActor in
                self?.bleDiagnosticText = text
            }
        }

        loggerBridgeSource.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in
                self?.connectionState = state
                self?.syncStatus(for: state)
                if case .failed(let failure) = state {
                    self?.handleConnectionFailure(failure)
                }
            }
        }

        loggerBridgeSource.onRawPacket = { [weak self] packet in
            Task { @MainActor in
                self?.bufferedLatestPacket = packet
                self?.bufferedPacketCount += 1
                self?.lastPacketChangeAt = .now
            }
        }

        loggerBridgeSource.onFrame = { [weak self] frame in
            Task { @MainActor in
                self?.bufferedLatestFrame = frame
                self?.recentFrames.append(FrameSample(frame: frame, timestamp: .now))
                self?.trimRecentFrames()
            }
        }
    }

    func connectToMeme() {
        startConnectionFlow(resetUIState: true)
    }

    private func startConnectionFlow(resetUIState: Bool) {
        autoRetryTask?.cancel()
        autoRetryTask = nil
        lastStallRecoveryAt = nil

        if resetUIState {
            failureAlert = nil
            bleDiagnosticText = "-"
            latestFrame = nil
            latestPacket = nil
            receivedPacketCount = 0
            latestPoint = GazePoint(x: 640, y: 360)
            gazeTrail = []
            estimator = GazeEstimator()
            bufferedLatestFrame = nil
            bufferedLatestPacket = nil
            bufferedPacketCount = 0
            lastPacketChangeAt = nil
            recentFrames = []
            displayUpdatedAt = .now
            horizontalBlinking = false
            verticalBlinking = false
            blinkStrengthBlinking = false
            autoRetryCount = 0
        }

        if inputMode == .bluetooth {
            bluetoothSource.start()
        } else {
            guard let endpointURL = loggerEndpointURL else {
                failureAlert = BLEConnectionFailure(
                    title: "Logger連携に失敗しました",
                    reason: "Logger連携先URLが不正です。",
                    recoverySuggestion: "Host と Port を確認してください。"
                )
                return
            }
            loggerBridgeSource.setEndpointURL(endpointURL)
            loggerBridgeSource.start()
        }
    }

    func startCalibration() {
        guard latestFrame != nil else {
            statusText = "較正にはセンサーデータ受信が必要です"
            return
        }
        calibrationSamples = []
        calibrationTargetIndex = 0
        calibrationCompletedCount = 0
        calibrationState = .running
        statusText = "較正開始: ターゲットを見て「この点を記録」を押してください"
    }

    func captureCalibrationPoint() {
        guard calibrationState == .running else { return }
        guard calibrationTargetIndex < calibrationTargets.count else { return }
        let averagedFrame = averagedRecentFrame(window: 1.0)
        guard let frame = averagedFrame ?? latestFrame else {
            statusText = "センサーデータ未受信のため記録できません"
            return
        }

        let target = calibrationTargets[calibrationTargetIndex]
        calibrationSamples.append(
            CalibrationSample(
                horizontal: frame.horizontal,
                vertical: frame.vertical,
                targetX: target.x,
                targetY: target.y
            )
        )
        calibrationCompletedCount = calibrationSamples.count
        calibrationTargetIndex += 1

        if calibrationTargetIndex >= calibrationTargets.count {
            do {
                try estimator.solveCalibration(samples: calibrationSamples)
                calibrationState = .completed
                statusText = "較正完了: 視線マップを補正しました"
            } catch {
                calibrationState = .failed
                statusText = error.localizedDescription
            }
        }
    }

    func resetCalibration() {
        estimator.resetCalibration()
        calibrationSamples = []
        calibrationTargetIndex = 0
        calibrationCompletedCount = 0
        calibrationState = .idle
        statusText = "較正をリセットしました"
    }

    func disconnect() {
        autoRetryTask?.cancel()
        autoRetryTask = nil
        bluetoothSource.stop()
        loggerBridgeSource.stop()
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        let deviceName: String
        if case .connected(let name) = connectionState {
            deviceName = name.replacingOccurrences(of: " ", with: "_")
        } else {
            deviceName = "UNKNOWN"
        }
        _ = csvRecorder.startRecording(deviceID: deviceName)
        isRecording = true
    }

    private func stopRecording() {
        _ = csvRecorder.stopRecording()
        isRecording = false
        refreshCSVFiles()
    }

    // MARK: - CSV Management

    func refreshCSVFiles() {
        csvFiles = CSVFileManager.listFiles()
    }

    func deleteCSVFiles(at indexSet: IndexSet) {
        let filesToDelete = indexSet.map { csvFiles[$0] }
        CSVFileManager.deleteFiles(filesToDelete)
        refreshCSVFiles()
    }

    func deleteCSVFiles(ids: Set<String>) {
        let filesToDelete = csvFiles.filter { ids.contains($0.id) }
        CSVFileManager.deleteFiles(filesToDelete)
        refreshCSVFiles()
    }

    var calibrationProgressText: String {
        "\(calibrationCompletedCount)/\(calibrationTargets.count)"
    }

    var currentCalibrationTarget: GazePoint? {
        guard calibrationState == .running else { return nil }
        guard calibrationTargetIndex < calibrationTargets.count else { return nil }
        return calibrationTargets[calibrationTargetIndex]
    }

    var calibrationStatusText: String {
        switch calibrationState {
        case .idle:
            return "未実施"
        case .running:
            return "実施中"
        case .completed:
            return "完了"
        case .failed:
            return "失敗"
        }
    }

    var calibrationStatusColor: Color {
        switch calibrationState {
        case .idle:
            return .gray
        case .running:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private func handleConnectionFailure(_ failure: BLEConnectionFailure) {
        guard inputMode == .bluetooth else {
            failureAlert = failure
            return
        }
        if autoRetryCount < maxAutoRetryCount {
            autoRetryCount += 1
            statusText = "接続失敗。自動再試行 \(autoRetryCount)/\(maxAutoRetryCount)"
            autoRetryTask?.cancel()
            autoRetryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                self.bluetoothSource.start()
            }
            return
        }
        failureAlert = failure
    }

    private func recoverIfStalled() {
        guard inputMode == .bluetooth else { return }
        guard enableAutomaticStallRecovery else { return }
        guard case .connected = connectionState else { return }
        guard let connectedAt else { return }
        let now = Date()

        // 接続直後は通知間隔が安定しないため、停止判定をしない。
        guard now.timeIntervalSince(connectedAt) >= stallMonitoringWarmup else { return }

        let packetsSinceConnect = bufferedPacketCount - packetCountAtConnect
        guard packetsSinceConnect >= stallMinimumPacketsBeforeRecovery else { return }
        guard let lastPacketChangeAt else { return }
        let stalled = now.timeIntervalSince(lastPacketChangeAt) >= stallThreshold
        guard stalled else { return }

        if let lastStallRecoveryAt, now.timeIntervalSince(lastStallRecoveryAt) < stallRecoveryCooldown {
            return
        }
        lastStallRecoveryAt = now
        self.connectedAt = nil
        statusText = "受信停止を検知したため再接続します"
        bluetoothSource.stop()
        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.bluetoothSource.start()
        }
    }

    var buttonTitle: String {
        switch connectionState {
        case .connected:
            return "接続済み"
        case .scanning:
            return "スキャン中..."
        case .connecting:
            return "接続中..."
        case .failed:
            return "再接続する"
        case .idle:
            return inputMode == .bluetooth ? "MEMEに接続" : "Loggerに接続"
        }
    }

    var buttonColor: Color {
        switch connectionState {
        case .connected:
            return .blue
        case .failed:
            return .red
        case .scanning, .connecting:
            return Color(red: 0.08, green: 0.43, blue: 0.53)
        case .idle:
            return Color(red: 0.25, green: 0.33, blue: 0.41)
        }
    }

    private func syncStatus(for state: BLEConnectionState) {
        switch state {
        case .idle:
            statusText = "未接続"
        case .scanning:
            statusText = inputMode == .bluetooth ? "JINS MEMEを探しています" : "Logger連携サーバーへ接続中"
        case .connecting(let deviceName):
            statusText = "\(deviceName) に接続中"
        case .connected(let deviceName):
            statusText = "\(deviceName) に接続しました"
        case .failed(let failure):
            statusText = failure.reason
        }
    }

    var connectionSectionTitle: String {
        inputMode == .bluetooth ? "BLE接続" : "Logger連携"
    }

    var loggerEndpointDescription: String {
        "http://\(loggerHost):\(loggerPort)/api/state"
    }

    private var loggerEndpointURL: URL? {
        let host = loggerHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = loggerPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        guard let port = Int(portText), (1...65535).contains(port) else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/api/state"
        return components.url
    }

    private func startUpdateTimer() {
        updateTimer?.cancel()
        updateTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let previousFrame = self.latestFrame

                if let packet = self.bufferedLatestPacket {
                    self.latestPacket = packet
                }
                self.receivedPacketCount = self.bufferedPacketCount

                if let frame = self.bufferedLatestFrame {
                    self.latestFrame = frame
                    self.triggerBlinkIfNeeded(previous: previousFrame, current: frame)
                    let point = self.estimator.ingest(frame)
                    self.latestPoint = point
                    self.gazeTrail.append(point)
                    if self.gazeTrail.count > 120 {
                        self.gazeTrail.removeFirst(self.gazeTrail.count - 120)
                    }

                    // Update history arrays for Logger tab charts
                    self.appendHistory(&self.horizontalHistory, value: frame.horizontal)
                    self.appendHistory(&self.verticalHistory, value: frame.vertical)
                    self.appendHistory(&self.blinkStrengthHistory, value: frame.blinkStrength)
                    self.appendHistory(&self.blinkSpeedHistory, value: self.extendedData.blinkSpeed)
                    self.appendHistory(&self.accXHistory, value: self.extendedData.accX)
                    self.appendHistory(&self.accYHistory, value: self.extendedData.accY)
                    self.appendHistory(&self.accZHistory, value: self.extendedData.accZ)
                    self.appendHistory(&self.gyroRollHistory, value: self.extendedData.gyroRoll)
                    self.appendHistory(&self.gyroPitchHistory, value: self.extendedData.gyroPitch)
                    self.appendHistory(&self.gyroYawHistory, value: self.extendedData.gyroYaw)
                    self.appendHistory(&self.tiltXHistory, value: self.extendedData.tiltX)
                    self.appendHistory(&self.tiltYHistory, value: self.extendedData.tiltY)
                    self.appendHistory(&self.isStillHistory, value: self.extendedData.isStill)
                    self.appendHistory(&self.noiseHistory, value: self.extendedData.noise)

                    // Write to CSV if recording
                    if self.csvRecorder.isRecording {
                        self.csvRecorder.writeFrame(frame, extended: self.extendedData)
                    }
                }
                self.displayUpdatedAt = .now
                self.recoverIfStalled()
            }
    }

    private func appendHistory(_ array: inout [Double], value: Double) {
        array.append(value)
        if array.count > historyMaxCount {
            array.removeFirst(array.count - historyMaxCount)
        }
    }

    private func triggerBlinkIfNeeded(previous: SensorFrame?, current: SensorFrame?) {
        guard let current else { return }
        guard let previous else {
            triggerBlink(.horizontal)
            triggerBlink(.vertical)
            triggerBlink(.blinkStrength)
            return
        }

        if abs(current.horizontal - previous.horizontal) > 0.0001 {
            triggerBlink(.horizontal)
        }
        if abs(current.vertical - previous.vertical) > 0.0001 {
            triggerBlink(.vertical)
        }
        if abs(current.blinkStrength - previous.blinkStrength) > 0.0001 {
            triggerBlink(.blinkStrength)
        }
    }

    private func triggerBlink(_ field: BlinkField) {
        switch field {
        case .horizontal:
            horizontalBlinkTask?.cancel()
            horizontalBlinking = true
            horizontalBlinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, !Task.isCancelled else { return }
                self.horizontalBlinking = false
            }
        case .vertical:
            verticalBlinkTask?.cancel()
            verticalBlinking = true
            verticalBlinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, !Task.isCancelled else { return }
                self.verticalBlinking = false
            }
        case .blinkStrength:
            blinkStrengthBlinkTask?.cancel()
            blinkStrengthBlinking = true
            blinkStrengthBlinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, !Task.isCancelled else { return }
                self.blinkStrengthBlinking = false
            }
        }
    }

    private func trimRecentFrames() {
        let threshold = Date().addingTimeInterval(-4.0)
        recentFrames.removeAll { $0.timestamp < threshold }
        if recentFrames.count > 200 {
            recentFrames.removeFirst(recentFrames.count - 200)
        }
    }

    private func averagedRecentFrame(window: TimeInterval) -> SensorFrame? {
        let cutoff = Date().addingTimeInterval(-window)
        let targets = recentFrames
            .filter { $0.timestamp >= cutoff }
            .map(\.frame)
        guard !targets.isEmpty else { return nil }
        let count = Double(targets.count)
        let horizontal = targets.map(\.horizontal).reduce(0, +) / count
        let vertical = targets.map(\.vertical).reduce(0, +) / count
        let blink = targets.map(\.blinkStrength).reduce(0, +) / count
        return SensorFrame(horizontal: horizontal, vertical: vertical, blinkStrength: blink, source: targets.last?.source ?? "bluetooth")
    }
}

private enum BlinkField {
    case horizontal
    case vertical
    case blinkStrength
}

enum CalibrationState: Equatable {
    case idle
    case running
    case completed
    case failed
}

private struct FrameSample {
    let frame: SensorFrame
    let timestamp: Date
}
