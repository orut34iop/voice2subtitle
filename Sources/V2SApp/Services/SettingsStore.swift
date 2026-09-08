import Foundation

@MainActor
final class SettingsStore {
    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "com.franklioxygen.v2s.settings", qos: .utility)
    private var pendingSettings: AppSettings?
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = root.appendingPathComponent("v2s/settings.json")
        }
    }

    func load() -> AppSettings {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileReadNoSuchFileError {
                fputs("Failed to load settings: \(error)\n", stderr)
                // Preserve the original before defaults can overwrite a damaged file.
                let backup = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
                try? FileManager.default.copyItem(at: fileURL, to: backup)
            }
            return .default
        }
    }

    /// Slider events only replace a memory snapshot. Encode and write once after the gesture settles.
    func save(_ settings: AppSettings) {
        pendingSettings = settings
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            self?.submitPendingSave()
        }
    }

    private func takePendingData() -> Data? {
        guard let settings = pendingSettings else { return nil }
        pendingSettings = nil
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(settings)
        } catch {
            fputs("Failed to encode settings: \(error)\n", stderr)
            return nil
        }
    }

    private func submitPendingSave() {
        saveTask = nil
        guard let data = takePendingData() else { return }
        let fileURL = self.fileURL
        writeQueue.async { Self.write(data, to: fileURL) }
    }

    /// Used at termination so the last gesture and all earlier queued writes reach disk in order.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        let data = takePendingData()
        let fileURL = self.fileURL
        writeQueue.sync {
            if let data { Self.write(data, to: fileURL) }
        }
    }

    nonisolated private static func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: nil)
            try data.write(to: url, options: .atomic)
        } catch {
            fputs("Failed to save settings: \(error)\n", stderr)
        }
    }
}
