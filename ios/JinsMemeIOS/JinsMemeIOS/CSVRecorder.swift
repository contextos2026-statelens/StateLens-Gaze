import Foundation

final class CSVRecorder {
    private var fileHandle: FileHandle?
    private var currentFileURL: URL?
    private var rowCount = 0
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    var isRecording: Bool { fileHandle != nil }

    func startRecording(deviceID: String, dataType: String = "currentData") -> URL? {
        stopRecording()

        let dir = CSVFileManager.csvDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let timestamp = dateFormatter.string(from: Date())
        let safeName = deviceID.replacingOccurrences(of: ":", with: "")
        let fileName = "\(timestamp)_\(safeName)_\(dataType).csv"
        let fileURL = dir.appendingPathComponent(fileName)

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        currentFileURL = fileURL
        rowCount = 0

        // Write header
        let header = "timestamp,horizontal,vertical,blinkStrength,accX,accY,accZ,gyroRoll,gyroPitch,gyroYaw,tiltX,tiltY,isStill,noise,blinkSpeed,source\n"
        if let data = header.data(using: .utf8) {
            fileHandle?.write(data)
        }

        return fileURL
    }

    func writeFrame(_ frame: SensorFrame, extended: ExtendedSensorData) {
        guard let fileHandle else { return }

        let ts = frame.timestamp.timeIntervalSince1970
        let line = String(
            format: "%.3f,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.4f,%.4f,%@\n",
            ts,
            frame.horizontal,
            frame.vertical,
            frame.blinkStrength,
            extended.accX,
            extended.accY,
            extended.accZ,
            extended.gyroRoll,
            extended.gyroPitch,
            extended.gyroYaw,
            extended.tiltX,
            extended.tiltY,
            extended.isStill,
            extended.noise,
            extended.blinkSpeed,
            frame.source
        )

        if let data = line.data(using: .utf8) {
            fileHandle.write(data)
            rowCount += 1
        }
    }

    func stopRecording() -> URL? {
        let url = currentFileURL
        fileHandle?.closeFile()
        fileHandle = nil
        currentFileURL = nil
        rowCount = 0
        return url
    }

    var currentRowCount: Int { rowCount }
}

enum CSVFileManager {
    static var csvDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("CSVData", isDirectory: true)
    }

    static func listFiles() -> [CSVFileInfo] {
        let dir = csvDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension.lowercased() == "csv" }
            .compactMap { url -> CSVFileInfo? in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                    return nil
                }
                let size = (attrs[.size] as? Int64) ?? 0
                let created = (attrs[.creationDate] as? Date) ?? Date()
                let fileName = url.lastPathComponent

                // Extract data type from filename pattern: YYYYMMDD-HHmmss_DeviceID_dataType.csv
                let dataType: String
                let components = fileName.replacingOccurrences(of: ".csv", with: "").split(separator: "_")
                if components.count >= 3 {
                    dataType = String(components.last!)
                } else {
                    dataType = "unknown"
                }

                return CSVFileInfo(
                    id: fileName,
                    fileName: fileName,
                    fileURL: url,
                    fileSize: size,
                    createdAt: created,
                    dataType: dataType
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func deleteFile(_ fileInfo: CSVFileInfo) {
        try? FileManager.default.removeItem(at: fileInfo.fileURL)
    }

    static func deleteFiles(_ fileInfos: [CSVFileInfo]) {
        for file in fileInfos {
            try? FileManager.default.removeItem(at: file.fileURL)
        }
    }
}
