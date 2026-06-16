import Foundation

enum AppConfigError: LocalizedError {
    case templateCreated(URL)
    case invalidConfig(String)

    var errorDescription: String? {
        switch self {
        case .templateCreated(let url):
            return "Created config template at \(url.path). Optionally set excludedAlbums/imageCount/tileGap, then run bkswitcher again."
        case .invalidConfig(let message):
            return "Invalid config: \(message)"
        }
    }
}

struct AppConfig: Codable {
    var excludedAlbums: [String]
    var imageCount: Int
    var tileGap: Double
    var outputDirectory: String
    var refreshIntervalMinutes: Int
    var allowedExtensions: [String]

    static let configDirectoryName = "BKSwitcher"
    static let configFileName = "config.json"

    enum CodingKeys: String, CodingKey {
        case excludedAlbums
        case excludedFolders
        case imageCount
        case tileGap
        case rows
        case columns
        case outputDirectory
        case refreshIntervalMinutes
        case allowedExtensions
    }

    static var defaultValue: AppConfig {
        AppConfig(
            excludedAlbums: [],
            imageCount: 12,
            tileGap: 6,
            outputDirectory: "~/Library/Caches/BKSwitcher",
            refreshIntervalMinutes: 15,
            allowedExtensions: ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]
        )
    }

    static var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(configDirectoryName, isDirectory: true)
            .appendingPathComponent(configFileName, isDirectory: false)
    }

    static func initializeTemplate(overwrite: Bool = false) throws -> URL {
        let destination = configURL
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destination.path), !overwrite {
            return destination
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(defaultValue)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func load() throws -> AppConfig {
        let url = configURL

        guard FileManager.default.fileExists(atPath: url.path) else {
            let templateURL = try initializeTemplate(overwrite: false)
            throw AppConfigError.templateCreated(templateURL)
        }

        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        try config.validate()
        return config
    }

    func normalizedExcludedAlbumNames() -> [String] {
        excludedAlbums
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func resolvedOutputDirectoryURL() -> URL {
        URL(fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath, isDirectory: true)
    }

    func allowedExtensionSet() -> Set<String> {
        Set(
            allowedExtensions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    private func validate() throws {
        guard imageCount > 0 else {
            throw AppConfigError.invalidConfig("imageCount must be greater than zero.")
        }
        guard tileGap >= 0 else {
            throw AppConfigError.invalidConfig("tileGap cannot be negative.")
        }
        guard refreshIntervalMinutes > 0 else {
            throw AppConfigError.invalidConfig("refreshIntervalMinutes must be greater than zero.")
        }
        guard !allowedExtensionSet().isEmpty else {
            throw AppConfigError.invalidConfig("allowedExtensions cannot be empty.")
        }
    }
}

extension AppConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excludedAlbums =
            try container.decodeIfPresent([String].self, forKey: .excludedAlbums)
            ?? container.decodeIfPresent([String].self, forKey: .excludedFolders)
            ?? []

        if let explicitImageCount = try container.decodeIfPresent(Int.self, forKey: .imageCount) {
            imageCount = explicitImageCount
        } else {
            let legacyRows = try container.decodeIfPresent(Int.self, forKey: .rows)
            let legacyColumns = try container.decodeIfPresent(Int.self, forKey: .columns)
            if let legacyRows, let legacyColumns, legacyRows > 0, legacyColumns > 0 {
                imageCount = legacyRows * legacyColumns
            } else {
                imageCount = 12
            }
        }

        tileGap = try container.decodeIfPresent(Double.self, forKey: .tileGap) ?? 6
        outputDirectory = try container.decode(String.self, forKey: .outputDirectory)
        refreshIntervalMinutes = try container.decode(Int.self, forKey: .refreshIntervalMinutes)
        allowedExtensions = try container.decode([String].self, forKey: .allowedExtensions)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(excludedAlbums, forKey: .excludedAlbums)
        try container.encode(imageCount, forKey: .imageCount)
        try container.encode(tileGap, forKey: .tileGap)
        try container.encode(outputDirectory, forKey: .outputDirectory)
        try container.encode(refreshIntervalMinutes, forKey: .refreshIntervalMinutes)
        try container.encode(allowedExtensions, forKey: .allowedExtensions)
    }
}
