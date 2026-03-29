import SwiftUI

struct CSVTab: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var isEditing = false
    @State private var selectedFiles: Set<String> = []
    @State private var showShareSheet = false
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.csvFiles.isEmpty {
                    emptyState
                } else {
                    fileList
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("CSV一覧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !viewModel.csvFiles.isEmpty {
                        Button(isEditing ? "完了" : "編集") {
                            withAnimation {
                                isEditing.toggle()
                                if !isEditing {
                                    selectedFiles.removeAll()
                                }
                            }
                        }
                        .foregroundStyle(.blue)
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let shareURL {
                    ShareSheet(activityItems: [shareURL])
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("CSVファイルがありません")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("ロガータブで記録を開始すると\nここにファイルが表示されます")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - File List

    private var fileList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(viewModel.csvFiles) { file in
                    Button {
                        if isEditing {
                            toggleSelection(file.id)
                        } else {
                            shareURL = file.fileURL
                            showShareSheet = true
                        }
                    } label: {
                        HStack {
                            if isEditing {
                                Image(systemName: selectedFiles.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedFiles.contains(file.id) ? .blue : .secondary)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.fileName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                HStack(spacing: 8) {
                                    Text(fileSizeString(file.fileSize))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(dateString(file.createdAt))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if !isEditing {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete { indexSet in
                    viewModel.deleteCSVFiles(at: indexSet)
                }
            }
            .listStyle(.plain)

            if isEditing && !selectedFiles.isEmpty {
                HStack(spacing: 16) {
                    Button {
                        viewModel.deleteCSVFiles(ids: selectedFiles)
                        selectedFiles.removeAll()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("選択削除 (\(selectedFiles.count)件)")
                        }
                        .foregroundStyle(.red)
                    }

                    Spacer()

                    Button {
                        let urls = viewModel.csvFiles
                            .filter { selectedFiles.contains($0.id) }
                            .map(\.fileURL)
                        if let first = urls.first {
                            shareURL = first
                            showShareSheet = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("共有")
                        }
                        .foregroundStyle(.blue)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    // MARK: - Helpers

    private func toggleSelection(_ id: String) {
        if selectedFiles.contains(id) {
            selectedFiles.remove(id)
        } else {
            selectedFiles.insert(id)
        }
    }

    private func fileSizeString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
