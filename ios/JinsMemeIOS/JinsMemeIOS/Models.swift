import Foundation
import CoreBluetooth

struct SensorFrame: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let horizontal: Double
    let vertical: Double
    let blinkStrength: Double
    let source: String

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        horizontal: Double,
        vertical: Double,
        blinkStrength: Double,
        source: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.horizontal = horizontal
        self.vertical = vertical
        self.blinkStrength = blinkStrength
        self.source = source
    }
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
        "JINSG2",
        "JINSG2_",
    ]

    // Confirmed from on-device BLE diagnostics.
    let serviceUUID: UUID? = UUID(uuidString: "F5DC3761-CE15-4449-8CFA-7AF6AD175056")
    let notifyCharacteristicUUID: UUID? = UUID(uuidString: "F5DC3764-CE15-4449-8CFA-7AF6AD175056")
    let writeCharacteristicUUID: UUID? = UUID(uuidString: "F5DC3762-CE15-4449-8CFA-7AF6AD175056")
    let enableStreamStartCommandProbe = true
    let streamStartCommandCandidates: [Data] = [
        Data([0x01]),
        Data([0x02]),
        Data([0x03]),
        Data([0x01, 0x00]),
    ]
    let enablePeriodicStreamKeepAlive = true
    let streamKeepAliveInterval: TimeInterval = 4.0
    let streamKeepAliveSilenceThreshold: TimeInterval = 2.0
    let enableInSessionStreamCommandProbe = true
    let inSessionStreamCommandProbeInterval: TimeInterval = 3.0
    let enableStreamSilenceRestart = false
    let streamSilenceRestartThreshold: TimeInterval = 8.0
    let maxStreamRestartAttemptsPerSilence = 1
    // If we disconnect before receiving enough frames, advance to the next start command candidate.
    let streamCommandProbeDisconnectThreshold: TimeInterval = 25.0
    let streamCommandProbePacketThreshold = 8

    private let savedServiceUUIDKey = "meme.saved.service.uuid"
    private let savedNotifyUUIDKey = "meme.saved.notify.uuid"
    private let streamCommandCandidateIndexKey = "meme.saved.stream.command.index"

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

    var streamCommandCandidateIndex: Int {
        let raw = UserDefaults.standard.integer(forKey: streamCommandCandidateIndexKey)
        let maxIndex = max(0, streamStartCommandCandidates.count - 1)
        return min(max(raw, 0), maxIndex)
    }

    var selectedStreamStartCommand: Data {
        streamStartCommandCandidates[streamCommandCandidateIndex]
    }

    func advanceStreamStartCommandCandidate() {
        guard !streamStartCommandCandidates.isEmpty else { return }
        let next = (streamCommandCandidateIndex + 1) % streamStartCommandCandidates.count
        UserDefaults.standard.set(next, forKey: streamCommandCandidateIndexKey)
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
