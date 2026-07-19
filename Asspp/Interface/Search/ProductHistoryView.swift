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
    @State private var experimentalMinimumOS = Self.defaultExperimentalMinimumOS
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ScrollViewReader { proxy in
            List {
                compatibilityFinder
                experimentalIPABuilder

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

    private var experimentalIPABuilder: some View {
        Section {
            HStack {
                Text("Target iOS/iPadOS")
                Spacer()
                TextField("15.0", text: $experimentalMinimumOS)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
            }

            Button {
                vm.createExperimentalIPA(
                    endpoint: .latest,
                    minimumOS: experimentalMinimumOS
                )
            } label: {
                Label("Create from Latest Version", systemImage: "hammer")
            }
            .disabled(experimentalActionDisabled)

            Button {
                vm.createExperimentalIPA(
                    endpoint: .oldest,
                    minimumOS: experimentalMinimumOS
                )
            } label: {
                Label("Create from Oldest Version", systemImage: "hammer.fill")
            }
            .disabled(experimentalActionDisabled)

            if vm.experimentalIPAIsRunning {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(vm.experimentalIPAMessage ?? "Creating experimental IPA…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let message = vm.experimentalIPAMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            if let result = vm.experimentalIPAResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Version \(result.displayVersion)")
                        .font(.subheadline.weight(.medium))
                    Text("MinimumOSVersion: \(result.originalMinimumOS ?? "missing") → \(result.patchedMinimumOS)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button {
                    _ = AirDrop(items: [result.patchedURL, result.reportURL])
                } label: {
                    Label("Share Patched IPA", systemImage: "square.and.arrow.up")
                }

                Button {
                    _ = AirDrop(items: [result.originalURL])
                } label: {
                    Label("Share Original IPA", systemImage: "archivebox")
                }
            }
        } header: {
            Text("Compatibility Experiment")
        } footer: {
            Text("Downloads the selected endpoint, preserves an original IPA, and changes only the main app Info.plist. TrollStore must re-sign the patched IPA. This does not make newer APIs compatible with iOS 15.")
        }
    }

    private var experimentalActionDisabled: Bool {
        vm.loading
            || vm.versionIdentifiers.isEmpty
            || vm.accountIdentifier == nil
            || ExperimentalIPABuilder.normalizedMinimumOS(experimentalMinimumOS) == nil
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

    private static var defaultExperimentalMinimumOS: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }
}
