import Combine
import Foundation
import SwiftUI

@MainActor
final class MacReceiverViewModel: ObservableObject {
    @Published var statusText = "起動中"
    @Published var latestFrame: SensorFrame?
    @Published var latestPoint = GazePoint(x: 640, y: 360)
    @Published var trail: [GazePoint] = []
    @Published var connectedPeers: [String] = []

    private let receiver = PeerRelayReceiver()

    init() {
        receiver.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.statusText = status
            }
        }
        receiver.onFrameReceive = { [weak self] frame in
            Task { @MainActor in
                self?.consume(frame)
            }
        }
        receiver.$connectedPeers
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectedPeers)
        receiver.start()
    }

    private func consume(_ frame: SensorFrame) {
        latestFrame = frame
        let point = GazePoint(
            x: ((frame.horizontal + 1.0) * 0.5 * 1280.0).clamped(to: 0...1280),
            y: ((1.0 - (frame.vertical + 1.0) * 0.5) * 720.0).clamped(to: 0...720)
        )
        latestPoint = point
        trail.append(point)
        if trail.count > 240 {
            trail.removeFirst(trail.count - 240)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
