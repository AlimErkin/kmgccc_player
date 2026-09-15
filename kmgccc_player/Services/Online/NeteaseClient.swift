//
//  NeteaseClient.swift
//  kmgccc_player
//
//  Native NetEase Cloud Music client: QR sign-in, search, audio URL, lyrics.
//
//  Every endpoint used here is a plain unencrypted HTTP call — the QR handshake
//  and `song/enhance/player/url` do not go through weapi/eapi, so no crypto
//  shim or bundled helper process is needed. That is what lets this live in
//  Swift instead of behind another helper binary.
//
//  The listener signs in with their OWN account. The resulting MUSIC_U cookie
//  is held by `NeteaseAccountStore` in the keychain and never leaves the Mac.
//

import Foundation

// MARK: - Errors

nonisolated enum NeteaseError: Error, LocalizedError, Equatable {
    case transport(String)
    case badResponse
    case notSignedIn
    /// NetEase throttles audio-URL requests per account (code -462 / 405).
    /// Surfaced on its own because it is not a credential problem and retrying
    /// with a different account does not help.
    case rateLimited(Int)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .transport(let message):
            return message
        case .badResponse:
            return NSLocalizedString("netease.error.bad_response", comment: "")
        case .notSignedIn:
            return NSLocalizedString("netease.error.not_signed_in", comment: "")
        case .rateLimited(let code):
            return String(
                format: NSLocalizedString("netease.error.rate_limited", comment: ""),
                code
            )
        case .unavailable(let message):
            return message
        }
    }
}

// MARK: - QR sign-in state

nonisolated struct NeteaseQRSession: Sendable, Equatable {
    let key: String
    /// `https://music.163.com/login?codekey=…` — rendered as a QR code locally.
    let loginURL: URL
}

nonisolated enum NeteaseQRStatus: Sendable, Equatable {
    case waitingForScan
    case scannedAwaitingConfirm
    case expired
    case authorized(cookie: String)
    case other(code: Int, message: String)
}

nonisolated struct NeteaseAccount: Sendable, Equatable {
    var uid: String
    var nickname: String
    var avatarURL: URL?
    var vipType: Int
    var isVIP: Bool { vipType > 0 }
}

// MARK: - Client

actor NeteaseClient {
    static let shared = NeteaseClient()

    private static let origin = "https://music.163.com"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Cookie used for authenticated calls, e.g. `MUSIC_U=…`.
    private var cookie: String?

    /// Session used for ordinary API calls. Cookie handling is manual so a
    /// stale system-wide cookie can never override the account the listener
    /// actually signed in with.
    private let apiSession: URLSession
    /// Session used only for the QR handshake, where the authorization arrives
    /// as `Set-Cookie` and has to be captured.
    private let loginSession: URLSession
    private let loginCookieStorage = HTTPCookieStorage()

    init(cookie: String? = nil) {
        self.cookie = cookie

        let apiConfig = URLSessionConfiguration.ephemeral
        apiConfig.httpShouldSetCookies = false
        apiConfig.httpCookieAcceptPolicy = .never
        apiConfig.timeoutIntervalForRequest = 15
        apiConfig.waitsForConnectivity = false
        self.apiSession = URLSession(configuration: apiConfig)

        let loginConfig = URLSessionConfiguration.ephemeral
        loginConfig.httpShouldSetCookies = true
        loginConfig.httpCookieAcceptPolicy = .always
        loginConfig.httpCookieStorage = loginCookieStorage
        loginConfig.timeoutIntervalForRequest = 15
        self.loginSession = URLSession(configuration: loginConfig)
    }

    func updateCookie(_ newCookie: String?) {
        cookie = newCookie?.isEmpty == true ? nil : newCookie
    }

    var isSignedIn: Bool { cookie != nil }

    // MARK: - QR sign-in

    /// Step 1 — ask for a unikey and build the URL the NetEase phone app scans.
    func beginQRSignIn() async throws -> NeteaseQRSession {
        let json = try await getJSON(
            path: "/api/login/qrcode/unikey",
            query: ["type": "1", "noCache": Self.noCacheToken()],
            authenticated: false,
            session: loginSession
        )
        guard let unikey = json["unikey"] as? String, !unikey.isEmpty else {
            throw NeteaseError.badResponse
        }
        guard let loginURL = URL(string: "\(Self.origin)/login?codekey=\(unikey)") else {
            throw NeteaseError.badResponse
        }
        return NeteaseQRSession(key: unikey, loginURL: loginURL)
    }

    /// Step 2 — poll until the phone confirms. 800 expired / 801 waiting /
    /// 802 scanned, awaiting confirmation / 803 authorized.
    func pollQRSignIn(_ session: NeteaseQRSession) async throws -> NeteaseQRStatus {
        loginCookieStorage.removeCookies(since: .distantPast)
        let (data, response) = try await send(
            request(
                path: "/api/login/qrcode/client/login",
                query: ["type": "1", "key": session.key, "noCache": Self.noCacheToken()],
                authenticated: false
            ),
            on: loginSession
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int
        else { throw NeteaseError.badResponse }
        let message = (json["message"] as? String) ?? ""

        switch code {
        case 801: return .waitingForScan
        case 802: return .scannedAwaitingConfirm
        case 800: return .expired
        case 803:
            guard let musicU = extractMusicU(from: response) else {
                // Authorized but the cookie did not come through; the caller
                // keeps polling rather than reporting a false success.
                return .other(
                    code: code,
                    message: NSLocalizedString("netease.qr.authorized_no_cookie", comment: "")
                )
            }
            let value = "MUSIC_U=\(musicU)"
            cookie = value
            return .authorized(cookie: value)
        default:
            return .other(code: code, message: message)
        }
    }

    private func extractMusicU(from response: HTTPURLResponse) -> String? {
        // Prefer the session's cookie storage: `allHeaderFields` folds repeated
        // Set-Cookie lines into one comma-joined string, which splits the
        // signed token apart on some responses.
        if let url = URL(string: Self.origin),
           let stored = loginCookieStorage.cookies(for: url)?
               .first(where: { $0.name == "MUSIC_U" }) {
            return stored.value
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { out, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                out[key] = value
            }
        }
        guard let url = URL(string: Self.origin) else { return nil }
        return HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
            .first(where: { $0.name == "MUSIC_U" })?
            .value
    }

    func signOut() {
        cookie = nil
        loginCookieStorage.removeCookies(since: .distantPast)
    }

    // MARK: - Account

    func account() async throws -> NeteaseAccount? {
        guard cookie != nil else { throw NeteaseError.notSignedIn }
        var req = request(path: "/api/nuser/account/get", query: [:], authenticated: true)
        req.httpMethod = "POST"
        req.httpBody = Data()
        let (data, _) = try await send(req, on: apiSession)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw NeteaseError.badResponse }

        let accountObject = json["account"] as? [String: Any]
        let profile = json["profile"] as? [String: Any]
        guard let rawUID = accountObject?["id"] ?? profile?["userId"] else { return nil }
        let uid = String(describing: rawUID)
        guard uid != "0", !uid.isEmpty else { return nil }

        let vip = (accountObject?["vipType"] as? Int)
            ?? (profile?["vipType"] as? Int)
            ?? 0
        return NeteaseAccount(
            uid: uid,
            nickname: (profile?["nickname"] as? String) ?? "",
            avatarURL: (profile?["avatarUrl"] as? String).flatMap(URL.init(string:)),
            vipType: vip
        )
    }

    // MARK: - Catalog

    func searchSongs(_ keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [OnlineSong] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var req = request(path: "/api/cloudsearch/pc", query: [:], authenticated: true)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody([
            "s": trimmed,
            "type": "1",
            "limit": String(limit),
            "offset": String(offset),
        ])

        let (data, _) = try await send(req, on: apiSession)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let rows = result["songs"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap(Self.song(fromSearchRow:))
    }

    /// Songs in a NetEase playlist. `n=1000` asks for the full track list in one
    /// round trip; the authenticated form matters because personalized
    /// playlists resolve differently per account.
    func playlistSongs(playlistID: String, limit: Int = 1000) async throws -> [OnlineSong] {
        let json = try await getJSON(
            path: "/api/v3/playlist/detail",
            query: ["id": playlistID, "n": String(limit)],
            authenticated: true,
            session: apiSession
        )
        guard let playlist = json["playlist"] as? [String: Any] else { return [] }
        if let tracks = playlist["tracks"] as? [[String: Any]], !tracks.isEmpty {
            return tracks.compactMap(Self.song(fromSearchRow:))
        }
        return []
    }

    struct NeteasePlaylist: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var coverURL: URL?
        public var trackCount: Int
    }

    /// The signed-in listener's own playlists (created and favourited).
    func userPlaylists(uid: String, limit: Int = 100) async throws -> [NeteasePlaylist] {
        guard cookie != nil else { throw NeteaseError.notSignedIn }
        let json = try await getJSON(
            path: "/api/user/playlist",
            query: ["uid": uid, "limit": String(limit), "offset": "0"],
            authenticated: true,
            session: apiSession
        )
        guard let rows = json["playlist"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let rawID = row["id"] else { return nil }
            return NeteasePlaylist(
                id: String(describing: rawID),
                name: (row["name"] as? String) ?? "",
                coverURL: (row["coverImgUrl"] as? String).flatMap(URL.init(string:)),
                trackCount: (row["trackCount"] as? Int) ?? 0
            )
        }
    }

    func lyric(songID: String) async throws -> String? {
        let json = try await getJSON(
            path: "/api/song/lyric",
            query: ["id": songID, "lv": "-1", "kv": "-1", "tv": "-1"],
            authenticated: true,
            session: apiSession
        )
        let original = ((json["lrc"] as? [String: Any])?["lyric"] as? String) ?? ""
        return original.isEmpty ? nil : original
    }

    // MARK: - Audio

    /// Resolve a playable audio URL, best quality first.
    ///
    /// Anonymous is tried first on purpose: it covers most of the catalog and
    /// keeps the listener's account away from the rate limiter. The signed-in
    /// attempt is only needed for VIP-exclusive tracks.
    func audioURL(songID: String, preferredBitrates: [Int] = [320_000, 192_000, 128_000]) async throws -> URL {
        var lastError: NeteaseError = .unavailable(
            NSLocalizedString("netease.error.no_audio", comment: "")
        )

        for authenticated in (cookie == nil ? [false] : [false, true]) {
            for bitrate in preferredBitrates {
                do {
                    if let url = try await fetchAudioURL(
                        songID: songID,
                        bitrate: bitrate,
                        authenticated: authenticated
                    ) {
                        return url
                    }
                } catch let error as NeteaseError {
                    // Throttling is account-wide: stop hammering it, and let the
                    // caller tell the listener what actually happened.
                    if case .rateLimited = error { throw error }
                    lastError = error
                }
            }
        }
        throw lastError
    }

    private func fetchAudioURL(songID: String, bitrate: Int, authenticated: Bool) async throws -> URL? {
        let json = try await getJSON(
            path: "/api/song/enhance/player/url",
            query: ["ids": "[\(songID)]", "br": String(bitrate)],
            authenticated: authenticated,
            session: apiSession
        )
        if let code = json["code"] as? Int, code == -462 || code == 405 {
            throw NeteaseError.rateLimited(code)
        }
        guard let rows = json["data"] as? [[String: Any]],
              let first = rows.first,
              let raw = first["url"] as? String,
              !raw.isEmpty
        else { return nil }
        // NetEase still hands out plain-http CDN hosts for some tracks. The app
        // declares an ATS exception for those hosts rather than silently
        // failing, but prefer https whenever the same host serves it.
        return URL(string: raw.replacingOccurrences(of: "http://", with: "https://"))
            ?? URL(string: raw)
    }

    // MARK: - Row mapping

    private static func song(fromSearchRow row: [String: Any]) -> OnlineSong? {
        guard let rawID = row["id"] else { return nil }
        let artists = (row["ar"] as? [[String: Any]] ?? row["artists"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
            .joined(separator: " / ")
        let albumObject = (row["al"] as? [String: Any]) ?? (row["album"] as? [String: Any])
        // NetEase reports duration in milliseconds.
        let milliseconds = (row["dt"] as? Double) ?? (row["duration"] as? Double) ?? 0
        return OnlineSong(
            provider: .netease,
            remoteID: String(describing: rawID),
            title: (row["name"] as? String) ?? "",
            artist: artists,
            album: (albumObject?["name"] as? String) ?? "",
            duration: milliseconds / 1000,
            coverURL: (albumObject?["picUrl"] as? String).flatMap(URL.init(string:))
        )
    }

    // MARK: - Transport

    private static func noCacheToken() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000))
    }

    private func formBody(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private func request(
        path: String,
        query: [String: String],
        authenticated: Bool
    ) -> URLRequest {
        var components = URLComponents(string: Self.origin + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: components.url!)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("\(Self.origin)/", forHTTPHeaderField: "Referer")
        req.setValue(Self.origin, forHTTPHeaderField: "Origin")
        // `os=pc` is what makes the audio endpoint hand back real CDN paths.
        if authenticated, let cookie {
            req.setValue("\(cookie); os=pc", forHTTPHeaderField: "Cookie")
        } else {
            req.setValue("os=pc", forHTTPHeaderField: "Cookie")
        }
        return req
    }

    private func getJSON(
        path: String,
        query: [String: String],
        authenticated: Bool,
        session: URLSession
    ) async throws -> [String: Any] {
        let (data, _) = try await send(
            request(path: path, query: query, authenticated: authenticated),
            on: session
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NeteaseError.badResponse
        }
        return json
    }

    private func send(_ request: URLRequest, on session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NeteaseError.badResponse }
            return (data, http)
        } catch let error as NeteaseError {
            throw error
        } catch {
            throw NeteaseError.transport(error.localizedDescription)
        }
    }
}
