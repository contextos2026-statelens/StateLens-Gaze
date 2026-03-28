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

struct GazePoint: Equatable, Identifiable {
    let id = UUID()
    let x: Double
    let y: Double
}
