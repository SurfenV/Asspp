//
//  main.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Digger
import Logging
import SwiftUI

let logger = {
    LoggingSystem.bootstrap { LogManagerHandler(label: $0) }
    var logger = Logger(label: "wiki.qaq.asspp")
    logger.logLevel = .debug
    return logger
}()

APLogger.verbose = true
var applePackageLogger = Logger(label: "wiki.qaq.asspp.applepackage")
applePackageLogger.logLevel = .debug
APLogger.logger = applePackageLogger

let version = [
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
]
.compactMap { $0 ?? "?" }
.joined(separator: ".")

let bundleIdentifier = Bundle.main.bundleIdentifier!
logger.info("Asspp \(bundleIdentifier) \(version) starting up...")

private let availableDirectories = FileManager
    .default
    .urls(for: .documentDirectory, in: .userDomainMask)
let documentsDirectory = availableDirectories[0]
    .appendingPathComponent("Asspp")
do {
    let enumerator = FileManager.default.enumerator(atPath: documentsDirectory.path)
    while let file = enumerator?.nextObject() as? String {
        let path = documentsDirectory.appendingPathComponent(file)
        if let content = try? FileManager.default.contentsOfDirectory(atPath: path.path),
           content.isEmpty
        { try? FileManager.default.removeItem(at: path) }
    }
}

try? FileManager.default.createDirectory(
    at: documentsDirectory,
    withIntermediateDirectories: true,
    attributes: nil
)
let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent(bundleIdentifier)
do {
    let enumerator = FileManager.default.enumerator(atPath: temporaryDirectory.path)
    while let file = enumerator?.nextObject() as? String {
        let path = temporaryDirectory.appendingPathComponent(file)
        if let content = try? FileManager.default.contentsOfDirectory(atPath: path.path),
           content.isEmpty
        { try? FileManager.default.removeItem(at: path) }
    }
}

try? FileManager.default.createDirectory(
    at: temporaryDirectory,
    withIntermediateDirectories: true,
    attributes: nil
)

_ = ProcessInfo.processInfo.hostName

do {
    let deviceIdentifierKey = "wiki.qaq.asspp.device.identifier"
    if UserDefaults.standard.string(forKey: deviceIdentifierKey) == nil {
        do {
            let systemIdentifier = try ApplePackage.DeviceIdentifier.system()
            UserDefaults.standard.set(systemIdentifier, forKey: deviceIdentifierKey)
        } catch {
            logger.info("[?] failed to read system device identifier, using a random one")
            let randomIdentifier = ApplePackage.DeviceIdentifier.random()
            UserDefaults.standard.set(randomIdentifier, forKey: deviceIdentifierKey)
        }
    }
    let identifier = UserDefaults.standard.string(forKey: deviceIdentifierKey)!
    logger.info("device identifier configured (value redacted)")
    ApplePackage.Configuration.deviceIdentifier = identifier
}

DiggerManager.shared.maxConcurrentTasksCount = 3
DiggerManager.shared.startDownloadImmediately = true

Task.detached {
    _ = try await Installer(certificateAtPath: Installer.ca.path)
}

App.main()

#if canImport(UIKit)
    import UIKit

    class AppDelegate: NSObject, UIApplicationDelegate {
        var taskIdentifier: UIBackgroundTaskIdentifier = .invalid

        func applicationWillResignActive(_: UIApplication) {
            let task = UIApplication.shared.beginBackgroundTask(withName: "Install Service") {}
            taskIdentifier = task
        }

        func applicationWillEnterForeground(_: UIApplication) {
            UIApplication.shared.endBackgroundTask(taskIdentifier)
        }
    }
#endif

private struct App: SwiftUI.App {
    #if canImport(UIKit)
        @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            if #available(iOS 26.0, *) {
                NewMainView()
            } else {
                MainView()
            }
        }
    }
}
