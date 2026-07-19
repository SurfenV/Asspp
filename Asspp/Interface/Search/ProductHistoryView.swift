//
//  ProductHistoryView.swift
//  Asspp
//
//  Created by luca on 15.09.2025.
//

import ApplePackage
import SwiftUI

struct ProductHistoryView: View {
    @ObservedObject var vm: AppPackageArchive
    let accountID: String
    @State private var showErrorAlert = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ScrollViewReader { proxy in
            List {
                compatibilityFinder

                if vm.versionIdentifiers.isEmpty {
                    Label("Loading version history…", systemImage: "clock")
                        .foregroundColor(.secondary)
                }
                ForEach(vm.versionIdentifiers, id: \.self) { key in
                    if let aid = vm.accountIdentifier,
                       let pkg = vm.package(for: key),
                       let metadata = vm.versionItems[key]
                    {
                        Menu {
                            Button("Download \(pkg.software.version)") {
                                startDownload(pkg, accountID: aid)
                            }
                        } label: {
                            versionRow(metadata)
                        }
                        .id(key)
                    } else {
                        Button {
                            vm.populateVersionItem(for: key)
                        } label: {
                            HStack {
                                Text(key).foregroundColor(.secondary)
                                Spacer()
                                Image(systemName: "arrow.down.circle")
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .id(key)
                    }
                }
            }
            .navigationTitle("Version History")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            vm.populateNextVersionItems(count: 20)
                        } label: {
                            Label("Load More", systemImage: "arrow.down.circle")
                        }
                        .disabled(vm.isVersionItemsFullyLoaded)
                        Divider()
                        Button(role: .destructive) {
                            guard !vm.loading else { return }
                            vm.clearVersionItems()
                            vm.populateVersionIdentifiers()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert(isPresented: $showErrorAlert) {
                Alert(
                    title: Text("Oops"),
                    message: Text(vm.error ?? String(localized: "Unknown Error")),
                    dismissButton: .default(Text("OK"), action: {
                        vm.error = nil
                        if vm.shouldDismiss {
                            dismiss()
                        }
                    })
                )
            }
            .onChange(of: vm.error) { newValue in
                showErrorAlert = newValue != nil
            }
            .onChange(of: vm.compatibleVersionIdentifier) { versionID in
                guard let versionID else { return }
                withAnimation {
                    proxy.scrollTo(versionID, anchor: .center)
                }
            }
            .onAppear {
                vm.configureHistoryAccount(accountID)
                logger.info("[history-ui] appeared bundle=\(vm.package.software.bundleID) cachedIDs=\(vm.versionIdentifiers.count) cachedMetadata=\(vm.versionItems.count)")
                if vm.versionIdentifiers.isEmpty {
                    vm.populateVersionIdentifiers()
                }
            }
            .onDisappear {
                logger.info("[history-ui] disappeared bundle=\(vm.package.software.bundleID)")
                vm.cancelLoading()
            }
        }
    }

    private var compatibilityFinder: some View {
        Section {
            Button {
                vm.findLatestCompatibleVersion()
            } label: {
                Label("Find Latest Compatible Version", systemImage: "checkmark.magnifyingglass")
            }
            .disabled(
                vm.loading
                    || vm.versionIdentifiers.isEmpty
                    || vm.accountIdentifier == nil
            )

            if vm.compatibilitySearchIsRunning {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(vm.compatibilitySearchMessage ?? "Searching…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let message = vm.compatibilitySearchMessage {
                Label(message, systemImage: vm.compatibleVersionIdentifier == nil
                    ? "exclamationmark.magnifyingglass"
                    : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(vm.compatibleVersionIdentifier == nil ? .orange : .green)
            }

            if let versionID = vm.compatibleVersionIdentifier,
               let aid = vm.accountIdentifier,
               let pkg = vm.package(for: versionID)
            {
                Button {
                    startDownload(pkg, accountID: aid)
                } label: {
                    Label("Download \(pkg.software.version)", systemImage: "arrow.down.circle.fill")
                }
            }
        } footer: {
            Text("Uses exponential probing and binary search, then checks nearby versions. Only the tested candidates are loaded.")
        }
    }

    private func startDownload(_ package: AppStore.AppPackage, accountID: String) {
        Task {
            do {
                try await Downloads.this.startDownload(for: package, accountID: accountID)
            } catch {
                vm.error = error.localizedDescription
            }
        }
    }

    private func versionRow(_ metadata: VersionMetadata) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(metadata.displayVersion)
                    .font(.body.weight(.medium))
                    .foregroundColor(.accentColor)
                Spacer()
                compatibilityBadge(metadata.minimumOsVersion)
            }
            if let packageDate = metadata.releaseDate {
                Text("Package date (approx.): \(packageDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Package date unavailable")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let minimumOsVersion = metadata.minimumOsVersion {
                Text("Requires iOS/iPadOS \(minimumOsVersion)+")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Minimum system version unknown")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func compatibilityBadge(_ minimumOsVersion: String?) -> some View {
        if let minimumOsVersion,
           let compatible = Self.currentSystemSupports(minimumOsVersion)
        {
            Label {
                Text(compatible ? String(localized: "Compatible") : String(localized: "Newer OS required"))
            } icon: {
                Image(systemName: compatible ? "checkmark.circle.fill" : "xmark.circle.fill")
            }
            .font(.caption)
            .foregroundColor(compatible ? .green : .red)
        }
    }

    private static func currentSystemSupports(_ minimumOsVersion: String) -> Bool? {
        #if os(iOS)
            return AppPackageArchive.systemVersion(
                ProcessInfo.processInfo.operatingSystemVersion,
                supports: minimumOsVersion
            )
        #else
            return nil
        #endif
    }
}
