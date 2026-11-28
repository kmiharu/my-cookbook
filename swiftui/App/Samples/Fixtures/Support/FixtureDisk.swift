import Foundation

/// Each sample owns a file and a size limit. The actor serializes read-modify-write.
actor FixtureDisk<Value: Codable & Sendable> {
    enum StorageError: Error {
        case fileTooLarge
    }

    private let fileName: String
    private let initialValue: Value
    private let byteLimit: Int
    private let customDirectory: URL?

    init(_ fileName: String, initial: Value, byteLimit: Int = 4_500_000, directory: URL? = nil) {
        self.fileName = fileName
        self.initialValue = initial
        self.byteLimit = byteLimit
        self.customDirectory = directory
    }

    func read() throws -> Value {
        let url = try fileURL()
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
            guard data.count <= byteLimit else { throw StorageError.fileTooLarge }
            return try JSONDecoder().decode(Value.self, from: data)
        } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            return initialValue
        }
    }

    @discardableResult
    func update(_ edit: @Sendable (inout Value) throws -> Void) throws -> Value {
        var updated = try read()
        try edit(&updated)
        let data = try JSONEncoder().encode(updated)
        guard data.count <= byteLimit else { throw StorageError.fileTooLarge }
        let url = try fileURL()
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        return updated
    }

    private func fileURL() throws -> URL {
        if let customDirectory { return customDirectory.appending(path: fileName) }
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appending(path: "FixtureSamples", directoryHint: .isDirectory).appending(path: fileName)
    }
}
