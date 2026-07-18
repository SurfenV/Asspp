//
//  LogView.swift
//  Asspp
//

import SwiftUI
import UIKit

struct LogView: View {
    @State private var unlocked = false
    @State private var logText = ""
    @State private var showShareSheet = false
    @State private var showCopiedAlert = false

    var body: some View {
        Group {
            if unlocked {
                ScrollView {
                    Text(logText.isEmpty ? "No diagnostic logs yet." : logText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 42))
                    Text("Diagnostic logs may contain app identifiers, version IDs, regions, status codes, and error messages. Passwords, tokens, cookies, account IDs, and the device GUID are redacted.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    Button("Show Logs") {
                        unlocked = true
                        refresh()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .navigationTitle("Diagnostic Logs")
        .toolbar {
            if unlocked {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button {
                        UIPasteboard.general.string = LogManager.shared.text()
                        showCopiedAlert = true
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        LogManager.shared.clear()
                        refresh()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityView(activityItems: [LogManager.shared.exportURL()])
        }
        .alert("Copied", isPresented: $showCopiedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The diagnostic log was copied to the clipboard.")
        }
    }

    private func refresh() {
        logText = LogManager.shared.text()
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
