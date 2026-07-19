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
        List {
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
                            Task {
                                do {
                                    try await Downloads.this.startDownload(for: pkg, accountID: aid)
                                } catch {
                                    vm.error = error.localizedDescription
                                }
                            }
                        }
                    } label: {
                        versionRow(metadata)
                    }
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
                        vm.populateVersionIdentifiers {
                            vm.populateNextVersionItems(count: 5)
                        }
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
        .onAppear {
            vm.configureHistoryAccount(accountID)
            logger.info("[history-ui] appeared bundle=\(vm.package.software.bundleID) cachedIDs=\(vm.versionIdentifiers.count) cachedMetadata=\(vm.versionItems.count)")
            if vm.versionIdentifiers.isEmpty {
                vm.populateVersionIdentifiers {
                    vm.populateNextVersionItems(count: 5)
                }
            } else if vm.versionItems.isEmpty {
                vm.populateNextVersionItems(count: 5)
            }
        }
        .onDisappear {
            logger.info("[history-ui] disappeared bundle=\(vm.package.software.bundleID)")
            vm.cancelLoading()
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
            Text(metadata.releaseDate.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundColor(.secondary)
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
            let components = minimumOsVersion
                .split(separator: ".")
                .compactMap { Int($0) }
            guard let major = components.first else { return nil }
            let required = OperatingSystemVersion(
                majorVersion: major,
                minorVersion: components.count > 1 ? components[1] : 0,
                patchVersion: components.count > 2 ? components[2] : 0
            )
            return ProcessInfo.processInfo.isOperatingSystemAtLeast(required)
        #else
            return nil
        #endif
    }
}
