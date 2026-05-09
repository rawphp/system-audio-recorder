import Foundation
import Observation

// MARK: - BitrateMode (UserDefaults serialisation helpers)
//
// `BitrateMode` is declared in `LameEncoder.swift` as a plain enum.
// Here we add the conformances needed for UserDefaults round-trip and equality tests.

extension BitrateMode: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "VBR": self = .vbr
        case "CBR": self = .cbr
        default:    return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .vbr: return "VBR"
        case .cbr: return "CBR"
        }
    }
}

extension BitrateMode: Equatable {}

// MARK: - OutputMode
//
// `SessionConfig.OutputMode` is a nested type. We define a flat `AppOutputMode`
// that maps to the same concept but can be stored in UserDefaults independently
// of the session layer.

/// Whether the encoder produces one mixed-down file or separate per-source files.
///
/// This is the settings-layer equivalent of `SessionConfig.OutputMode`. It is
/// stored in UserDefaults under the `outputMode` key (spec §6.2) and converted
/// to `SessionConfig.OutputMode` when building a `SessionConfig`.
public enum AppOutputMode: String, Equatable, CaseIterable, Sendable {
    /// All sources mixed into one stereo MP3.
    case mixed = "mixed"
    /// One MP3 per source (N apps + optionally mic).
    case separate = "separate"
}

// MARK: - SettingsError

/// Errors surfaced by `AppSettings`.
///
/// REQ-033 (`ErrorSurface`) will observe `AppSettings.lastBookmarkError` and
/// `AppSettings.lastFolderCreationError` to display non-fatal banners.
public enum SettingsError: Error, Equatable {
    /// The security-scoped bookmark stored for the output folder is stale or
    /// could not be resolved (folder deleted/moved/unmounted).
    ///
    /// When this is set, `outputFolderURL` returns `nil`. The user must
    /// re-pick a folder before recording can proceed.
    case outputFolderUnavailable

    /// The default output folder (`~/Music/Recordings`) could not be created.
    /// `AppSettings` fell back to `NSTemporaryDirectory()/Recordings` and stored
    /// a fresh bookmark for that location.
    case outputFolderFallback(URL)
}

// MARK: - BookmarkProvider (test seam)

/// Abstracts the security-scoped bookmark API for testability.
///
/// The production implementation calls `URL.bookmarkData(options:.withSecurityScope)`,
/// which requires an actual on-disk file and a signed entitlement. Tests inject a
/// `StubBookmarkProvider` that avoids those requirements.
public protocol BookmarkProvider: AnyObject {
    /// Create and return bookmark data for the given URL.
    /// - Throws: Any `URL.bookmarkData` error (e.g. file does not exist).
    func store(url: URL) throws -> Data

    /// Resolve previously stored bookmark data back to a URL.
    /// - Throws: Any `URL(resolvingBookmarkData:...)` error (e.g. stale bookmark).
    func resolve(data: Data) throws -> URL
}

// MARK: - SecurityScopedBookmarkProvider (production)

/// Production implementation of `BookmarkProvider` using the real security-scoped
/// bookmark API.
///
/// Requires the `com.apple.security.security-scoped-bookmarks` (or equivalent)
/// entitlement and a real on-disk URL.
public final class SecurityScopedBookmarkProvider: BookmarkProvider {
    public init() {}

    public func store(url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolve(data: Data) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            // A stale bookmark can still be resolved but should be refreshed.
            // Treat as success; the caller can refresh if desired.
        }
        return url
    }
}

// MARK: - FolderCreating (test seam)

/// Abstracts directory creation for testability.
public protocol FolderCreating {
    func createDirectory(at url: URL) throws
}

// MARK: - FileManagerFolderCreator (production)

/// Production implementation that delegates to `FileManager`.
public struct FileManagerFolderCreator: FolderCreating {
    public init() {}

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}

// MARK: - AppSettings

/// `@Observable` settings store backed by a `UserDefaults` suite.
///
/// All keys follow spec §6.2. Inject a custom `UserDefaults` suite name and
/// a `StubBookmarkProvider` in tests to avoid touching the real suite or the
/// security-scoped bookmark API.
///
/// ## Thread safety
/// `AppSettings` is `@MainActor` so all property reads/writes are serialised
/// on the main thread. `@Observable` change notifications are delivered on the
/// main actor.
///
/// ## Output folder bookmark lifecycle
/// 1. First launch: `resolvedOutputFolder()` creates `~/Music/Recordings`
///    (or a temp fallback), stores a security-scoped bookmark, and returns the URL.
/// 2. Subsequent launches: `outputFolderURL` resolves the persisted bookmark.
///    If stale, it returns `nil` and sets `lastBookmarkError`.
///
/// ## Error surface
/// REQ-033 (`ErrorSurface`) observes `lastBookmarkError` and
/// `lastFolderCreationError` to display non-fatal banners.
@Observable
@MainActor
public final class AppSettings {

    // MARK: - Keys namespace

    /// Canonical UserDefaults key strings for spec §6.2.
    public enum Keys {
        public static let outputFolderBookmark   = "outputFolderBookmark"
        public static let bitrate                = "bitrate"
        public static let bitrateMode            = "bitrateMode"
        public static let outputMode             = "outputMode"
        public static let keepWAVAfterEncode     = "keepWAVAfterEncode"
        public static let hotkey                 = "hotkey"
        public static let lastSourcePreset       = "lastSourcePreset"
        public static let micDeviceID            = "micDeviceID"
        public static let showInDock             = "showInDock"
        public static let autoStopDurationSeconds = "autoStopDurationSeconds"
        public static let autoStopSilenceSeconds  = "autoStopSilenceSeconds"
    }

    // MARK: - Private storage

    private let defaults: UserDefaults
    private let bookmarkProvider: BookmarkProvider
    private let folderCreator: FolderCreating

    // MARK: - Observable persisted properties

    /// Encoding target bitrate in kbps. Default: 192.
    public var bitrate: Int {
        get {
            let stored = defaults.integer(forKey: Keys.bitrate)
            return stored == 0 ? 192 : stored
        }
        set { defaults.set(newValue, forKey: Keys.bitrate) }
    }

    /// VBR or CBR encoding mode. Default: `.vbr`.
    public var bitrateMode: BitrateMode {
        get {
            guard let raw = defaults.string(forKey: Keys.bitrateMode),
                  let mode = BitrateMode(rawValue: raw) else { return .vbr }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.bitrateMode) }
    }

    /// Mixed or separate output files. Default: `.mixed`.
    public var outputMode: AppOutputMode {
        get {
            guard let raw = defaults.string(forKey: Keys.outputMode),
                  let mode = AppOutputMode(rawValue: raw) else { return .mixed }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.outputMode) }
    }

    /// Whether to delete the source WAV after successful MP3 encoding. Default: false.
    public var keepWAVAfterEncode: Bool {
        get {
            // UserDefaults.bool returns false for missing keys — correct default.
            return defaults.bool(forKey: Keys.keepWAVAfterEncode)
        }
        set { defaults.set(newValue, forKey: Keys.keepWAVAfterEncode) }
    }

    /// The user's chosen global hotkey shortcut identifier. Default: nil (unset).
    public var hotkey: String? {
        get { defaults.string(forKey: Keys.hotkey) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: Keys.hotkey)
            } else {
                defaults.removeObject(forKey: Keys.hotkey)
            }
        }
    }

    /// The name of the most-recently used source preset. Default: "Everything".
    public var lastSourcePreset: String {
        get { defaults.string(forKey: Keys.lastSourcePreset) ?? "Everything" }
        set { defaults.set(newValue, forKey: Keys.lastSourcePreset) }
    }

    /// The persistent identifier of the user's chosen microphone. `nil` = system default.
    public var micDeviceID: String? {
        get { defaults.string(forKey: Keys.micDeviceID) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: Keys.micDeviceID)
            } else {
                defaults.removeObject(forKey: Keys.micDeviceID)
            }
        }
    }

    /// Whether the app shows in the Dock while running. Default: true.
    public var showInDock: Bool {
        get {
            // UserDefaults.bool returns false for missing keys, but the default is true.
            // We use object(forKey:) to distinguish "not set" from "explicitly set to false".
            if defaults.object(forKey: Keys.showInDock) == nil { return true }
            return defaults.bool(forKey: Keys.showInDock)
        }
        set { defaults.set(newValue, forKey: Keys.showInDock) }
    }

    /// Duration in seconds after which recording auto-stops. `nil` = disabled.
    public var autoStopDurationSeconds: Double? {
        get {
            guard defaults.object(forKey: Keys.autoStopDurationSeconds) != nil else { return nil }
            let value = defaults.double(forKey: Keys.autoStopDurationSeconds)
            return value == 0 ? nil : value
        }
        set {
            if let value = newValue {
                defaults.set(value, forKey: Keys.autoStopDurationSeconds)
            } else {
                defaults.removeObject(forKey: Keys.autoStopDurationSeconds)
            }
        }
    }

    /// Silence duration in seconds after which recording auto-stops. `nil` = disabled.
    public var autoStopSilenceSeconds: Double? {
        get {
            guard defaults.object(forKey: Keys.autoStopSilenceSeconds) != nil else { return nil }
            let value = defaults.double(forKey: Keys.autoStopSilenceSeconds)
            return value == 0 ? nil : value
        }
        set {
            if let value = newValue {
                defaults.set(value, forKey: Keys.autoStopSilenceSeconds)
            } else {
                defaults.removeObject(forKey: Keys.autoStopSilenceSeconds)
            }
        }
    }

    // MARK: - Observable error surfaces (for REQ-033)

    /// Set when the persisted output-folder bookmark fails to resolve.
    ///
    /// REQ-033 (`ErrorSurface`) will observe this to present a non-fatal banner
    /// prompting the user to re-pick a folder.
    public private(set) var lastBookmarkError: SettingsError?

    /// Set when the default output folder (`~/Music/Recordings`) could not be created.
    ///
    /// REQ-033 (`ErrorSurface`) will observe this to present a non-fatal banner
    /// explaining the fallback to `NSTemporaryDirectory`.
    public private(set) var lastFolderCreationError: SettingsError?

    // MARK: - Output folder URL (security-scoped bookmark)

    /// Resolve the stored security-scoped bookmark to a URL.
    ///
    /// Returns `nil` if no bookmark has been stored yet, or if the stored bookmark
    /// is stale (folder deleted / moved / unmounted). In the stale case,
    /// `lastBookmarkError` is set to `.outputFolderUnavailable`.
    public var outputFolderURL: URL? {
        guard let data = defaults.data(forKey: Keys.outputFolderBookmark) else {
            return nil
        }
        do {
            let url = try bookmarkProvider.resolve(data: data)
            lastBookmarkError = nil
            return url
        } catch {
            lastBookmarkError = .outputFolderUnavailable
            return nil
        }
    }

    /// Store a new security-scoped bookmark for `url`.
    ///
    /// Overwrites the previously stored bookmark. Subsequent accesses to
    /// `outputFolderURL` will resolve this new bookmark.
    ///
    /// - Parameter url: The folder URL to bookmark. Must exist on disk for
    ///   the production `SecurityScopedBookmarkProvider` to succeed.
    public func setOutputFolder(_ url: URL) {
        do {
            let data = try bookmarkProvider.store(url: url)
            defaults.set(data, forKey: Keys.outputFolderBookmark)
        } catch {
            // If bookmark creation fails, we leave the previous bookmark in place.
            // The caller can check outputFolderURL to detect the issue.
        }
    }

    /// Resolve the output folder, creating the default if needed.
    ///
    /// Call this on first launch (or whenever `outputFolderURL` returns `nil`)
    /// to ensure a valid output folder is ready. The resolved URL is also stored
    /// as a fresh bookmark.
    ///
    /// - Returns: The resolved output folder URL, or the temp fallback URL.
    @discardableResult
    public func resolvedOutputFolder() -> URL? {
        // If we have a valid stored bookmark, use it.
        if let existing = outputFolderURL {
            return existing
        }

        // Try to create ~/Music/Recordings.
        let primaryURL = defaultOutputFolderURL
        do {
            try folderCreator.createDirectory(at: primaryURL)
            setOutputFolder(primaryURL)
            lastFolderCreationError = nil
            return primaryURL
        } catch {
            // Fall back to NSTemporaryDirectory/Recordings.
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Recordings")
            do {
                try folderCreator.createDirectory(at: tempURL)
                setOutputFolder(tempURL)
                lastFolderCreationError = .outputFolderFallback(tempURL)
                return tempURL
            } catch {
                lastFolderCreationError = .outputFolderFallback(tempURL)
                return tempURL
            }
        }
    }

    // MARK: - Computed helpers

    /// The canonical default output folder URL: `~/Music/Recordings`.
    ///
    /// This URL is used on first launch when no bookmark has been stored.
    /// Exposed as `public` so tests can assert against it without needing
    /// to hit the filesystem.
    public var defaultOutputFolderURL: URL {
        let musicDir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
        return musicDir.appendingPathComponent("Recordings")
    }

    // MARK: - Initialisation

    /// Production initialiser — uses the real UserDefaults suite and the
    /// security-scoped bookmark API.
    public convenience init() {
        let defaults = UserDefaults(suiteName: "com.tomkaczocha.SystemAudioRecorder")!
        self.init(
            defaults: defaults,
            bookmarkProvider: SecurityScopedBookmarkProvider(),
            folderCreator: FileManagerFolderCreator()
        )
    }

    /// Designated initialiser with injectable seams for testing.
    ///
    /// - Parameters:
    ///   - defaults: A `UserDefaults` instance. Pass a test suite to avoid
    ///     touching the production suite.
    ///   - bookmarkProvider: Provide a `StubBookmarkProvider` in tests to avoid
    ///     real security-scoped bookmark API calls.
    ///   - folderCreator: Provide a `FailingFolderCreator` in tests to simulate
    ///     permission-denied failures.
    public init(
        defaults: UserDefaults,
        bookmarkProvider: BookmarkProvider,
        folderCreator: FolderCreating = FileManagerFolderCreator()
    ) {
        self.defaults = defaults
        self.bookmarkProvider = bookmarkProvider
        self.folderCreator = folderCreator
    }
}
