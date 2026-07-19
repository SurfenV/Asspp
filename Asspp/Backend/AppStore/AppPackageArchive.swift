//
//  AppPackageArchive.swift
//  Asspp
//
//  Created by luca on 15.09.2025.
//

import ApplePackage
import Foundation
import OrderedCollections

enum ExperimentalHistoryEndpoint: String, Sendable {
    case latest
    case oldest
}

@MainActor
class AppPackageArchive: ObservableObject {
    private(set) var accountIdentifier: String?
    let region: String

    @Published
    var package: AppStore.AppPackage

    typealias VersionIdentifier = String
    @PublishedPersist
    var versionIdentifiers: [VersionIdentifier]
    @PublishedPersist
    var versionItems: OrderedDictionary<VersionIdentifier, VersionMetadata>

    var isVersionItemsFullyLoaded: Bool {
        assert(versionItems.count <= versionIdentifiers.count)
        return versionItems.count == versionIdentifiers.count
    }

    @Published var error: String?
    var loading = false
    var loadingMessage = ""
    @Published var shouldDismiss = false
    @Published var compatibilitySearchMessage: String?
    @Published var compatibleVersionIdentifier: VersionIdentifier?
    @Published var compatibilitySearchIsRunning = false
    @Published var experimentalIPAMessage: String?
    @Published var experimentalIPAIsRunning = false
    @Published var experimentalIPAResult: ExperimentalIPAResult?

    private var operationTask: Task<Void, Never>?
    private var visiblePrefetchTargetIndex = -1

    init(accountID: String?, region: String, package: AppStore.AppPackage) {
        let normalizedAccountID = accountID.flatMap { $0.isEmpty ? nil : $0 }
        logger.info("[history-init] begin bundle=\(package.software.bundleID) region=\(region) account=\(normalizedAccountID == nil ? "missing" : "available")")
        accountIdentifier = normalizedAccountID
        self.region = region
        _package = .init(initialValue: package)

        let packageIdentifier = [package.id, package.software.bundleID.lowercased(), region]
            .joined()
            .lowercased()
        logger.info("[history-init] loading metadata cache bundle=\(package.software.bundleID)")
        // v4 removes Apple's app-level releaseDate, which was incorrectly
        // repeated for every historical version, and stores the IPA package
        // date instead.
        _versionItems = .init(key: "\(packageIdentifier).versions.v4", defaultValue: [:])
        logger.info("[history-init] loading version-ID cache bundle=\(package.software.bundleID)")
        _versionIdentifiers = .init(key: "\(packageIdentifier).versionNumbers", defaultValue: [])
        logger.info("[history] archive initialized bundle=\(package.software.bundleID) region=\(region) cachedIDs=\(versionIdentifiers.count) cachedMetadata=\(versionItems.count)")
    }

    func package(for externalVersion: String) -> AppStore.AppPackage? {
        if let metadata = versionItems[externalVersion] {
            var pkg = package
            pkg.software.version = metadata.displayVersion
            if let minimumOsVersion = metadata.minimumOsVersion {
                pkg.software.minimumOsVersion = minimumOsVersion
            }
            pkg.externalVersionID = externalVersion
            return pkg
        } else {
            return nil
        }
    }

    func configureHistoryAccount(_ accountID: String) {
        let normalizedAccountID = accountID.isEmpty ? nil : accountID
        accountIdentifier = normalizedAccountID
        logger.info("[history] account configured bundle=\(package.software.bundleID) account=\(normalizedAccountID == nil ? "missing" : "available")")
    }

    func clearVersionItems() {
        assert(!loading)
        logger.info("[history] cache cleared bundle=\(package.software.bundleID) ids=\(versionIdentifiers.count) metadata=\(versionItems.count)")
        visiblePrefetchTargetIndex = -1
        error = nil
        compatibilitySearchMessage = nil
        compatibleVersionIdentifier = nil
        experimentalIPAMessage = nil
        experimentalIPAResult = nil
        versionIdentifiers = []
        versionItems.removeAll()
    }

    func cancelLoading() {
        logger.info("[history] cancel requested bundle=\(package.software.bundleID) active=\(operationTask != nil)")
        operationTask?.cancel()
        operationTask = nil
        visiblePrefetchTargetIndex = -1
        loading = false
        loadingMessage = ""
        compatibilitySearchIsRunning = false
        experimentalIPAIsRunning = false
    }

    func populateVersionIdentifiers(_ completion: (() -> Void)? = nil) {
        guard let accountIdentifier, !accountIdentifier.isEmpty else {
            logger.error("[history] version-list rejected: no account bundle=\(package.software.bundleID)")
            error = "No App Store account is available for the \(region) region."
            return
        }
        guard !loading else {
            logger.info("[history] version-list ignored: another operation is active bundle=\(package.software.bundleID)")
            return
        }
        let bundleID = package.software.bundleID
        let knownApp = package.software
        let operationID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        logger.info("[history:\(operationID)] version-list start bundle=\(bundleID) region=\(region)")

        let initialUserAccount: AppStore.UserAccount
        do {
            initialUserAccount = try AppStore.this.accountSnapshot(id: accountIdentifier)
        } catch {
            self.error = error.localizedDescription
            return
        }

        loading = true
        loadingMessage = "Loading version list…"
        if error != nil { error = nil }

        operationTask = Task.detached(priority: .userInitiated) { [weak self] in
            let watchdog = Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                logger.warning("[history:\(operationID)] watchdog: operation still pending after 5s")
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                logger.warning("[history:\(operationID)] watchdog: operation still pending after 15s")
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                logger.warning("[history:\(operationID)] watchdog: operation still pending after 30s")
            }
            let mainActorProbe = Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                logger.warning("[history:\(operationID)] main-actor probe scheduled after 5s")
                DispatchQueue.main.async {
                    logger.warning("[history:\(operationID)] main-actor probe completed after 5s")
                }
            }
            do {
                logger.info("[history:\(operationID)] value-based version request begin")
                let output = try await VersionFinder.listReturningAccount(
                    account: initialUserAccount.account,
                    bundleIdentifier: bundleID,
                    knownApp: knownApp
                )
                try Task.checkCancellation()
                logger.info("[history:\(operationID)] detached version backend returned count=\(output.versions.count); dispatching UI callback")

                DispatchQueue.main.async { [weak self] in
                    watchdog.cancel()
                    mainActorProbe.cancel()
                    guard let self else { return }
                    var userAccount = initialUserAccount
                    userAccount.account = output.account
                    AppStore.this.saveAccountSnapshot(userAccount, id: accountIdentifier)
                    self.versionIdentifiers = Array(output.versions.reversed())
                    logger.info("[history:\(operationID)] version IDs applied count=\(self.versionIdentifiers.count)")
                    logger.info("[history:\(operationID)] version-list success count=\(output.versions.count) elapsed=\(Self.elapsed(since: startedAt))s")
                    self.loading = false
                    self.loadingMessage = ""
                    self.operationTask = nil
                    logger.info("[history:\(operationID)] version-list UI completed")
                    completion?()
                }
            } catch is CancellationError {
                watchdog.cancel()
                mainActorProbe.cancel()
                logger.info("[history:\(operationID)] version-list cancelled elapsed=\(Self.elapsed(since: startedAt))s")
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("[history:\(operationID)] version-list failed type=\(String(reflecting: type(of: error))) elapsed=\(Self.elapsed(since: startedAt))s error=\(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    watchdog.cancel()
                    mainActorProbe.cancel()
                    guard let self else { return }
                    if case .licenseRequired = error as? ApplePackageError {
                        self.shouldDismiss = true
                    }
                    self.error = error.localizedDescription
                    self.loading = false
                    self.loadingMessage = ""
                    self.operationTask = nil
                    logger.info("[history:\(operationID)] version-list UI failed callback completed")
                }
            }
        }
    }

    func populateNextVersionItems(count: Int = 3) {
        guard let accountIdentifier, !loading, !isVersionItemsFullyLoaded else {
            logger.info("[history] metadata batch ignored account=\(accountIdentifier == nil ? "missing" : "available") loading=\(loading) fullyLoaded=\(isVersionItemsFullyLoaded)")
            return
        }
        let operationID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        logger.info("[history:\(operationID)] metadata batch start requested=\(count) loaded=\(versionItems.count)/\(versionIdentifiers.count)")

        let pendingVersions = Array(
            versionIdentifiers.enumerated()
                .filter { versionItems[$0.element] == nil }
                .prefix(count)
        )
        let app = package.software
        let initialUserAccount: AppStore.UserAccount
        do {
            initialUserAccount = try AppStore.this.accountSnapshot(id: accountIdentifier)
        } catch {
            self.error = error.localizedDescription
            return
        }

        loading = true
        loadingMessage = "Loading version details…"
        if error != nil { error = nil }

        operationTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var userAccount = initialUserAccount
                for (nextIdx, version) in pendingVersions {
                    try Task.checkCancellation()
                    let itemStartedAt = Date()
                    logger.info("[history:\(operationID)] metadata item start index=\(nextIdx) versionID=\(version)")

                    let output = try await VersionLookup.getVersionMetadataReturningAccount(
                        account: userAccount.account,
                        app: app,
                        versionID: version
                    )
                    userAccount.account = output.account
                    let metadata = output.metadata
                    try Task.checkCancellation()
                    let updatedUserAccount = userAccount
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        AppStore.this.saveAccountSnapshot(updatedUserAccount, id: accountIdentifier)
                        self.versionItems[version] = metadata
                        logger.info("[history:\(operationID)] metadata item UI applied index=\(nextIdx) displayVersion=\(metadata.displayVersion) elapsed=\(Self.elapsed(since: itemStartedAt))s")
                    }
                }
                try Task.checkCancellation()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.loading = false
                    self.loadingMessage = ""
                    self.operationTask = nil
                    logger.info("[history:\(operationID)] metadata batch completed loaded=\(self.versionItems.count)/\(self.versionIdentifiers.count)")
                    self.continueVisiblePrefetchIfNeeded()
                }
            } catch is CancellationError {
                logger.info("[history:\(operationID)] metadata batch cancelled elapsed=\(Self.elapsed(since: startedAt))s")
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("[history:\(operationID)] metadata batch failed type=\(String(reflecting: type(of: error))) elapsed=\(Self.elapsed(since: startedAt))s error=\(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.error = error.localizedDescription
                    self.visiblePrefetchTargetIndex = -1
                    self.loading = false
                    self.loadingMessage = ""
                    self.operationTask = nil
                }
            }
        }
    }

    func prefetchVersionItemIfVisible(_ versionID: String) {
        guard versionItems[versionID] == nil,
              let index = versionIdentifiers.firstIndex(of: versionID)
        else {
            return
        }
        if index > visiblePrefetchTargetIndex {
            visiblePrefetchTargetIndex = index
            logger.info("[history] visible prefetch target updated index=\(index) versionID=\(versionID)")
        }
        continueVisiblePrefetchIfNeeded()
    }

    private func continueVisiblePrefetchIfNeeded() {
        guard visiblePrefetchTargetIndex >= 0, !loading else { return }
        let upperBound = min(visiblePrefetchTargetIndex + 1, versionIdentifiers.count)
        let missingVisibleItems = versionIdentifiers.prefix(upperBound)
            .filter { versionItems[$0] == nil }
        guard !missingVisibleItems.isEmpty else {
            visiblePrefetchTargetIndex = -1
            return
        }

        let count = min(10, missingVisibleItems.count)
        logger.info("[history] visible prefetch continuing requested=\(count) targetIndex=\(visiblePrefetchTargetIndex)")
        populateNextVersionItems(count: count)
    }

    func populateVersionItem(for versionID: String) {
        guard let accountIdentifier, !loading, versionIdentifiers.contains(versionID), versionItems[versionID] == nil else {
            logger.info("[history] metadata item ignored versionID=\(versionID) loading=\(loading)")
            return
        }
        let operationID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        logger.info("[history:\(operationID)] metadata single start versionID=\(versionID)")

        let app = package.software
        let initialUserAccount: AppStore.UserAccount
        do {
            initialUserAccount = try AppStore.this.accountSnapshot(id: accountIdentifier)
        } catch {
            self.error = error.localizedDescription
            return
        }

        loading = true
        loadingMessage = "Loading version details…"
        if error != nil { error = nil }

        operationTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let output = try await VersionLookup.getVersionMetadataReturningAccount(
                    account: initialUserAccount.account,
                    app: app,
                    versionID: versionID
                )
                try Task.checkCancellation()
                var userAccount = initialUserAccount
                userAccount.account = output.account
                let metadata = output.metadata
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    AppStore.this.saveAccountSnapshot(userAccount, id: accountIdentifier)
                    self.versionItems[versionID] = metadata
                    self.loading = false
                    self.loadingMessage = ""
                    self.operationTask = nil
                    logger.info("[history:\(operationID)] metadata single UI applied displayVersion=\(metadata.displayVersion) elapsed=\(Self.elapsed(since: startedAt))s")
                    self.continueVisiblePrefetchIfNeeded()
                }
            } catch is CancellationError {
                logger.info("[history:\(operationID)] metadata single cancelled elapsed=\(Self.elapsed(since: startedAt))s")
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("[history:\(operationID)] metadata single failed type=\(String(reflecting: type(of: error))) elapsed=\(Self.elapsed(since: startedAt))s error=\(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.error = error.localizedDescription
                    self.visiblePrefetchTargetIndex = -1
                    self.loading = false
                    self.loadingMessage = ""
                    self.operationTask = nil
                }
            }
        }
    }

    /// Finds the newest installable version without resolving every row.
    /// It probes exponentially older versions to bracket the compatibility
    /// transition, then bisects that range and verifies nearby versions.
    func findLatestCompatibleVersion() {
        guard let accountIdentifier,
              !loading,
              !versionIdentifiers.isEmpty
        else {
            logger.info("[compatibility-search] ignored account=\(accountIdentifier == nil ? "missing" : "available") loading=\(loading) versions=\(versionIdentifiers.count)")
            return
        }

        let operationID = String(UUID().uuidString.prefix(8))
        let identifiers = versionIdentifiers
        let app = package.software
        let cachedItems = Dictionary(uniqueKeysWithValues: versionItems.map { ($0.key, $0.value) })
        let currentSystem = ProcessInfo.processInfo.operatingSystemVersion
        let initialUserAccount: AppStore.UserAccount
        do {
            initialUserAccount = try AppStore.this.accountSnapshot(id: accountIdentifier)
        } catch {
            self.error = error.localizedDescription
            return
        }

        loading = true
        loadingMessage = "Finding a compatible version…"
        compatibilitySearchIsRunning = true
        compatibilitySearchMessage = "Checking the newest version…"
        compatibleVersionIdentifier = nil
        error = nil
        logger.info("[compatibility-search:\(operationID)] start versions=\(identifiers.count) system=\(currentSystem.majorVersion).\(currentSystem.minorVersion).\(currentSystem.patchVersion)")

        operationTask = Task.detached(priority: .userInitiated) { [weak self] in
            var userAccount = initialUserAccount
            var resolvedItems = cachedItems
            var probeCount = 0

            func resolve(_ index: Int) async throws -> VersionMetadata {
                let versionID = identifiers[index]
                if let cached = resolvedItems[versionID] {
                    return cached
                }

                probeCount += 1
                let message = "Checking candidate \(probeCount): \(index + 1) of \(identifiers.count)…"
                await MainActor.run { [weak self] in
                    self?.compatibilitySearchMessage = message
                }
                logger.info("[compatibility-search:\(operationID)] probe start index=\(index) versionID=\(versionID)")
                let output = try await VersionLookup.getVersionMetadataReturningAccount(
                    account: userAccount.account,
                    app: app,
                    versionID: versionID
                )
                userAccount.account = output.account
                resolvedItems[versionID] = output.metadata
                let updatedUserAccount = userAccount
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    AppStore.this.saveAccountSnapshot(updatedUserAccount, id: accountIdentifier)
                    self.versionItems[versionID] = output.metadata
                }
                logger.info("[compatibility-search:\(operationID)] probe completed index=\(index) displayVersion=\(output.metadata.displayVersion) minimumOS=\(output.metadata.minimumOsVersion ?? "unknown")")
                return output.metadata
            }

            func isCompatible(_ metadata: VersionMetadata) -> Bool? {
                guard let minimumOsVersion = metadata.minimumOsVersion else {
                    return nil
                }
                return Self.systemVersion(currentSystem, supports: minimumOsVersion)
            }

            do {
                var newestKnownIncompatibleIndex = -1
                var oldestKnownCompatibleIndex: Int?
                var probeIndex = 0

                while true {
                    try Task.checkCancellation()
                    let metadata = try await resolve(probeIndex)
                    if isCompatible(metadata) == true {
                        oldestKnownCompatibleIndex = probeIndex
                        break
                    }
                    if isCompatible(metadata) == false {
                        newestKnownIncompatibleIndex = probeIndex
                    }
                    guard probeIndex < identifiers.count - 1 else { break }
                    probeIndex = min(
                        identifiers.count - 1,
                        max(probeIndex + 1, (probeIndex + 1) * 2 - 1)
                    )
                }

                guard var compatibleIndex = oldestKnownCompatibleIndex else {
                    let resultMessage = newestKnownIncompatibleIndex >= 0
                        ? "No compatible historical version was found."
                        : "Could not determine the minimum system requirement."
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.loading = false
                        self.loadingMessage = ""
                        self.operationTask = nil
                        self.compatibilitySearchIsRunning = false
                        self.compatibilitySearchMessage = resultMessage
                    }
                    logger.info("[compatibility-search:\(operationID)] no compatible result probes=\(probeCount)")
                    return
                }

                var lowerBound = max(0, newestKnownIncompatibleIndex)
                var upperBound = compatibleIndex
                while upperBound - lowerBound > 1 {
                    try Task.checkCancellation()
                    let middle = lowerBound + (upperBound - lowerBound) / 2
                    let metadata = try await resolve(middle)
                    if isCompatible(metadata) == true {
                        upperBound = middle
                        compatibleIndex = middle
                    } else {
                        // Unknown requirements cannot certify compatibility;
                        // continue toward older versions, then verify nearby.
                        lowerBound = middle
                    }
                }

                // App deployment targets are normally monotonic, but verify a
                // small window in case a developer briefly lowered it again.
                let verificationStart = max(0, compatibleIndex - 4)
                if verificationStart < compatibleIndex {
                    for index in verificationStart ..< compatibleIndex {
                        try Task.checkCancellation()
                        if isCompatible(try await resolve(index)) == true {
                            compatibleIndex = index
                            break
                        }
                    }
                }

                let versionID = identifiers[compatibleIndex]
                let metadata = try await resolve(compatibleIndex)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.loading = false
                    self.loadingMessage = ""
                    self.operationTask = nil
                    self.compatibilitySearchIsRunning = false
                    self.compatibleVersionIdentifier = versionID
                    self.compatibilitySearchMessage = "Found version \(metadata.displayVersion), requiring iOS/iPadOS \(metadata.minimumOsVersion ?? "unknown")+."
                }
                logger.info("[compatibility-search:\(operationID)] success index=\(compatibleIndex) displayVersion=\(metadata.displayVersion) probes=\(probeCount)")
            } catch is CancellationError {
                logger.info("[compatibility-search:\(operationID)] cancelled probes=\(probeCount)")
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("[compatibility-search:\(operationID)] failed type=\(String(reflecting: type(of: error))) probes=\(probeCount) error=\(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.loading = false
                    self.loadingMessage = ""
                    self.operationTask = nil
                    self.compatibilitySearchIsRunning = false
                    self.compatibilitySearchMessage = nil
                    self.error = error.localizedDescription
                }
            }
        }
    }

    nonisolated static func systemVersion(
        _ current: OperatingSystemVersion,
        supports requiredVersion: String
    ) -> Bool? {
        let components = requiredVersion
            .split(separator: ".")
            .compactMap { Int($0) }
        guard let major = components.first else { return nil }
        let required = OperatingSystemVersion(
            majorVersion: major,
            minorVersion: components.count > 1 ? components[1] : 0,
            patchVersion: components.count > 2 ? components[2] : 0
        )
        if current.majorVersion != required.majorVersion {
            return current.majorVersion > required.majorVersion
        }
        if current.minorVersion != required.minorVersion {
            return current.minorVersion > required.minorVersion
        }
        return current.patchVersion >= required.patchVersion
    }

    func createExperimentalIPA(
        endpoint: ExperimentalHistoryEndpoint,
        minimumOS input: String
    ) {
        guard let accountIdentifier,
              !loading,
              !versionIdentifiers.isEmpty
        else {
            logger.info("[experimental-ipa] request ignored endpoint=\(endpoint.rawValue) loading=\(loading) versions=\(versionIdentifiers.count)")
            return
        }
        guard let minimumOS = ExperimentalIPABuilder.normalizedMinimumOS(input) else {
            error = "Enter a valid minimum system version such as 15.0 or 15.8."
            return
        }

        let versionID: String
        switch endpoint {
        case .latest:
            guard let first = versionIdentifiers.first else { return }
            versionID = first
        case .oldest:
            guard let last = versionIdentifiers.last else { return }
            versionID = last
        }

        let operationID = String(UUID().uuidString.prefix(8))
        let app = package.software
        let cachedMetadata = versionItems[versionID]
        let initialUserAccount: AppStore.UserAccount
        do {
            initialUserAccount = try AppStore.this.accountSnapshot(id: accountIdentifier)
        } catch {
            self.error = error.localizedDescription
            return
        }

        loading = true
        loadingMessage = "Creating experimental IPA…"
        experimentalIPAIsRunning = true
        experimentalIPAMessage = "Resolving the \(endpoint.rawValue) historical version…"
        experimentalIPAResult = nil
        error = nil
        logger.info("[experimental-ipa:\(operationID)] UI request endpoint=\(endpoint.rawValue) versionID=\(versionID) targetOS=\(minimumOS)")

        operationTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var userAccount = initialUserAccount
                let metadata: VersionMetadata
                if let cachedMetadata {
                    metadata = cachedMetadata
                } else {
                    let output = try await VersionLookup.getVersionMetadataReturningAccount(
                        account: userAccount.account,
                        app: app,
                        versionID: versionID
                    )
                    userAccount.account = output.account
                    metadata = output.metadata
                    let updatedUserAccount = userAccount
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        AppStore.this.saveAccountSnapshot(updatedUserAccount, id: accountIdentifier)
                        self.versionItems[versionID] = metadata
                    }
                }
                try Task.checkCancellation()

                let result = try await ExperimentalIPABuilder.build(
                    account: &userAccount.account,
                    app: app,
                    versionID: versionID,
                    displayVersion: metadata.displayVersion,
                    minimumOS: minimumOS,
                    endpointLabel: endpoint.rawValue,
                    progress: { [weak self] message in
                        await self?.updateExperimentalIPAMessage(message)
                    }
                )
                try Task.checkCancellation()
                let updatedUserAccount = userAccount
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    AppStore.this.saveAccountSnapshot(updatedUserAccount, id: accountIdentifier)
                    self.loading = false
                    self.loadingMessage = ""
                    self.operationTask = nil
                    self.experimentalIPAIsRunning = false
                    self.experimentalIPAResult = result
                    self.experimentalIPAMessage = "Created \(endpoint.rawValue) version \(result.displayVersion) with MinimumOSVersion \(result.patchedMinimumOS)."
                }
                logger.info("[experimental-ipa:\(operationID)] UI completed endpoint=\(endpoint.rawValue) displayVersion=\(result.displayVersion) patched=\(result.patchedURL.lastPathComponent)")
            } catch is CancellationError {
                logger.info("[experimental-ipa:\(operationID)] cancelled endpoint=\(endpoint.rawValue)")
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("[experimental-ipa:\(operationID)] failed endpoint=\(endpoint.rawValue) type=\(String(reflecting: type(of: error))) error=\(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.loading = false
                    self.loadingMessage = ""
                    self.operationTask = nil
                    self.experimentalIPAIsRunning = false
                    self.experimentalIPAMessage = nil
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func updateExperimentalIPAMessage(_ message: String) {
        experimentalIPAMessage = message
    }

    private nonisolated static func elapsed(since date: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(date))
    }
}

@MainActor
extension AppPackageArchive {
    var version: String { package.software.version }

    var releaseDate: Date? { package.releaseDate }

    var releaseNotes: String? { package.software.releaseNotes }

    var formattedPrice: String { package.software.formattedPrice ?? "—" }

    var price: Double? { package.software.price }

    var downloadOutput: DownloadOutput? {
        get { package.downloadOutput }
        set { package.downloadOutput = newValue }
    }
}
