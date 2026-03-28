import SwiftUI

struct MacReceiverContentView: View {
    @ObservedObject var viewModel: MacReceiverViewModel

    var body: some View {
        VStack(spacing: 18) {
            header
            stage
            table
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(red: 0.95, green: 0.93, blue: 0.89), Color(red: 0.88, green: 0.91, blue: 0.96)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac Receiver")
                .font(.caption)
                .foregroundStyle(.teal)
                .fontWeight(.semibold)
            Text("JINS MEME ES 共有データ受信")
                .font(.largeTitle)
                .fontWeight(.bold)

            HStack {
                statCard(title: "状態", value: viewModel.statusText)
                statCard(title: "接続端末", value: viewModel.connectedPeers.joined(separator: ", ").ifEmpty("なし"))
                statCard(title: "座標", value: "\(Int(viewModel.latestPoint.x)), \(Int(viewModel.latestPoint.y))")
            }

            if let frame = viewModel.latestFrame {
                Text("horizontal: \(frame.horizontal.formatted(.number.precision(.fractionLength(3)))) / vertical: \(frame.vertical.formatted(.number.precision(.fractionLength(3)))) / blink: \(frame.blinkStrength.formatted(.number.precision(.fractionLength(2))))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 24))
    }

    private var stage: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.13, green: 0.18, blue: 0.24), Color(red: 0.08, green: 0.11, blue: 0.16)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                ForEach(Array(viewModel.trail.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(Color.orange.opacity(Double(index + 1) / Double(max(viewModel.trail.count, 1)) * 0.25))
                        .frame(width: 32, height: 32)
                        .position(x: point.x / 1280.0 * proxy.size.width, y: point.y / 720.0 * proxy.size.height)
                }
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.orange, lineWidth: 5))
                    .shadow(color: .orange.opacity(0.35), radius: 10)
                    .position(
                        x: viewModel.latestPoint.x / 1280.0 * proxy.size.width,
                        y: viewModel.latestPoint.y / 720.0 * proxy.size.height
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("受信ログ")
                .font(.headline)
            List {
                if let frame = viewModel.latestFrame {
                    LabeledContent("Timestamp", value: frame.timestamp.formatted(date: .omitted, time: .standard))
                    LabeledContent("Source", value: frame.source)
                    LabeledContent("Horizontal", value: frame.horizontal.formatted(.number.precision(.fractionLength(3))))
                    LabeledContent("Vertical", value: frame.vertical.formatted(.number.precision(.fractionLength(3))))
                    LabeledContent("Blink", value: frame.blinkStrength.formatted(.number.precision(.fractionLength(2))))
                } else {
                    Text("まだ受信していません")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 180)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 24))
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
