//
//  AppPackageArchive.swift
//  Asspp
//
//  Created by luca on 15.09.2025.
//

import ApplePackage
import Foundation
import OrderedCollections

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
        // v3 resolves the deployment target from the remote IPA when Apple's
        // history metadata omits it. Refresh older unknown cached values once.
        _versionItems = .init(key: "\(packageIdentifier).versions.v3", defaultValue: [:])
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
