import Foundation

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
    case mock = "Mock"

    var id: String { rawValue }
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

    // The official public SDK ended on 2024-05-20, so these UUIDs must be filled
    // with the values available in your internal/dev environment if you have them.
    let serviceUUID: UUID? = nil
    let notifyCharacteristicUUID: UUID? = nil
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
