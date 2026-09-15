//
//  LibraryCatalogClient.swift
//  kmgccc_player
//
//  Client for the in-house catalog, reached through the operator's own service
//  rather than the upstream backend directly.
//
//  Going through that service is deliberate: it already owns the catalog
//  snapshot, the multi-writing search index (Uyghur / Latin / Chinese / artist
//  spellings) and the paging workarounds the upstream list endpoints need. The
//  app therefore needs exactly one HTTP client and no upstream token.
//

import Foundation

// MARK: - Errors

nonisolated enum CatalogError: Error, LocalizedError {
    case notConfigured
    case transport(String)
    case badResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return NSLocalizedString("catalog.error.not_configured", comment: "")
        case .transport(let message):
            return message
        case .badResponse:
            return NSLocalizedString("catalog.error.bad_response", comment: "")
        case .http(let status, let message):
            return message.isEmpty ? "HTTP \(status)" : "HTTP \(status) — \(message)"
        }
    }
}

// MARK: - Wire shapes

/// Exactly what `/api/app/*` returns for one song. Field names are chosen so
/// the service can project the catalog row directly, without the app having to
/// know about upstream quirks.
nonisolated struct CatalogSongDTO: Codable, Sendable {
    var id: String
    var title: String
    var originalTitle: String?
    var artist: String?
    var artistID: String?
    var album: String?
    var duration: Double?
    var cover: String?
    var mp3: String?
    var lyric: String?
    var year: String?
    var language: String?

    var asOnlineSong: OnlineSong {
        OnlineSong(
            provider: .library,
            remoteID: id,
            title: title,
            originalTitle: originalTitle,
            artist: artist ?? "",
            album: album ?? "",
            duration: duration ?? 0,
            coverURL: cover.flatMap(Self.url(from:)),
            streamURL: mp3.flatMap(Self.url(from:)),
            lyricLRC: (lyric?.isEmpty == false) ? lyric : nil,
            year: year,
            language: language
        )
    }

    private static func url(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }
}

nonisolated struct CatalogArtistDTO: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var originalName: String?
    var image: String?
    var songCount: Int?
}

nonisolated struct CatalogPlaylistDTO: Codable, Sendable, Identifiable {
    var id: String
    var title: String
    var cover: String?
    var songCount: Int?
}

// MARK: - Configuration

nonisolated struct CatalogEndpoint: Sendable, Equatable {
    var baseURL: URL
    /// Optional shared token, sent as `X-App-Token`. Empty when the service is
    /// reachable without one.
    var token: String

    init?(rawBaseURL: String, token: String = "") {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            ? trimmed
            : "https://" + trimmed
        guard let url = URL(string: normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized)
        else { return nil }
        self.baseURL = url
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Client

actor LibraryCatalogClient {
    static let shared = LibraryCatalogClient()

    private var endpoint: CatalogEndpoint?
    private let session: URLSession

    init(endpoint: CatalogEndpoint? = nil) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func configure(_ newEndpoint: CatalogEndpoint?) {
        endpoint = newEndpoint
    }

    var isConfigured: Bool { endpoint != nil }

    // MARK: - Reachability

    struct Health: Codable, Sendable {
        var ok: Bool
        var name: String?
        var songCount: Int?
    }

    func ping() async throws -> Health {
        try await get("/api/app/ping", query: [:])
    }

    // MARK: - Browsing

    private struct SongsEnvelope: Codable { var songs: [CatalogSongDTO] }
    private struct SearchEnvelope: Codable {
        var songs: [CatalogSongDTO]?
        var artists: [CatalogArtistDTO]?
    }
    private struct ArtistsEnvelope: Codable { var artists: [CatalogArtistDTO] }
    private struct PlaylistsEnvelope: Codable { var playlists: [CatalogPlaylistDTO] }
    private struct PlaylistEnvelope: Codable {
        var playlist: CatalogPlaylistDTO?
        var songs: [CatalogSongDTO]
    }
    private struct SongEnvelope: Codable { var song: CatalogSongDTO? }

    struct SearchResults: Sendable {
        var songs: [OnlineSong]
        var artists: [CatalogArtistDTO]
    }

    func search(_ keyword: String, limit: Int = 60) async throws -> SearchResults {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResults(songs: [], artists: []) }
        let envelope: SearchEnvelope = try await get(
            "/api/app/search",
            query: ["q": trimmed, "limit": String(limit)]
        )
        return SearchResults(
            songs: (envelope.songs ?? []).map(\.asOnlineSong),
            artists: envelope.artists ?? []
        )
    }

    /// One song with everything playback needs: audio URL, cover and lyrics.
    func song(id: String) async throws -> OnlineSong? {
        let envelope: SongEnvelope = try await get("/api/app/song", query: ["id": id])
        return envelope.song?.asOnlineSong
    }

    func artists(limit: Int = 200, offset: Int = 0) async throws -> [CatalogArtistDTO] {
        let envelope: ArtistsEnvelope = try await get(
            "/api/app/artists",
            query: ["limit": String(limit), "offset": String(offset)]
        )
        return envelope.artists
    }

    func songs(artistID: String, limit: Int = 200) async throws -> [OnlineSong] {
        let envelope: SongsEnvelope = try await get(
            "/api/app/artist-songs",
            query: ["id": artistID, "limit": String(limit)]
        )
        return envelope.songs.map(\.asOnlineSong)
    }

    func playlists() async throws -> [CatalogPlaylistDTO] {
        let envelope: PlaylistsEnvelope = try await get("/api/app/playlists", query: [:])
        return envelope.playlists
    }

    func playlist(id: String) async throws -> (info: CatalogPlaylistDTO?, songs: [OnlineSong]) {
        let envelope: PlaylistEnvelope = try await get("/api/app/playlist", query: ["id": id])
        return (envelope.playlist, envelope.songs.map(\.asOnlineSong))
    }

    /// Paged feed used by the initial catalog sync.
    struct CatalogPage: Sendable {
        var songs: [OnlineSong]
        var nextCursor: String?
        var total: Int?
    }

    private struct CatalogPageEnvelope: Codable {
        var songs: [CatalogSongDTO]
        var nextCursor: String?
        var total: Int?
    }

    func catalogPage(cursor: String?, limit: Int = 500) async throws -> CatalogPage {
        var query = ["limit": String(limit)]
        if let cursor, !cursor.isEmpty { query["cursor"] = cursor }
        let envelope: CatalogPageEnvelope = try await get("/api/app/catalog", query: query)
        return CatalogPage(
            songs: envelope.songs.map(\.asOnlineSong),
            nextCursor: envelope.nextCursor,
            total: envelope.total
        )
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        guard let endpoint else { throw CatalogError.notConfigured }
        guard var components = URLComponents(
            url: endpoint.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw CatalogError.notConfigured }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw CatalogError.notConfigured }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !endpoint.token.isEmpty {
            request.setValue(endpoint.token, forHTTPHeaderField: "X-App-Token")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CatalogError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CatalogError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            // The service answers with `{ ok: false, error }` for expected
            // failures; surface that text instead of a bare status code.
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["error"] as? String } ?? ""
            throw CatalogError.http(http.statusCode, message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CatalogError.badResponse
        }
    }
}
