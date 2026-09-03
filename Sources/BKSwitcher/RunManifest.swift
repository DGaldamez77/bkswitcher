import Foundation

enum RunManifestError: LocalizedError {
    case noPreviousRun(URL)
    case emptyManifest(String)

    var errorDescription: String? {
        switch self {
        case .noPreviousRun(let directory):
            return "No previous run manifest found in \(directory.path). Run `bkswitcher` once before using --recreate."
        case .emptyManifest(let stamp):
            return "Previous run manifest \(stamp) records no photos, so there is nothing to recreate."
        }
    }
}

/// One photo used by a run, recorded so the run can be reproduced later.
struct RunManifestPhoto: Codable {
    let assetLocalIdentifier: String
    let originalFilename: String
    /// Filename inside `used-photos/<stamp>/`, kept relative so the cache directory can move.
    let exportedFilename: String
    let photoTakenDate: Date?
    let photoLocationText: String?
}

/// Everything needed to redraw a previous collage byte-for-byte: the photo set, their order, the
/// layout seed, and the geometry the collage was rendered with.
struct RunManifest: Codable {
    let stamp: String
    let generatedAt: Date
    let canvasWidth: Double
    let canvasHeight: Double
    let tileGap: Double
    let layoutSeed: UInt64
    let photos: [RunManifestPhoto]

    static let filenameSuffix = "-run.json"

    var canvasSize: CGSize {
        CGSize(width: canvasWidth, height: canvasHeight)
    }

    static func url(in directory: URL, stamp: String) -> URL {
        directory.appendingPathComponent("wallpaper-\(stamp)\(filenameSuffix)")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func write(in directory: URL) throws -> URL {
        let destination = RunManifest.url(in: directory, stamp: stamp)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RunManifest.encoder.encode(self).write(to: destination, options: .atomic)
        return destination
    }

    /// Loads the most recent decodable manifest. Manifests are scanned newest-first by recorded
    /// `generatedAt` so a corrupt or partially written file falls through to the prior run instead
    /// of failing the whole command.
    static func loadLatest(in directory: URL) throws -> RunManifest {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            throw RunManifestError.noPreviousRun(directory)
        }

        let manifests = entries
            .filter { $0.lastPathComponent.hasSuffix(filenameSuffix) }
            .compactMap { url -> RunManifest? in
                guard let data = try? Data(contentsOf: url) else {
                    return nil
                }
                return try? decoder.decode(RunManifest.self, from: data)
            }
            .sorted { $0.generatedAt > $1.generatedAt }

        guard let latest = manifests.first else {
            throw RunManifestError.noPreviousRun(directory)
        }
        guard !latest.photos.isEmpty else {
            throw RunManifestError.emptyManifest(latest.stamp)
        }
        return latest
    }
}
