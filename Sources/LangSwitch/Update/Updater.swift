import AppKit
import CryptoKit
import LangSwitchCore

/// Where updates come from: the releases of this project on GitHub. These are the only network
/// addresses the application ever talks to, and nothing about the user or their typing is sent — a
/// request carries the application's own version and nothing else.
enum UpdateSource {
    static let repository = "AndySobol/LangSwitch"
    /// The Atom feed of the releases page: unlike the JSON API it has no request quota per address.
    static let releases = URL(string: "https://github.com/\(repository)/releases.atom")

    /// A file is downloaded only from this project's release assets, over HTTPS.
    static func isReleaseAsset(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/\(repository)/releases/download/")
    }

    static func isReleasePage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/\(repository)/releases/")
    }
}

enum UpdateError: Error, Equatable {
    case server(Int)
    case untrustedAddress
    case noChecksum
    case checksumMismatch
    case imageUnreadable
    case notThisApplication
    case badSignature
    /// Everything checked out, but the bundle could not be replaced in place.
    case cannotReplace

    @MainActor var message: String {
        switch self {
        case .server(let status):
            return loc(
                "Сервер обновлений ответил ошибкой \(status).",
                "The update server answered with error \(status).")
        case .untrustedAddress:
            return loc("Обновление лежит по неожиданному адресу.", "The update is at an unexpected address.")
        case .noChecksum:
            return loc("У выпуска нет контрольной суммы.", "The release has no checksum.")
        case .checksumMismatch:
            return loc(
                "Скачанный файл не совпал с контрольной суммой и удалён.",
                "The downloaded file did not match its checksum and was removed.")
        case .imageUnreadable:
            return loc("Образ обновления не открылся.", "The update image could not be opened.")
        case .notThisApplication:
            return loc(
                "В образе не та программа или не та версия.",
                "The image holds a different application or version.")
        case .badSignature:
            return loc("Подпись новой версии повреждена.", "The signature of the new version is broken.")
        case .cannotReplace:
            return loc(
                "Не удалось заменить программу на месте.", "The application could not be replaced in place.")
        }
    }
}

/// Checks for a newer release, downloads it, verifies it and replaces the running application.
@MainActor @Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo)
        case installing(ReleaseInfo)
        /// Downloaded and verified, but the application cannot replace itself where it is; the image
        /// is opened for the user instead.
        case manual(ReleaseInfo, URL)
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var lastCheck: Date?
    let current: AppVersion

    /// Called when an automatic check finds a release.
    @ObservationIgnored var onUpdateFound: ((ReleaseInfo) -> Void)?
    /// Called right before the application is replaced: the last chance to save.
    @ObservationIgnored var willRelaunch: (() async -> Void)?
    @ObservationIgnored private var automatic: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession

    private static let lastCheckKey = "update.lastCheck"
    private static let checkInterval: TimeInterval = 24 * 3600

    init() {
        // LANGSWITCH_PRETEND_VERSION lets a developer see the update flow from an up-to-date build.
        let pretended = ProcessInfo.processInfo.environment["LANGSWITCH_PRETEND_VERSION"]
        let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        current = AppVersion(pretended ?? bundled ?? "") ?? AppVersion("0")!
        lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        // No cookies, no cache, no credentials: every request stands alone.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "LangSwitch/\(current)"]
        session = URLSession(configuration: configuration)
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    /// The release on offer, in whatever stage it is.
    var release: ReleaseInfo? {
        switch state {
        case .available(let release), .downloading(let release), .installing(let release),
            .manual(let release, _):
            release
        default: nil
        }
    }

    /// Puts a release on offer without asking the network; for the snapshot renderer only.
    func showForPreview(_ release: ReleaseInfo) { state = .available(release) }

    /// Looks once a day, while `isEnabled` allows. The task sleeps between looks and costs nothing.
    func startAutomaticChecks(isEnabled: @escaping @MainActor () -> Bool) {
        automatic?.cancel()
        automatic = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                if let self, isEnabled(), !self.isBusy, self.release == nil,
                    self.lastCheck.map({ Date().timeIntervalSince($0) >= Self.checkInterval }) ?? true
                {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(3 * 3600))
            }
        }
    }

    /// Asks the releases page for the latest version. A failed automatic check stays silent.
    func check(userInitiated: Bool) async {
        guard !isBusy, let address = UpdateSource.releases else { return }
        let previous = state
        state = .checking
        do {
            var request = URLRequest(url: address)
            request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw UpdateError.server(status) }
            let releases = try ReleaseFeed.releases(fromAtom: data, repository: UpdateSource.repository)
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
            // A tag appears in the feed before its files are built; a release counts once its
            // checksum list is there and names the disk image.
            var found: ReleaseInfo?
            for candidate in ReleaseFeed.updates(in: releases, newerThan: current).prefix(3) {
                if try await publishedDigest(of: candidate) != nil {
                    found = candidate
                    break
                }
            }
            if let found {
                state = .available(found)
                if !userInitiated { onUpdateFound?(found) }
            } else {
                state = .upToDate
            }
        } catch {
            state = userInitiated ? .failed(Self.describe(error)) : previous
        }
    }

    /// The SHA-256 that the release publishes for its disk image; nil when it is not published (yet).
    private func publishedDigest(of release: ReleaseInfo) async throws -> String? {
        guard UpdateSource.isReleaseAsset(release.checksums), UpdateSource.isReleaseAsset(release.diskImage)
        else {
            throw UpdateError.untrustedAddress
        }
        let (list, response) = try await session.data(from: release.checksums)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ReleaseFeed.checksum(for: release.diskImageName, in: String(decoding: list, as: UTF8.self))
    }

    /// Downloads the release on offer, verifies it, replaces the application and starts the new one.
    func install() async {
        guard !isBusy, let release else { return }
        state = .downloading(release)
        do {
            let image = try await download(release)
            state = .installing(release)
            let destination = Bundle.main.bundleURL
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            let version = release.version
            do {
                try await Task.detached {
                    try UpdateInstaller.install(
                        image: image, expecting: version, bundleID: bundleID, over: destination)
                }.value
            } catch UpdateError.cannotReplace {
                // Read-only location (a translocated or system-wide copy): hand the image to the user.
                state = .manual(release, image)
                NSWorkspace.shared.open(image)
                return
            }
            await willRelaunch?()
            UpdateInstaller.relaunch(destination)
            NSApp.terminate(nil)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    /// Fetches the disk image and checks it against the published SHA-256.
    func download(_ release: ReleaseInfo) async throws -> URL {
        guard let expected = try await publishedDigest(of: release) else { throw UpdateError.noChecksum }
        let (temporary, response) = try await session.download(from: release.diskImage)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.server(status) }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LangSwitch/Updates", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent(release.diskImageName)
        try FileManager.default.moveItem(at: temporary, to: image)
        let digest = try await Task.detached { try UpdateInstaller.sha256(of: image) }.value
        guard digest == expected else {
            try? FileManager.default.removeItem(at: image)
            throw UpdateError.checksumMismatch
        }
        return image
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? UpdateError { return error.message }
        if error is ReleaseFeed.FeedError {
            return loc("Сервер обновлений ответил непонятно.", "The update server sent an unexpected answer.")
        }
        return loc("Нет связи с сервером обновлений.", "The update server could not be reached.")
    }
}

/// The file work of an update. Runs off the main actor; touches nothing but the paths it is given.
enum UpdateInstaller {
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    /// The application inside a mounted image is ours, of the expected version, and intact.
    private static func verify(_ application: URL, version: AppVersion, bundleID: String) throws {
        let info = NSDictionary(contentsOf: application.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID,
            let found = (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
            found == version
        else { throw UpdateError.notThisApplication }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", application.path]) == 0 else {
            throw UpdateError.badSignature
        }
    }

    /// Mounts the image, verifies the application in it and puts it in place of `destination`.
    static func install(image: URL, expecting version: AppVersion, bundleID: String, over destination: URL)
        throws
    {
        let files = FileManager.default
        let mount = files.temporaryDirectory.appendingPathComponent("LangSwitchUpdate-\(UUID().uuidString)")
        try files.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: mount) }
        guard
            run(
                "/usr/bin/hdiutil",
                ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
                == 0
        else { throw UpdateError.imageUnreadable }
        defer { run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let contents = (try? files.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let source = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.imageUnreadable
        }
        try verify(source, version: version, bundleID: bundleID)

        // The copy is made next to the destination, on the same volume, so that the swap is one rename.
        let parent = destination.deletingLastPathComponent()
        guard files.isWritableFile(atPath: parent.path), files.isWritableFile(atPath: destination.path) else {
            throw UpdateError.cannotReplace
        }
        let staging = parent.appendingPathComponent(".LangSwitch-update-\(UUID().uuidString).app")
        guard run("/usr/bin/ditto", [source.path, staging.path]) == 0 else {
            try? files.removeItem(at: staging)
            throw UpdateError.cannotReplace
        }
        do {
            try verify(staging, version: version, bundleID: bundleID)
            _ = try files.replaceItemAt(destination, withItemAt: staging)
        } catch let error as UpdateError {
            try? files.removeItem(at: staging)
            throw error
        } catch {
            try? files.removeItem(at: staging)
            throw UpdateError.cannotReplace
        }
    }

    /// Starts the application at `bundle` as soon as this process has gone.
    static func relaunch(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let script =
            "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        process.arguments = ["-c", script, bundle.path]
        try? process.run()
    }
}
