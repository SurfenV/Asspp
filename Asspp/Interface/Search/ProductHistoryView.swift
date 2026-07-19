//
//  ProductHistoryView.swift
//  Asspp
//
//  Created by luca on 15.09.2025.
//

import ApplePackage
import SwiftUI

struct ProductHistoryView: View {
    @StateObject var vm: AppPackageArchive
    @State private var showErrorAlert = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        List {
            ForEach(vm.versionIdentifiers, id: \.self) { key in
                if let aid = vm.accountIdentifier, let pkg = vm.package(for: key) {
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
                        HStack {
                            Text(pkg.software.version)
                                .foregroundColor(.accentColor)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                } else {
                    Button {
                        vm.populateVersionItem(for: key)
                    } label: {
                        HStack {
                            Text(key).foregroundColor(.secondary)
                            Spacer()
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
                        vm.populateNextVersionItems()
                    } label: {
                        Label("Load More", systemImage: "arrow.down.circle")
                    }
                    .disabled(vm.isVersionItemsFullyLoaded)
                    Divider()
                    Button(role: .destructive) {
                        guard !vm.loading else { return }
                        vm.clearVersionItems()
                        vm.populateVersionIdentifiers {
                            vm.populateNextVersionItems()
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
            logger.info("[history-ui] appeared bundle=\(vm.package.software.bundleID) cachedIDs=\(vm.versionIdentifiers.count) cachedMetadata=\(vm.versionItems.count)")
            guard vm.versionItems.isEmpty else { return }
            vm.populateVersionIdentifiers {
                vm.populateNextVersionItems()
            }
        }
        .onDisappear {
            logger.info("[history-ui] disappeared bundle=\(vm.package.software.bundleID)")
            vm.cancelLoading()
        }
    }
}
