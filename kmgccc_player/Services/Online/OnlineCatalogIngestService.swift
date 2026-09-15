//
//  OnlineCatalogIngestService.swift
//  kmgccc_player
//
//  Turns catalog rows into ordinary library tracks.
//
//  An online song becomes a real `Track` inside the online library, with a
//  managed locator pointing at the place its audio will live. The audio itself
//  stays absent until `OnlineMediaCache` fetches it on first play, so adding a
//  thousand songs costs metadata, a cover thumbnail and lyrics — not a
//  thousand downloads.
//
//  Because the row is an ordinary `Track`, every screen in the app — the track
//  list, artist and album pages, search, playlists, Now Playing, the skins, the
//  lyrics pipeline and the spectrum — renders and plays it with no new code.
//

import CryptoKit
import Foundation

@MainActor
final class OnlineCatalogIngestService {
    private let repository: any LibraryRepositoryProtocol
    private let paths: LibraryPaths
    private let session: URLSession

    init(repository: any LibraryRepositoryProtocol, paths: LibraryPaths) {
        self.repository = repository
        self.paths = paths
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config)
    }

    // MARK: - Identity

    /// A stable UUID for one catalog row, so re-adding a song updates the
    /// existing track instead of creating a duplicate. Derived like a v5 UUID:
    /// SHA-256 over "provider:id", with the version and variant bits set.
    nonisolated static func trackID(provider: OnlineProvider, remoteID: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(provider.rawValue):\(remoteID)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Where a given online track's audio is materialized. The extension is
    /// fixed at `.mp3` because both providers are asked for mp3-tier audio;
    /// a lossless option would have to record its own extension here.
    nonisolated static func audioFileName() -> String { "audio.mp3" }

    nonisolated static func relativeAudioPath(for id: UUID) -> String {
        "Tracks/\(id.uuidString)/\(audioFileName())"
    }

    // MARK: - Ingestion

    @discardableResult
    func ingest(_ songs: [OnlineSong]) async -> [Track] {
        guard !songs.isEmpty else { return [] }

        // Collapse duplicates inside one batch (a song can appear in several
        // playlists) before touching the repository.
        var unique: [UUID: OnlineSong] = [:]
        var order: [UUID] = []
        for song in songs {
            let id = Self.trackID(provider: song.provider, remoteID: song.remoteID)
            if unique[id] == nil { order.append(id) }
            unique[id] = song
        }

        let existing = await repository.fetchTracks(ids: order)
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        var created: [Track] = []
        var updated: [Track] = []
        var result: [Track] = []

        for id in order {
            guard let song = unique[id] else { continue }
            let ttml = await Self.ttml(from: song.lyricLRC)
            let artwork = await artworkData(for: song)

            if let track = existingByID[id] {
                apply(song, to: track, ttml: ttml, artwork: artwork)
                updated.append(track)
                result.append(track)
            } else {
                let track = makeTrack(from: song, id: id, ttml: ttml, artwork: artwork)
                created.append(track)
                result.append(track)
            }
        }

        if !created.isEmpty {
            await repository.addTracks(created)
            _ = await repository.persistTrackMetaLyricsAndArtwork(
                created,
                reason: "online-catalog-ingest"
            )
        }
        if !updated.isEmpty {
            _ = await repository.persistTrackMetaLyricsAndArtwork(
                updated,
                reason: "online-catalog-refresh"
            )
        }

        Log.info(
            "[Online] ingested \(created.count) new / \(updated.count) refreshed tracks",
            category: .library
        )
        return result
    }

    // MARK: - Track construction

    private func makeTrack(
        from song: OnlineSong,
        id: UUID,
        ttml: String?,
        artwork: Data?
    ) -> Track {
        let relativePath = Self.relativeAudioPath(for: id)
        let track = Track(
            id: id,
            title: song.title,
            artist: song.artist,
            album: song.album,
            language: song.language ?? "",
            releaseDate: Self.releaseDate(from: song.year),
            metadataSource: "online:\(song.provider.rawValue)",
            metadataFetchedAt: Date(),
            albumGroupKey: Self.albumGroupKey(for: song),
            duration: song.duration,
            // Online rows carry no bookmark: their audio is addressed by the
            // managed relative path below.
            fileBookmarkData: Data(),
            originalFilePath: "",
            libraryRelativePath: relativePath,
            mediaLocator: .managed(libraryRelativePath: relativePath),
            // The audio is not on disk yet. `notDownloaded` is the existing
            // recoverable state for exactly this situation, so the UI already
            // knows how to present it and playback still proceeds.
            availability: .notDownloaded,
            artworkData: artwork,
            ttmlLyricText: ttml,
            libraryRootSnapshot: paths.rootURL.path,
            audioFileName: Self.audioFileName(),
            artworkFileName: artwork == nil ? nil : LibraryPaths.preferredTrackArtworkFileName,
            ttmlLyricsFileName: ttml == nil ? nil : "lyrics.ttml"
        )
        track.remoteOrigin = RemoteAudioOrigin(song: song, fetchedAt: Date())
        return track
    }

    private func apply(_ song: OnlineSong, to track: Track, ttml: String?, artwork: Data?) {
        track.title = song.title
        track.artist = song.artist
        track.album = song.album
        if song.duration > 0 { track.duration = song.duration }
        if let language = song.language, !language.isEmpty { track.language = language }
        if let ttml, track.ttmlLyricText?.isEmpty != false {
            track.ttmlLyricText = ttml
            track.ttmlLyricsFileName = "lyrics.ttml"
        }
        if let artwork, track.artworkData == nil {
            track.artworkData = artwork
            track.artworkFileName = LibraryPaths.preferredTrackArtworkFileName
        }
        // Refresh provenance so a newly issued stream URL replaces a stale one.
        track.remoteOrigin = RemoteAudioOrigin(song: song, fetchedAt: Date())
    }

    // MARK: - Derived values

    private static func albumGroupKey(for song: OnlineSong) -> String {
        let album = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !album.isEmpty else { return "" }
        return "\(album.lowercased())|\(artist.lowercased())"
    }

    private static func releaseDate(from year: String?) -> Date? {
        guard let year, let value = Int(year.prefix(4)), value > 1000 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: value))
    }

    /// Reuses the app's existing LRC pipeline so remote lyrics render through
    /// the same native path as local ones, rather than a second parser.
    private static func ttml(from lrc: String?) async -> String? {
        guard let lrc, !lrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try? await LRCConverterService.shared.convertToTTML(lrcContent: lrc)
    }

    private func artworkData(for song: OnlineSong) async -> Data? {
        guard let url = song.coverURL else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count > 512
            else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
