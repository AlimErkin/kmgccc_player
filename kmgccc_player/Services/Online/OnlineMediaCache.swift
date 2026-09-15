//
//  OnlineMediaCache.swift
//  kmgccc_player
//
//  Turns a remote song into a real file inside the online library.
//
//  WHY DOWNLOAD INSTEAD OF STREAM
//  ------------------------------
//  Playback in this app runs through AVAudioEngine: `AudioFilePreparationActor`
//  opens an `AVAudioFile`, and `AVAudioPlaybackService` schedules its buffers
//  while `AudioAnalysisHub` taps the same graph for the spectrum. `AVAudioFile`
//  cannot open an http URL, and an AVPlayer-based parallel path would have to
//  re-implement scheduling, gapless append and the analysis tap — and would
//  still lose the real-time visualizer, which is one of this app's signatures.
//
//  Materializing the bytes first keeps ONE playback path. Everything
//  downstream — seek, gapless, spectrum, lyrics timing, Now Playing, skins —
//  works on a remote song exactly as it does on a local one, with no new code.
//
//  The cost is a short buffer before the first note. `prefetch(...)` hides it
//  for the next track in the queue.
//

import Foundation

nonisolated enum OnlineMediaError: Error, LocalizedError {
    case noAudioSource(String)
    case download(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noAudioSource(let message): return message
        case .download(let message): return message
        case .cancelled: return NSLocalizedString("online.media.cancelled", comment: "")
        }
    }
}

actor OnlineMediaCache {
    static let shared = OnlineMediaCache()

    /// How much downloaded online audio to keep before evicting least-recently
    /// played files. Kept modest by default: these are cache bytes inside the
    /// online library, not something the listener curated.
    static let defaultBudgetBytes: Int64 = 4 * 1024 * 1024 * 1024

    private let session: URLSession
    private let catalog: LibraryCatalogClient
    private let netease: NeteaseClient
    private var budgetBytes: Int64

    /// In-flight downloads keyed by destination path, so a double-click and a
    /// prefetch never race to write the same file.
    private var inFlight: [String: Task<URL, Error>] = [:]

    init(
        catalog: LibraryCatalogClient = .shared,
        netease: NeteaseClient = .shared,
        budgetBytes: Int64 = OnlineMediaCache.defaultBudgetBytes
    ) {
        self.catalog = catalog
        self.netease = netease
        self.budgetBytes = budgetBytes
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        // A slow phone tether should stall the first note, not fail the track.
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    func setBudgetBytes(_ bytes: Int64) {
        budgetBytes = max(256 * 1024 * 1024, bytes)
    }

    // MARK: - Public API

    /// True when the audio is already on disk and playable right now.
    func isMaterialized(at destination: URL) -> Bool {
        guard let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return false
        }
        return size > 0
    }

    /// Ensure `destination` holds the audio for `origin`, downloading it if
    /// needed. Returns the file URL that `AVAudioFile` can open.
    ///
    /// Concurrent callers for the same destination share one download.
    func materialize(
        origin: RemoteAudioOrigin,
        destination: URL
    ) async throws -> URL {
        if isMaterialized(at: destination) {
            touch(destination)
            return destination
        }

        let key = destination.standardizedFileURL.path
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task<URL, Error> { [self] in
            try await download(origin: origin, destination: destination)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            let url = try await task.value
            await enforceBudget(near: destination)
            return url
        } catch {
            // Never leave a half-written file behind: the next attempt must not
            // mistake it for a complete download.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Best-effort warm-up for an upcoming track. Failures are silent — this is
    /// only ever an optimization.
    func prefetch(origin: RemoteAudioOrigin, destination: URL) async {
        guard !isMaterialized(at: destination) else { return }
        _ = try? await materialize(origin: origin, destination: destination)
    }

    // MARK: - Download

    private func download(origin: RemoteAudioOrigin, destination: URL) async throws -> URL {
        let sourceURL = try await resolveStreamURL(for: origin)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var request = URLRequest(url: sourceURL)
        if origin.provider == .netease {
            // NetEase CDN nodes reject requests without a plausible referer.
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        }

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch is CancellationError {
            throw OnlineMediaError.cancelled
        } catch {
            throw OnlineMediaError.download(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw OnlineMediaError.download("HTTP \(http.statusCode)")
        }

        // An expired or geo-blocked URL often answers 200 with a tiny error
        // body. Treat an implausibly small payload as a failure so it is not
        // cached as if it were music.
        let size = (try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 16 * 1024 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw OnlineMediaError.noAudioSource(
                NSLocalizedString("online.media.empty_payload", comment: "")
            )
        }

        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw OnlineMediaError.download(error.localizedDescription)
        }
        touch(destination)
        Log.info(
            "[Online] materialized \(origin.provider.rawValue):\(origin.remoteID) "
            + "(\(size / 1024) KiB)",
            category: .audio
        )
        return destination
    }

    /// A hint is reused while it is still valid; otherwise the provider is
    /// asked again. NetEase signs its URLs with an expiry, so a row synced
    /// yesterday can never be played from its stored URL.
    private func resolveStreamURL(for origin: RemoteAudioOrigin) async throws -> URL {
        if let fresh = origin.freshStreamURL() { return fresh }

        switch origin.provider {
        case .library:
            guard let song = try await catalog.song(id: origin.remoteID),
                  let url = song.streamURL
            else {
                throw OnlineMediaError.noAudioSource(
                    NSLocalizedString("online.media.catalog_no_audio", comment: "")
                )
            }
            return url
        case .netease:
            do {
                return try await netease.audioURL(songID: origin.remoteID)
            } catch let error as NeteaseError {
                throw OnlineMediaError.noAudioSource(
                    error.errorDescription ?? String(describing: error)
                )
            }
        }
    }

    // MARK: - Eviction

    private func touch(_ url: URL) {
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    /// Keeps the total size of materialized audio under the budget by removing
    /// the least recently played files first. Only files this cache wrote are
    /// considered: it walks the `Tracks` tree and looks at audio payloads.
    ///
    /// The walk runs on a detached task because `FileManager`'s directory
    /// enumerator cannot be iterated from an async context, and because a large
    /// library should not hold up this actor while the next track starts.
    private func enforceBudget(near destination: URL) async {
        // Tracks/<uuid>/audio.mp3 -> Tracks
        let tracksRoot = destination
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let keepPath = destination.standardizedFileURL.path
        let budget = budgetBytes

        let reclaimed = await Task.detached(priority: .utility) {
            Self.evict(in: tracksRoot, budgetBytes: budget, keepPath: keepPath)
        }.value

        if reclaimed > 0 {
            Log.info(
                "[Online] evicted \(reclaimed / 1024 / 1024) MiB of cached audio",
                category: .audio
            )
        }
    }

    private struct CachedAudioFile {
        let url: URL
        let size: Int64
        let accessed: Date
    }

    /// Synchronous LRU sweep. Returns the number of bytes reclaimed.
    private nonisolated static func evict(
        in tracksRoot: URL,
        budgetBytes: Int64,
        keepPath: String
    ) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: tracksRoot,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var entries: [CachedAudioFile] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("audio.") else { continue }
            guard let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentAccessDateKey, .isRegularFileKey,
            ]), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            total += size
            entries.append(
                CachedAudioFile(
                    url: url,
                    size: size,
                    accessed: values.contentAccessDate ?? .distantPast
                )
            )
        }

        guard total > budgetBytes else { return 0 }
        var reclaimed: Int64 = 0
        for entry in entries.sorted(by: { $0.accessed < $1.accessed }) {
            guard total - reclaimed > budgetBytes else { break }
            // Never evict the file just fetched for the track about to play.
            guard entry.url.standardizedFileURL.path != keepPath else { continue }
            try? fileManager.removeItem(at: entry.url)
            reclaimed += entry.size
        }
        return reclaimed
    }
}
