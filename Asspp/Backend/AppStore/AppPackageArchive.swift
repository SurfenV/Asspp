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
        error = nil
        versionIdentifiers = []
        versionItems.removeAll()
    }

    func cancelLoading() {
        operationTask?.cancel()
        operationTask = nil
        loading = false
        loadingMessage = ""
    }

    func populateVersionIdentifiers(_ completion: (() async -> Void)? = nil) {
        guard let accountIdentifier, !loading else { return }
        let bundleID = package.software.bundleID
        loading = true
        loadingMessage = "Loading version list…"
        error = nil

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let versions = try await AppStore.this.withAccount(id: accountIdentifier) { userAccount in
                    try await VersionFinder.list(account: &userAccount.account, bundleIdentifier: bundleID)
                }
                guard !Task.isCancelled else { return }
                versionIdentifiers = versions.reversed()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if case .licenseRequired = error as? ApplePackageError {
                    shouldDismiss = true
                }
                self.error = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            loading = false
            loadingMessage = ""
            operationTask = nil
            await completion?()
        }
    }

    func populateNextVersionItems(count: Int = 3) {
        guard let accountIdentifier, !loading, !isVersionItemsFullyLoaded else { return }
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

                    let metadata = try await AppStore.this.withAccount(id: accountIdentifier) { userAccount in
                        try await VersionLookup.getVersionMetadata(account: &userAccount.account, app: app, versionID: version)
                    }
                    try Task.checkCancellation()
                    versionItems[version] = metadata
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            loading = false
            loadingMessage = ""
            operationTask = nil
        }
    }

    func populateVersionItem(for versionID: String) {
        guard let accountIdentifier, !loading, versionIdentifiers.contains(versionID), versionItems[versionID] == nil else { return }
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
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            loading = false
            loadingMessage = ""
            operationTask = nil
        }
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
