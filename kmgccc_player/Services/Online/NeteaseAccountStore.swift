//
//  NeteaseAccountStore.swift
//  kmgccc_player
//
//  Owns the listener's NetEase sign-in for the whole process.
//
//  Storage follows the same shape this app already uses for its telemetry
//  signing key: a 0600 file under Application Support rather than the keychain,
//  so no `keychain-access-groups` entitlement is needed and a locally built
//  copy never triggers a keychain prompt on every launch.
//
//  The cookie never leaves the Mac. It is sent only to music.163.com.
//

import Foundation
import Observation

@Observable
@MainActor
final class NeteaseAccountStore {
    static let shared = NeteaseAccountStore()

    private(set) var account: NeteaseAccount?
    private(set) var isSignedIn: Bool = false
    /// Last failure worth showing next to the sign-in button.
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private var cookie: String?
    @ObservationIgnored private let client: NeteaseClient

    init(client: NeteaseClient = .shared) {
        self.client = client
        let persisted = Self.load()
        cookie = persisted?.cookie
        account = persisted?.account
        isSignedIn = persisted?.cookie != nil
        if let cookie {
            Task { await client.updateCookie(cookie) }
        }
    }

    // MARK: - Sign-in lifecycle

    func adopt(cookie newCookie: String) async {
        cookie = newCookie
        isSignedIn = true
        lastErrorMessage = nil
        await client.updateCookie(newCookie)
        await refreshAccount()
        persist()
    }

    func signOut() async {
        cookie = nil
        account = nil
        isSignedIn = false
        lastErrorMessage = nil
        await client.signOut()
        Self.removeFile()
    }

    /// Re-reads the profile so the settings pane can show who is signed in and
    /// whether their membership is still active.
    func refreshAccount() async {
        guard cookie != nil else { return }
        do {
            let fetched = try await client.account()
            if let fetched {
                account = fetched
                lastErrorMessage = nil
            } else {
                // The cookie no longer identifies anybody: treat it as signed
                // out instead of leaving a dead credential in place.
                await signOut()
                lastErrorMessage = NSLocalizedString("netease.error.session_expired", comment: "")
            }
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        persist()
    }

    func reportError(_ message: String?) {
        lastErrorMessage = message
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var cookie: String?
        var uid: String?
        var nickname: String?
        var avatarURL: URL?
        var vipType: Int?

        var account: NeteaseAccount? {
            guard let uid, !uid.isEmpty else { return nil }
            return NeteaseAccount(
                uid: uid,
                nickname: nickname ?? "",
                avatarURL: avatarURL,
                vipType: vipType ?? 0
            )
        }
    }

    private static var directoryURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "kmgccc_player"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Online", isDirectory: true)
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent("netease-account.json")
    }

    private static func load() -> Persisted? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Persisted.self, from: data)
    }

    private static func removeFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        let payload = Persisted(
            cookie: cookie,
            uid: account?.uid,
            nickname: account?.nickname,
            avatarURL: account?.avatarURL,
            vipType: account?.vipType
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        do {
            try FileManager.default.createDirectory(
                at: Self.directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: Self.fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.fileURL.path
            )
        } catch {
            Log.error("[Online] failed to persist NetEase account: \(error)", category: .general)
        }
    }
}
