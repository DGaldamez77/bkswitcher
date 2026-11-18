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

    enum CodingKeys: String, CodingKey {
        case assetLocalIdentifier
        case originalFilename
        case exportedFilename
        case photoTakenDate
        case photoLocationText
        case libraryUrl
    }

    /// Photos asset identifiers look like `<UUID>/L0/001`; only the leading UUID is meaningful to
    /// the `photos://` URL handler.
    var photosAssetUUID: String {
        assetLocalIdentifier.split(separator: "/").first.map(String.init) ?? assetLocalIdentifier
    }

    /// Deep link that opens this photo in the macOS Photos app. Derived rather than stored so it
    /// stays correct even for manifests written before this field existed.
    var libraryUrl: URL? {
        var components = URLComponents()
        components.scheme = "photos"
        components.host = "asset"
        components.queryItems = [URLQueryItem(name: "identifier", value: photosAssetUUID)]
        return components.url
    }

    init(
        assetLocalIdentifier: String,
        originalFilename: String,
        exportedFilename: String,
        photoTakenDate: Date?,
        photoLocationText: String?
    ) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.originalFilename = originalFilename
        self.exportedFilename = exportedFilename
        self.photoTakenDate = photoTakenDate
        self.photoLocationText = photoLocationText
    }

    /// `libraryUrl` is written for convenience but ignored when reading, so manifests that predate
    /// the field still decode and recreate correctly.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetLocalIdentifier = try container.decode(String.self, forKey: .assetLocalIdentifier)
        originalFilename = try container.decode(String.self, forKey: .originalFilename)
        exportedFilename = try container.decode(String.self, forKey: .exportedFilename)
        photoTakenDate = try container.decodeIfPresent(Date.self, forKey: .photoTakenDate)
        photoLocationText = try container.decodeIfPresent(String.self, forKey: .photoLocationText)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(assetLocalIdentifier, forKey: .assetLocalIdentifier)
        try container.encode(originalFilename, forKey: .originalFilename)
        try container.encode(exportedFilename, forKey: .exportedFilename)
        try container.encodeIfPresent(photoTakenDate, forKey: .photoTakenDate)
        try container.encodeIfPresent(photoLocationText, forKey: .photoLocationText)
        try container.encodeIfPresent(libraryUrl, forKey: .libraryUrl)
    }
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
    let pictureMarginPixels: Double
    let useOptimalLayout: Bool
    let photos: [RunManifestPhoto]

    static let filenameSuffix = "-run.json"

    enum CodingKeys: String, CodingKey {
        case stamp
        case generatedAt
        case canvasWidth
        case canvasHeight
        case tileGap
        case layoutSeed
        case pictureMarginPixels
        case useOptimalLayout
        case photos
    }

    var canvasSize: CGSize {
        CGSize(width: canvasWidth, height: canvasHeight)
    }

    static func url(in directory: URL, stamp: String) -> URL {
        directory.appendingPathComponent("wallpaper-\(stamp)\(filenameSuffix)")
    }

    init(
        stamp: String,
        generatedAt: Date,
        canvasWidth: Double,
        canvasHeight: Double,
        tileGap: Double,
        layoutSeed: UInt64,
        pictureMarginPixels: Double,
        useOptimalLayout: Bool,
        photos: [RunManifestPhoto]
    ) {
        self.stamp = stamp
        self.generatedAt = generatedAt
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.tileGap = tileGap
        self.layoutSeed = layoutSeed
        self.pictureMarginPixels = pictureMarginPixels
        self.useOptimalLayout = useOptimalLayout
        self.photos = photos
    }

    /// `pictureMarginPixels`/`useOptimalLayout` are read with fallbacks so manifests written before
    /// the optimal layout existed still decode (as the legacy mosaic layout with a 10px margin).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stamp = try container.decode(String.self, forKey: .stamp)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        canvasWidth = try container.decode(Double.self, forKey: .canvasWidth)
        canvasHeight = try container.decode(Double.self, forKey: .canvasHeight)
        tileGap = try container.decode(Double.self, forKey: .tileGap)
        layoutSeed = try container.decode(UInt64.self, forKey: .layoutSeed)
        pictureMarginPixels = try container.decodeIfPresent(Double.self, forKey: .pictureMarginPixels) ?? 10
        useOptimalLayout = try container.decodeIfPresent(Bool.self, forKey: .useOptimalLayout) ?? false
        photos = try container.decode([RunManifestPhoto].self, forKey: .photos)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stamp, forKey: .stamp)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(canvasWidth, forKey: .canvasWidth)
        try container.encode(canvasHeight, forKey: .canvasHeight)
        try container.encode(tileGap, forKey: .tileGap)
        try container.encode(layoutSeed, forKey: .layoutSeed)
        try container.encode(pictureMarginPixels, forKey: .pictureMarginPixels)
        try container.encode(useOptimalLayout, forKey: .useOptimalLayout)
        try container.encode(photos, forKey: .photos)
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
