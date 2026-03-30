import Foundation
import CoreBluetooth

struct SensorFrame: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let horizontal: Double
    let vertical: Double
    let blinkStrength: Double
    let source: String
    // 6軸IMUデータ（BLE 20バイトパケット byte 8-19 から抽出）
    var accX: Double
    var accY: Double
    var accZ: Double
    var gyroX: Double
    var gyroY: Double
    var gyroZ: Double

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        horizontal: Double,
        vertical: Double,
        blinkStrength: Double,
        source: String,
        accX: Double = 0,
        accY: Double = 0,
        accZ: Double = 0,
        gyroX: Double = 0,
        gyroY: Double = 0,
        gyroZ: Double = 0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.horizontal = horizontal
        self.vertical = vertical
        self.blinkStrength = blinkStrength
        self.source = source
        self.accX = accX
        self.accY = accY
        self.accZ = accZ
        self.gyroX = gyroX
        self.gyroY = gyroY
        self.gyroZ = gyroZ
    }
}

struct ExtendedSensorData: Equatable {
    var accX: Double = 0
    var accY: Double = 0
    var accZ: Double = 0
    var gyroRoll: Double = 0
    var gyroPitch: Double = 0
    var gyroYaw: Double = 0
    var tiltX: Double = 0
    var tiltY: Double = 0
    var isStill: Double = 0
    var noise: Double = 0
    var blinkSpeed: Double = 0
    var blinkCount: Int = 0
    var gazeMovementCount: Int = 0
    var headMovementCount: Int = 0
}

struct GazePoint: Equatable {
    let x: Double
    let y: Double
}

struct CalibrationSample: Identifiable, Equatable {
    let id = UUID()
    let horizontal: Double
    let vertical: Double
    let targetX: Double
    let targetY: Double
}

enum LoggerDataMode: String, CaseIterable, Identifiable {
    case realtime = "リアルタイム"
    case summary15Walk = "15秒(歩行)"
    case summary15Still = "15秒(静止)"
    case summary60Walk = "60秒(歩行)"
    case summary60Still = "60秒(静止)"
    case stateDetection = "状態検出"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .realtime: return "リアルタイム"
        case .summary15Walk: return "15秒\n歩行"
        case .summary15Still: return "15秒\n静止"
        case .summary60Walk: return "60秒\n歩行"
        case .summary60Still: return "60秒\n静止"
        case .stateDetection: return "状態検出"
        }
    }
}

struct CSVFileInfo: Identifiable, Equatable {
    let id: String
    let fileName: String
    let fileURL: URL
    let fileSize: Int64
    let createdAt: Date
    let dataType: String
}

class AppSettings: ObservableObject {
    @Published var autoSave: Bool {
        didSet { UserDefaults.standard.set(autoSave, forKey: "settings.autoSave") }
    }
    @Published var saveIntervalMinutes: Int {
        didSet { UserDefaults.standard.set(saveIntervalMinutes, forKey: "settings.saveInterval") }
    }
    @Published var enableGyro: Bool {
        didSet { UserDefaults.standard.set(enableGyro, forKey: "settings.enableGyro") }
    }
    @Published var googleDriveEnabled: Bool {
        didSet { UserDefaults.standard.set(googleDriveEnabled, forKey: "settings.googleDrive") }
    }

    init() {
        autoSave = UserDefaults.standard.bool(forKey: "settings.autoSave")
        saveIntervalMinutes = UserDefaults.standard.object(forKey: "settings.saveInterval") as? Int ?? 60
        enableGyro = UserDefaults.standard.object(forKey: "settings.enableGyro") as? Bool ?? true
        googleDriveEnabled = UserDefaults.standard.bool(forKey: "settings.googleDrive")
    }
}

enum InputMode: String, CaseIterable, Identifiable {
    case bluetooth = "Bluetooth"
    case loggerBridge = "Logger Bridge"
    case mock = "Mock"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bluetooth:
            return "BLE直結"
        case .loggerBridge:
            return "Logger連携"
        case .mock:
            return "Mock"
        }
    }
}

struct AffineCalibration: Equatable {
    let x: [Double]
    let y: [Double]
}

struct BLEConfiguration {
    let peripheralNameHints = [
        "JINS MEME",
        "JINS_MEME",
        "JINSG2",
        "JINSG2_",
        "JINS",
        "MEME"
    ]

    // Confirmed from on-device BLE diagnostics.
    let serviceUUID: UUID? = UUID(uuidString: "F5DC3761-CE15-4449-8CFA-7AF6AD175056")
    let notifyCharacteristicUUID: UUID? = UUID(uuidString: "F5DC3764-CE15-4449-8CFA-7AF6AD175056")
    let writeCharacteristicUUID: UUID? = UUID(uuidString: "F5DC3762-CE15-4449-8CFA-7AF6AD175056")

    // Logger連携 / nRF実測で確認した開始コマンド候補。
    // 先頭を最優先で試行し、失敗時に順送りで切り替える。
    let enableStreamStartCommandProbe = true
    let streamStartCommandCandidates: [Data] = [
        Data([0x01, 0x00]),
        Data([0x01]),
        Data([0x0A]),
        Data([0x02]),
        Data([0x03]),
        Data([0x00]),
        Data([0x01, 0x01]),
        Data([0xFF])
    ]
    let streamStartProbeInitialDelay: TimeInterval = 0.5
    let streamStartProbeEvaluationInterval: TimeInterval = 6.0
    let streamStartProbeWindow: TimeInterval = 4.0
    let streamStartProbeMinimumPacketRateHz: Double = 1.0
    let streamStartProbeMinimumDistinctPackets = 1
    let streamStartProbeRetryInterval: TimeInterval = 5.0
    let streamMaintainPulseInterval: TimeInterval = 5.0
    let streamSilenceCheckInterval: TimeInterval = 1.0
    let streamSilenceThreshold: TimeInterval = 5.0
    let streamEarlyDropWindow: TimeInterval = 8.0
    let streamEarlyDropPacketThreshold = 12
    let streamFallbackCommandCooldown: TimeInterval = 3.0
    let persistSuccessfulStreamCommand = true
    let enableReadPollingFallback = true
    let readPollingInterval: TimeInterval = 0.2

    private let savedServiceUUIDKey = "meme.saved.service.uuid"
    private let savedNotifyUUIDKey = "meme.saved.notify.uuid"
    private let preferredStreamCommandIndexKey = "meme.saved.stream.command.success.index"

    var resolvedServiceUUID: UUID? {
        serviceUUID ?? UUID(uuidString: UserDefaults.standard.string(forKey: savedServiceUUIDKey) ?? "")
    }

    var resolvedNotifyCharacteristicUUID: UUID? {
        notifyCharacteristicUUID ?? UUID(uuidString: UserDefaults.standard.string(forKey: savedNotifyUUIDKey) ?? "")
    }

    var isUsingPersistedUUIDFallback: Bool {
        serviceUUID == nil && notifyCharacteristicUUID == nil
    }

    func saveResolved(serviceUUID: CBUUID?, notifyUUID: CBUUID?) {
        if let serviceUUID {
            UserDefaults.standard.set(serviceUUID.uuidString, forKey: savedServiceUUIDKey)
        }
        if let notifyUUID {
            UserDefaults.standard.set(notifyUUID.uuidString, forKey: savedNotifyUUIDKey)
        }
    }

    func clearResolved() {
        UserDefaults.standard.removeObject(forKey: savedServiceUUIDKey)
        UserDefaults.standard.removeObject(forKey: savedNotifyUUIDKey)
    }

    var preferredStreamStartCommandIndex: Int? {
        guard !streamStartCommandCandidates.isEmpty else { return nil }
        guard let rawValue = UserDefaults.standard.object(forKey: preferredStreamCommandIndexKey) else {
            return nil
        }
        let raw: Int
        if let intValue = rawValue as? Int {
            raw = intValue
        } else if let number = rawValue as? NSNumber {
            raw = number.intValue
        } else {
            return nil
        }
        guard raw >= 0 && raw < streamStartCommandCandidates.count else { return nil }
        return raw
    }

    func savePreferredStreamStartCommandIndex(_ index: Int) {
        guard persistSuccessfulStreamCommand else { return }
        guard index >= 0 && index < streamStartCommandCandidates.count else { return }
        UserDefaults.standard.set(index, forKey: preferredStreamCommandIndexKey)
    }

    func clearPreferredStreamStartCommandIndex() {
        UserDefaults.standard.removeObject(forKey: preferredStreamCommandIndexKey)
    }
}

enum BLEConnectionState: Equatable {
    case idle
    case scanning
    case connecting(deviceName: String)
    case connected(deviceName: String)
    case failed(BLEConnectionFailure)
}

struct BLEConnectionFailure: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let reason: String
    let recoverySuggestion: String
}

struct BLEPacketSnapshot: Equatable {
    let receivedAt: Date
    let byteCount: Int
    let hexPreview: String
}

enum NetworkInterfaceInfo {
    static func getLocalIPAddresses() -> [String] {
        var addresses = [String]()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        guard let firstAddr = ifaddr else { return [] }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let name = String(cString: interface.ifa_name)
            
            // IPv4 のみを対象 (AF_INET = 2)
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                    let address = String(cString: hostname)
                    // ループバック (127.0.0.1) を除外
                    if address != "127.0.0.1" && address != "0.0.0.0" {
                        addresses.append("\(name): \(address)")
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return addresses
    }
    
    static func bestAvailableIP() -> String? {
        let all = getLocalIPAddresses()
        
        // テザリングのIP (bridgeインターフェース) を最優先
        if let hotspot = all.first(where: { $0.hasPrefix("bridge") }) {
            return hotspot.components(separatedBy: ": ").last
        }
        // 次に Wi-Fi (en0)
        if let wifi = all.first(where: { $0.hasPrefix("en0") }) {
            return wifi.components(separatedBy: ": ").last
        }
        
        // pdp_ip (キャリア通信) などその他のアドレスは接続不能なため無視する
        return nil
    }
}

import AVFoundation

final class SilentAudioPlayer {
    static let shared = SilentAudioPlayer()
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isPlaying = false
    
    private init() {
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // Do not active immediately, wait for start
        } catch {
            print("Audio session setup failed: \(error)")
        }
    }
    
    func start() {
        guard !isPlaying else { return }
        
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session start failed: \(error)")
        }
        
        engine.attach(playerNode)
        
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        
        // 無音のバッファを作成
        let frameCount = AVAudioFrameCount(format.sampleRate * 2.0)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                data[i] = 0.0 // Silence
            }
        }
        
        do {
            try engine.start()
            playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            playerNode.play()
            isPlaying = true
        } catch {
            print("Engine start failed: \(error)")
        }
    }
    
    func stop() {
        guard isPlaying else { return }
        playerNode.stop()
        engine.stop()
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
