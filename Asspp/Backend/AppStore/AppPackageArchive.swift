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
    let accountIdentifier: String?
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
    @Published var loading = false
    @Published var loadingMessage = ""
    @Published var shouldDismiss = false

    private var operationTask: Task<Void, Never>?

    init(accountID: String?, region: String, package: AppStore.AppPackage) {
        accountIdentifier = accountID
        self.region = region
        _package = .init(initialValue: package)

        let packageIdentifier = [package.id, package.software.bundleID.lowercased(), region]
            .joined()
            .lowercased()
        _versionItems = .init(key: "\(packageIdentifier).versions", defaultValue: [:])
        _versionIdentifiers = .init(key: "\(packageIdentifier).versionNumbers", defaultValue: [])
        logger.info("[history] archive initialized bundle=\(package.software.bundleID) region=\(region) cachedIDs=\(versionIdentifiers.count) cachedMetadata=\(versionItems.count)")
    }

    func package(for externalVersion: String) -> AppStore.AppPackage? {
        if let metadata = versionItems[externalVersion] {
            var pkg = package
            pkg.software.version = metadata.displayVersion
            pkg.externalVersionID = externalVersion
            return pkg
        } else {
            return nil
        }
    }

    func clearVersionItems() {
        assert(!loading)
        logger.info("[history] cache cleared bundle=\(package.software.bundleID) ids=\(versionIdentifiers.count) metadata=\(versionItems.count)")
        error = nil
        versionIdentifiers = []
        versionItems.removeAll()
    }

    func cancelLoading() {
        logger.info("[history] cancel requested bundle=\(package.software.bundleID) active=\(operationTask != nil)")
        operationTask?.cancel()
        operationTask = nil
        loading = false
        loadingMessage = ""
    }

    func populateVersionIdentifiers(_ completion: (() async -> Void)? = nil) {
        guard let accountIdentifier else {
            logger.error("[history] version-list rejected: no account bundle=\(package.software.bundleID)")
            return
        }
        guard !loading else {
            logger.info("[history] version-list ignored: another operation is active bundle=\(package.software.bundleID)")
            return
        }
        let bundleID = package.software.bundleID
        let operationID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        logger.info("[history:\(operationID)] version-list start bundle=\(bundleID) region=\(region)")
        loading = true
        loadingMessage = "Loading version list…"
        error = nil

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let versions = try await AppStore.this.withAccount(id: accountIdentifier) { userAccount in
                    logger.info("[history:\(operationID)] account loaded store=\(userAccount.account.store) pod=\(userAccount.account.pod ?? "missing")")
                    try await VersionFinder.list(account: &userAccount.account, bundleIdentifier: bundleID)
                }
                guard !Task.isCancelled else {
                    logger.info("[history:\(operationID)] version-list result discarded after cancellation elapsed=\(Self.elapsed(since: startedAt))s")
                    return
                }
                versionIdentifiers = versions.reversed()
                logger.info("[history:\(operationID)] version-list success count=\(versions.count) elapsed=\(Self.elapsed(since: startedAt))s")
            } catch is CancellationError {
                logger.info("[history:\(operationID)] version-list cancelled elapsed=\(Self.elapsed(since: startedAt))s")
                return
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("[history:\(operationID)] version-list failed type=\(String(reflecting: type(of: error))) elapsed=\(Self.elapsed(since: startedAt))s error=\(error.localizedDescription)")
                if case .licenseRequired = error as? ApplePackageError {
                    shouldDismiss = true
                }
                self.error = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            loading = false
            loadingMessage = ""
            operationTask = nil
            logger.info("[history:\(operationID)] version-list UI completed")
            await completion?()
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
        loading = true
        loadingMessage = "Loading version details…"
        error = nil

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for _ in 0 ..< count where !isVersionItemsFullyLoaded {
                    try Task.checkCancellation()
                    let nextIdx = versionItems.count
                    let version = versionIdentifiers[nextIdx]
                    let app = package.software
                    let itemStartedAt = Date()
                    logger.info("[history:\(operationID)] metadata item start index=\(nextIdx) versionID=\(version)")

                    let metadata = try await AppStore.this.withAccount(id: accountIdentifier) { userAccount in
                        try await VersionLookup.getVersionMetadata(account: &userAccount.account, app: app, versionID: version)
                    }
                    try Task.checkCancellation()
                    versionItems[version] = metadata
                    logger.info("[history:\(operationID)] metadata item success index=\(nextIdx) displayVersion=\(metadata.displayVersion) elapsed=\(Self.elapsed(since: itemStartedAt))s")
                }
            } catch is CancellationError {
                logger.info("[history:\(operationID)] metadata batch cancelled elapsed=\(Self.elapsed(since: startedAt))s")
                return
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("[history:\(operationID)] metadata batch failed type=\(String(reflecting: type(of: error))) elapsed=\(Self.elapsed(since: startedAt))s error=\(error.localizedDescription)")
                self.error = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            loading = false
            loadingMessage = ""
            operationTask = nil
            logger.info("[history:\(operationID)] metadata batch completed loaded=\(versionItems.count)/\(versionIdentifiers.count)")
        }
    }

    func populateVersionItem(for versionID: String) {
        guard let accountIdentifier, !loading, versionIdentifiers.contains(versionID), versionItems[versionID] == nil else {
            logger.info("[history] metadata item ignored versionID=\(versionID) loading=\(loading)")
            return
        }
        let operationID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        logger.info("[history:\(operationID)] metadata single start versionID=\(versionID)")
        loading = true
        loadingMessage = "Loading version details…"
        error = nil

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let app = package.software
                let metadata = try await AppStore.this.withAccount(id: accountIdentifier) { userAccount in
                    try await VersionLookup.getVersionMetadata(account: &userAccount.account, app: app, versionID: versionID)
                }
                guard !Task.isCancelled else { return }
                versionItems[versionID] = metadata
                logger.info("[history:\(operationID)] metadata single success displayVersion=\(metadata.displayVersion) elapsed=\(Self.elapsed(since: startedAt))s")
            } catch is CancellationError {
                logger.info("[history:\(operationID)] metadata single cancelled elapsed=\(Self.elapsed(since: startedAt))s")
                return
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("[history:\(operationID)] metadata single failed type=\(String(reflecting: type(of: error))) elapsed=\(Self.elapsed(since: startedAt))s error=\(error.localizedDescription)")
                self.error = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            loading = false
            loadingMessage = ""
            operationTask = nil
        }
    }

    private static func elapsed(since date: Date) -> String {
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
