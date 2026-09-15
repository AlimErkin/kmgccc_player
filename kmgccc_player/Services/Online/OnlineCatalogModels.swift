//
//  OnlineCatalogModels.swift
//  kmgccc_player
//
//  Wire models shared by the online catalog providers.
//
//  These types are the ONLY representation of a song that has not been
//  materialized on disk yet. They never enter SwiftData: a remote song becomes
//  a `Track` only after `OnlineCatalogSyncService` writes it into the online
//  library, and its audio stays absent until `OnlineMediaCache` downloads it.
//

import Foundation

// MARK: - Provider

nonisolated enum OnlineProvider: String, Codable, Sendable, CaseIterable {
    /// The in-house catalog, reached through the operator's own service.
    case library
    /// NetEase Cloud Music, reached with the listener's own QR-scanned account.
    case netease

    var displayName: String {
        switch self {
        case .library: return NSLocalizedString("online.provider.library", comment: "")
        case .netease: return NSLocalizedString("online.provider.netease", comment: "")
        }
    }
}

// MARK: - Catalog song

/// One song as the remote catalog describes it. Values are already normalized
/// by the provider client, so the sync service never has to know which backend
/// produced a row.
nonisolated struct OnlineSong: Codable, Sendable, Equatable, Identifiable {
    var provider: OnlineProvider
    /// Stable identifier inside `provider`. For the in-house catalog this is the
    /// backend song id; for NetEase it is the numeric song id.
    var remoteID: String

    var title: String
    /// Latin/original title when the catalog carries both writings. Kept apart
    /// from `title` so search can match either without overwriting the display
    /// name the catalog chose.
    var originalTitle: String?
    var artist: String
    var album: String
    var duration: Double

    var coverURL: URL?
    /// Direct audio URL when the catalog hands one out up front. NetEase signs
    /// its URLs with an expiry, so this is only ever treated as a hint.
    var streamURL: URL?
    /// Raw LRC text. The catalog ships lyrics with the song, so the lyrics
    /// pipeline never has to go searching for a remote track.
    var lyricLRC: String?

    var year: String?
    var language: String?

    var id: String { "\(provider.rawValue):\(remoteID)" }

    init(
        provider: OnlineProvider,
        remoteID: String,
        title: String,
        originalTitle: String? = nil,
        artist: String = "",
        album: String = "",
        duration: Double = 0,
        coverURL: URL? = nil,
        streamURL: URL? = nil,
        lyricLRC: String? = nil,
        year: String? = nil,
        language: String? = nil
    ) {
        self.provider = provider
        self.remoteID = remoteID
        self.title = title
        self.originalTitle = originalTitle
        self.artist = artist
        self.album = album
        self.duration = duration
        self.coverURL = coverURL
        self.streamURL = streamURL
        self.lyricLRC = lyricLRC
        self.year = year
        self.language = language
    }
}

// MARK: - Remote origin persisted on a Track

/// The durable half of `OnlineSong`, stored on a `Track` so playback can go
/// back to the provider for a fresh stream URL long after the sync that
/// created the row.
///
/// This is deliberately NOT a `TrackMediaLocator` case. The locator keeps
/// describing where the audio lives on disk (a managed path inside the online
/// library); this type only describes where those bytes came from. Keeping the
/// two apart is what lets every existing exhaustive switch over the locator
/// stay untouched.
nonisolated struct RemoteAudioOrigin: Codable, Sendable, Equatable {
    var provider: OnlineProvider
    var remoteID: String
    /// Last known direct audio URL. Re-resolved when missing or stale.
    var streamURLHint: URL?
    var streamURLFetchedAt: Date?
    var coverURL: URL?

    /// NetEase signs audio URLs with a short-lived token; the in-house catalog
    /// serves stable paths. Twenty minutes is comfortably inside NetEase's
    /// window while still reusing a hint across a normal listening session.
    static let streamHintLifetime: TimeInterval = 20 * 60

    init(
        provider: OnlineProvider,
        remoteID: String,
        streamURLHint: URL? = nil,
        streamURLFetchedAt: Date? = nil,
        coverURL: URL? = nil
    ) {
        self.provider = provider
        self.remoteID = remoteID
        self.streamURLHint = streamURLHint
        self.streamURLFetchedAt = streamURLFetchedAt
        self.coverURL = coverURL
    }

    init(song: OnlineSong, fetchedAt: Date? = nil) {
        self.init(
            provider: song.provider,
            remoteID: song.remoteID,
            streamURLHint: song.streamURL,
            streamURLFetchedAt: song.streamURL == nil ? nil : fetchedAt,
            coverURL: song.coverURL
        )
    }

    /// A usable hint, or nil when the provider must be asked again.
    func freshStreamURL(now: Date = Date()) -> URL? {
        guard let streamURLHint else { return nil }
        switch provider {
        case .library:
            // Catalog URLs are stable paths in the operator's media store.
            return streamURLHint
        case .netease:
            guard let streamURLFetchedAt,
                  now.timeIntervalSince(streamURLFetchedAt) < Self.streamHintLifetime
            else { return nil }
            return streamURLHint
        }
    }
}

// MARK: - Codable bridging on Track

nonisolated enum RemoteAudioOriginCoding {
    static func encode(_ origin: RemoteAudioOrigin?) -> Data? {
        guard let origin else { return nil }
        return try? JSONEncoder().encode(origin)
    }

    static func decode(_ data: Data?) -> RemoteAudioOrigin? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(RemoteAudioOrigin.self, from: data)
    }
}
