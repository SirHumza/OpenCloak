import Foundation

public struct DiskImageVolume: Equatable {
    public let device: String
    public let mountPoint: URL?

    public init(device: String, mountPoint: URL?) {
        self.device = device
        self.mountPoint = mountPoint
    }
}

public enum ImageToolError: LocalizedError, Equatable {
    case processFailed(String)
    case invalidCredential
    case busy
    case volumeMissing
    case imageMissing

    public var errorDescription: String? {
        switch self {
        case .processFailed(let detail):
            return detail.isEmpty ? "macOS could not complete the encrypted disk operation." : detail
        case .invalidCredential:
            return "That credential did not open this encrypted image."
        case .busy:
            return "The encrypted image is in use. Close its files and try again."
        case .volumeMissing:
            return "macOS opened the image but did not mount a volume."
        case .imageMissing:
            return "The encrypted image could not be found."
        }
    }
}

public enum FileTreeStats {
    public struct Measurement: Equatable {
        public let files: Int
        public let bytes: Int64

        public init(files: Int, bytes: Int64) {
            self.files = files
            self.bytes = bytes
        }
    }

    public static func measure(_ url: URL) -> Measurement? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard let isDirectory = values?.isDirectory else { return nil }
        if !isDirectory {
            guard let size = values?.fileSize else { return nil }
            return Measurement(files: 1, bytes: Int64(size))
        }
        guard let enumerator = FileManager.default.enumerator(at: url,
                                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                             options: [],
                                                             errorHandler: nil) else { return nil }
        var files = 0
        var bytes: Int64 = 0
        for case let child as URL in enumerator {
            guard let childValues = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  childValues.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(childValues.fileSize ?? 0)
        }
        return Measurement(files: files, bytes: bytes)
    }

    public static func matches(_ left: URL, _ right: URL) -> Bool {
        guard let a = measure(left), let b = measure(right) else { return false }
        return a == b
    }
}

/// A thin, argument-array-only wrapper around `hdiutil`. Secrets go through `-stdinpass`; no shell
/// is ever involved.
public enum ImageTool {
    private struct ProcessResult {
        let status: Int32
        let standardOutput: Data
        let standardError: String
    }

    private static let ignoreSIGPIPE: Void = {
        _ = signal(SIGPIPE, SIG_IGN)
    }()

    public static func create(at url: URL, volumeName: String, size: String, credential: String) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ImageToolError.processFailed("An encrypted image already exists at this location.")
        }
        let result: ProcessResult
        do {
            result = try run(arguments: ["create", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                                         "-size", size, "-encryption", "AES-256", "-stdinpass",
                                         "-volname", volumeName, "-o", url.path], secret: credential)
        } catch {
            throw ImageToolError.processFailed("The disk-image tool could not be started.")
        }
        guard result.status == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw ImageToolError.processFailed(condense(result.standardError))
        }
    }

    public static func attach(_ url: URL, credential: String) throws -> DiskImageVolume {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ImageToolError.imageMissing }
        let result: ProcessResult
        do {
            result = try run(arguments: ["attach", "-plist", "-nobrowse", "-noautoopen", "-stdinpass", url.path],
                             secret: credential)
        } catch {
            throw ImageToolError.processFailed("The disk-image tool could not be started.")
        }
        guard result.status == 0 else {
            let text = result.standardError.lowercased()
            if text.contains("authentication error") || text.contains("incorrect") || text.contains("wrong password") {
                throw ImageToolError.invalidCredential
            }
            if text.contains("busy") || text.contains("in use") {
                throw ImageToolError.busy
            }
            throw ImageToolError.processFailed(condense(result.standardError))
        }
        guard let volume = volumes(from: result.standardOutput, imagePath: url.path).first else {
            throw ImageToolError.volumeMissing
        }
        return volume
    }

    public static func detach(device: String) throws {
        let result = try run(arguments: ["detach", device])
        guard result.status == 0 else {
            let text = result.standardError.lowercased()
            if text.contains("busy") || text.contains("in use") {
                throw ImageToolError.busy
            }
            throw ImageToolError.processFailed(condense(result.standardError))
        }
    }

    public static func detachAll(ofImageAt url: URL) throws {
        for volume in mountedVolumes(forImageAt: url) {
            try detach(device: volume.device)
        }
    }

    public static func mountedVolumes(forImageAt url: URL) -> [DiskImageVolume] {
        guard let result = try? run(arguments: ["info", "-plist"]), result.status == 0 else { return [] }
        return volumes(from: result.standardOutput, imagePath: url.path)
    }

    public static func isEncrypted(_ url: URL) -> Bool {
        guard let result = try? run(arguments: ["isencrypted", url.path]), result.status == 0 else { return false }
        let answer = String(data: result.standardOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return answer == "yes" || answer == "true" || answer == "1"
    }

    public static func imagePath(forMountPoint path: String) -> String? {
        guard let result = try? run(arguments: ["info", "-plist"]), result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.standardOutput, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        for image in images {
            guard let imagePath = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            if entities.contains(where: { ($0["mount-point"] as? String) == path }) {
                return imagePath
            }
        }
        return nil
    }

    // MARK: - Internals

    private static func volumes(from data: Data, imagePath: String) -> [DiskImageVolume] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        let target = URL(fileURLWithPath: imagePath).standardizedFileURL.path
        var result: [DiskImageVolume] = []
        for image in images {
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).standardizedFileURL.path == target,
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities {
                guard let device = entity["dev-entry"] as? String,
                      let mountPoint = entity["mount-point"] as? String else { continue }
                result.append(DiskImageVolume(device: device, mountPoint: URL(fileURLWithPath: mountPoint, isDirectory: true)))
            }
        }
        return result
    }

    private static func condense(_ standardError: String) -> String {
        let condensed = standardError
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .replacingOccurrences(of: "hdiutil: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return condensed.isEmpty ? "macOS could not complete the encrypted disk operation." : String(condensed.prefix(180))
    }

    private static func run(arguments: [String], secret: String? = nil) throws -> ProcessResult {
        _ = ignoreSIGPIPE
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        do { try process.run() }
        catch { throw ImageToolError.processFailed("The disk-image tool could not be started.") }

        let input = standardInput.fileHandleForWriting
        if let secret {
            var payload = Data(secret.utf8)
            payload.append(0)
            DispatchQueue.global(qos: .userInitiated).async {
                try? input.write(contentsOf: payload)
                try? input.close()
            }
        } else {
            try? input.close()
        }

        let group = DispatchGroup()
        var outputData = Data()
        var errorData = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()

        return ProcessResult(status: process.terminationStatus,
                             standardOutput: outputData,
                             standardError: String(data: errorData, encoding: .utf8) ?? "")
    }
}
