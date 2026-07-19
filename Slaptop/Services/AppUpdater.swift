// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import AppKit
import Foundation
import Security

enum UpdateCheckFrequency: String, CaseIterable {
    case daily
    case weekly
    case manual

    static let key = "update.checkFrequency"

    var label: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .manual: return "Manually"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .daily: return 86_400
        case .weekly: return 604_800
        case .manual: return nil
        }
    }
}

enum AppUpdateError: LocalizedError {
    case checkFailed(String)
    case downloadFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case let .checkFailed(detail): return "Update check failed: \(detail)"
        case let .downloadFailed(detail): return "Update download failed: \(detail)"
        case let .installFailed(detail): return "Update installation failed: \(detail)"
        }
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case availableButNotInstallable(tag: String)
        case downloading(tag: String)
        case installing(tag: String)
        case failed(String)
    }

    struct Release {
        let tag: String
        let buildNumber: Int
        let dmgURL: URL
    }

    nonisolated static let repository = "AM-Guru/Slaptop"
    private static let lastCheckedKey = "update.lastCheckedAt"
    /// Automatic checks are evaluated hourly against the chosen frequency, so
    /// a due check runs soon after wake or launch rather than exactly on the
    /// daily/weekly boundary.
    private static let automaticEvaluationInterval: TimeInterval = 3_600
    private static let launchEvaluationDelay: TimeInterval = 15

    @Published var frequency: UpdateCheckFrequency {
        didSet { defaults.set(frequency.rawValue, forKey: UpdateCheckFrequency.key) }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheckedAt: Date?

    private let defaults: UserDefaults
    private var automaticCheckTimer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        frequency = UpdateCheckFrequency(
            rawValue: defaults.string(forKey: UpdateCheckFrequency.key) ?? ""
        ) ?? .daily
        lastCheckedAt = defaults.object(forKey: Self.lastCheckedKey) as? Date
    }

    var statusDescription: String {
        switch phase {
        case .idle:
            guard let lastCheckedAt else { return "Updates have not been checked yet." }
            return "Last checked \(Self.relativeDescription(of: lastCheckedAt))."
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "Slaptop is up to date (build \(Self.currentBuildNumber))."
        case let .availableButNotInstallable(tag):
            return "Update \(tag) is available. Install Slaptop in /Applications to update automatically."
        case let .downloading(tag):
            return "Downloading Slaptop \(tag)…"
        case let .installing(tag):
            return "Installing Slaptop \(tag)… Slaptop will relaunch."
        case let .failed(message):
            return message
        }
    }

    func startAutomaticChecks() {
        automaticCheckTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.automaticEvaluationInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdatesIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        automaticCheckTimer = timer

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchEvaluationDelay) { [weak self] in
            self?.checkForUpdatesIfDue()
        }
    }

    func checkForUpdatesIfDue() {
        guard Self.isAutomaticCheckDue(
            frequency: frequency,
            lastCheckedAt: lastCheckedAt,
            now: Date()
        ) else { return }
        checkForUpdates()
    }

    /// Manual and automatic entry point: checks the latest GitHub release and,
    /// when it is newer and Slaptop runs from /Applications, downloads,
    /// verifies, installs, and relaunches.
    func checkForUpdates() {
        switch phase {
        case .checking, .downloading, .installing: return
        default: break
        }
        phase = .checking
        Task { await performCheckAndInstall() }
    }

    nonisolated static func isAutomaticCheckDue(
        frequency: UpdateCheckFrequency,
        lastCheckedAt: Date?,
        now: Date
    ) -> Bool {
        guard let interval = frequency.interval else { return false }
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= interval
    }

    /// Release tags are produced by CI as "v<version>-build.<run number>", so
    /// the trailing run number is the monotonic comparison key.
    nonisolated static func buildNumber(fromTag tag: String) -> Int? {
        guard let range = tag.range(of: "build.", options: .backwards) else { return nil }
        let digits = tag[range.upperBound...]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    nonisolated static var currentBuildNumber: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    private func performCheckAndInstall() async {
        defer {
            lastCheckedAt = Date()
            defaults.set(lastCheckedAt, forKey: Self.lastCheckedKey)
        }

        do {
            let release = try await Self.fetchLatestRelease()
            guard release.buildNumber > Self.currentBuildNumber else {
                phase = .upToDate
                return
            }
            guard MissionControlController.isInstalledApplication else {
                phase = .availableButNotInstallable(tag: release.tag)
                return
            }

            phase = .downloading(tag: release.tag)
            let dmgURL = try await Self.download(release.dmgURL)
            phase = .installing(tag: release.tag)
            try await Task.detached(priority: .userInitiated) {
                try AppUpdateInstaller.install(dmgAt: dmgURL)
            }.value
            Self.relaunchInstalledApplication()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private nonisolated static func fetchLatestRelease() async throws -> Release {
        guard let url = URL(
            string: "https://api.github.com/repos/\(repository)/releases/latest"
        ) else {
            throw AppUpdateError.checkFailed("invalid release endpoint")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateError.checkFailed("unexpected response type")
        }
        guard httpResponse.statusCode == 200 else {
            throw AppUpdateError.checkFailed("GitHub replied with status \(httpResponse.statusCode)")
        }

        struct ReleaseDocument: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadURL: String

                enum CodingKeys: String, CodingKey {
                    case name
                    case browserDownloadURL = "browser_download_url"
                }
            }

            let tagName: String
            let assets: [Asset]

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case assets
            }
        }

        let document = try JSONDecoder().decode(ReleaseDocument.self, from: data)
        guard let buildNumber = buildNumber(fromTag: document.tagName) else {
            throw AppUpdateError.checkFailed("unrecognized release tag \(document.tagName)")
        }
        guard
            let asset = document.assets.first(where: { $0.name == "Slaptop.dmg" }),
            let dmgURL = URL(string: asset.browserDownloadURL),
            dmgURL.scheme == "https"
        else {
            throw AppUpdateError.checkFailed("release \(document.tagName) has no Slaptop.dmg asset")
        }
        return Release(tag: document.tagName, buildNumber: buildNumber, dmgURL: dmgURL)
    }

    private nonisolated static func download(_ url: URL) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppUpdateError.downloadFailed("unexpected server response")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Slaptop-update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func relaunchInstalledApplication() {
        // The reopen must outlive this process, so it is delegated to a
        // detached shell that waits for the current instance to exit.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 1; /usr/bin/open \"\(MissionControlController.installedApplicationPath)\"",
        ]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    private nonisolated static func relativeDescription(of date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Filesystem side of an update: mount the disk image, verify the replacement
/// app's code signature, swap it into /Applications, and clean up.
enum AppUpdateInstaller {
    /// The update must be Slaptop, signed by this project's team. Verified
    /// against the downloaded bundle before anything is replaced.
    private static let signatureRequirement = "anchor apple generic"
        + " and identifier \"guru.am.slaptop\""
        + " and certificate leaf[subject.OU] = \"59A594LZGR\""

    static func install(dmgAt dmgURL: URL) throws {
        let fileManager = FileManager.default
        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("Slaptop-update-mount-\(UUID().uuidString)")
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        try run(
            "/usr/bin/hdiutil",
            ["attach", dmgURL.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, "-quiet"],
            failure: { AppUpdateError.installFailed("could not open the update image: \($0)") }
        )
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"]) {
                AppUpdateError.installFailed($0)
            }
            try? fileManager.removeItem(at: mountPoint)
            try? fileManager.removeItem(at: dmgURL)
        }

        let replacementApp = mountPoint.appendingPathComponent("Slaptop.app")
        guard fileManager.fileExists(atPath: replacementApp.path) else {
            throw AppUpdateError.installFailed("the update image does not contain Slaptop.app")
        }
        try validateSignature(of: replacementApp)

        let installedURL = URL(fileURLWithPath: MissionControlController.installedApplicationPath)
        let previousURL = fileManager.temporaryDirectory
            .appendingPathComponent("Slaptop-previous-\(UUID().uuidString).app")
        try fileManager.moveItem(at: installedURL, to: previousURL)
        do {
            try run(
                "/usr/bin/ditto",
                [replacementApp.path, installedURL.path],
                failure: { AppUpdateError.installFailed("could not copy the new version: \($0)") }
            )
        } catch {
            // Roll the previous version back so the user is never left
            // without an installed app.
            try? fileManager.removeItem(at: installedURL)
            try? fileManager.moveItem(at: previousURL, to: installedURL)
            throw error
        }
        try? fileManager.removeItem(at: previousURL)
    }

    static func validateSignature(of applicationURL: URL) throws {
        var staticCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode
        else {
            throw AppUpdateError.installFailed("the downloaded app could not be inspected")
        }

        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(signatureRequirement as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else {
            throw AppUpdateError.installFailed("the update signature requirement is invalid")
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw AppUpdateError.installFailed(
                "the downloaded app is not a Slaptop build signed by AM Guru, LLC"
            )
        }
    }

    @discardableResult
    private static func run(
        _ executable: String,
        _ arguments: [String],
        failure: (String) -> Error
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let standardError = Pipe()
        process.standardError = standardError
        let standardOutput = Pipe()
        process.standardOutput = standardOutput

        do {
            try process.run()
        } catch {
            throw failure(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(detail?.isEmpty == false ? detail! : "exit status \(process.terminationStatus)")
        }
        return String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }
}
