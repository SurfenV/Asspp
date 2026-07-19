//
//  AppStore.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Combine
import Foundation

class AppStore: ObservableObject {
    var cancellables: Set<AnyCancellable> = .init()

    @MainActor
    @PublishedPersist(
        key: "Accounts",
        defaultValue: [],
        keychain: "wiki.qaq.Asspp.Accounts"
    )
    var accounts: [UserAccount]

    @MainActor
    @PublishedPersist(key: "DemoMode", defaultValue: false)
    var demoMode: Bool

    static let this = AppStore()
    private init() {}

    @MainActor
    @discardableResult
    func save(email: String, account: ApplePackage.Account) -> UserAccount {
        let account = UserAccount(account: account)
        accounts = (accounts.filter { $0.account.email != email } + [account])
            .sorted { $0.account.email < $1.account.email }
        return account
    }

    @MainActor
    func delete(id: UserAccount.ID) {
        accounts = accounts.filter { $0.id != id }
    }

    @MainActor
    var possibleRegions: Set<String> {
        Set(accounts.compactMap { ApplePackage.Configuration.countryCode(for: $0.account.store) })
    }

    @MainActor
    func eligibleAccounts(for region: String) -> [UserAccount] {
        accounts.filter { ApplePackage.Configuration.countryCode(for: $0.account.store) == region }
    }

    @MainActor
    func accountSnapshot(id: String) throws -> UserAccount {
        logger.info("[account-snapshot] resolving account")
        guard let account = accounts.first(where: { $0.id == id }) else {
            logger.error("[account-snapshot] account not found")
            throw AuthenticationError.accountNotFound
        }
        logger.info("[account-snapshot] loaded store=\(account.account.store) pod=\(account.account.pod ?? "missing")")
        return account
    }

    @MainActor
    func saveAccountSnapshot(_ account: UserAccount, id: String) {
        logger.info("[account-snapshot] write-back begin pod=\(account.account.pod ?? "missing")")
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else {
            logger.warning("[account-snapshot] write-back skipped: account removed")
            return
        }
        accounts[idx] = account
        logger.info("[account-snapshot] write-back completed")
    }

    func withAccount<T>(id: String, _ body: (inout UserAccount) async throws -> T) async throws -> T {
        logger.info("[account-transaction] resolving account")
        guard var account = await accounts.first(where: { $0.id == id }) else {
            logger.error("[account-transaction] account not found")
            throw AuthenticationError.accountNotFound
        }
        logger.info("[account-transaction] body begin store=\(account.account.store) pod=\(account.account.pod ?? "missing")")
        let result = try await body(&account)
        logger.info("[account-transaction] body returned; scheduling account write-back")
        let updatedAccount = account
        await MainActor.run {
            logger.info("[account-transaction] main-actor write-back begin")
            guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[idx] = updatedAccount
            logger.info("[account-transaction] main-actor write-back completed")
        }
        logger.info("[account-transaction] completed")
        return result
    }
}
