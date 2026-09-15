//
//  OnlineBrowserSheet.swift
//  kmgccc_player
//
//  Find songs in the in-house catalog or on NetEase, and bring them into the
//  library.
//
//  This is the only genuinely new screen the online sources need. Everything
//  after the import — browsing, artists, albums, playlists, Now Playing,
//  lyrics, the spectrum — is the app's existing UI, because an imported
//  catalog row is an ordinary `Track`.
//

import SwiftUI

@MainActor
struct OnlineBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var account = NeteaseAccountStore.shared

    @State private var provider: OnlineProvider = .library
    @State private var query: String = ""
    @State private var songs: [OnlineSong] = []

    /// Collections offered by whichever provider is active: the catalog's
    /// curated 专题, or the listener's own NetEase playlists. One shape so the
    /// strip below does not care which source produced it.
    private struct Collection: Identifiable, Equatable {
        let id: String
        let title: String
        let provider: OnlineProvider
    }
    @State private var catalogCollections: [Collection] = []
    @State private var neteaseCollections: [Collection] = []
    @State private var isSearching = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 540)
        .background(ThemedBaseBackgroundColorView())
        .tint(themeStore.accentColor)
        .onAppear {
            configureClient()
            if provider == .netease { Task { await loadNeteaseCollections() } }
        }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("在线音乐")
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 0)
                Picker("", selection: $provider) {
                    Text("曲库").tag(OnlineProvider.library)
                    Text("网易云").tag(OnlineProvider.netease)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .onChange(of: provider) { _, _ in
                    songs = []
                    message = nil
                    if !query.isEmpty { scheduleSearch() }
                    if provider == .netease { Task { await loadNeteaseCollections() } }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜歌名或歌手", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { scheduleSearch(immediately: true) }
                    .onChange(of: query) { _, _ in scheduleSearch() }
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            if !collections.isEmpty {
                collectionStrip
            }
        }
        .padding(16)
    }

    private var collections: [Collection] {
        provider == .library ? catalogCollections : neteaseCollections
    }

    /// One tap pulls a whole collection into the library — the catalog's 专题,
    /// or a playlist from the listener's own NetEase account.
    private var collectionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(collections) { collection in
                    Button {
                        Task { await importCollection(collection) }
                    } label: {
                        Text(collection.title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(themeStore.accentColor.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                }
            }
        }
        .frame(height: 30)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let message {
            centeredNotice(message, systemImage: "exclamationmark.triangle")
        } else if provider == .netease && !account.isSignedIn {
            centeredNotice("先去「设置 › 在线音乐」扫码登录网易云", systemImage: "qrcode")
        } else if provider == .library && settings.onlineCatalogEndpoint == nil {
            centeredNotice("先去「设置 › 在线音乐」填曲库服务地址", systemImage: "link")
        } else if songs.isEmpty {
            centeredNotice(
                query.isEmpty ? "搜点什么" : (isSearching ? "搜索中…" : "没找到"),
                systemImage: "music.note.list"
            )
        } else {
            List(songs) { song in
                OnlineSongRow(song: song) {
                    Task { await playNow(song) }
                } onAdd: {
                    Task { await addToLibrary([song]) }
                }
                .listRowSeparator(.visible)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func centeredNotice(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: SettingsStyleTokens.rowValueFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if isWorking {
                ProgressView().controlSize(.small)
                Text("正在加入曲库…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if !songs.isEmpty {
                Text("\(songs.count) 首")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !songs.isEmpty {
                Button("全部加入曲库") {
                    Task { await addToLibrary(songs) }
                }
                .disabled(isWorking)
            }
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func configureClient() {
        let endpoint = settings.onlineCatalogEndpoint
        Task {
            await LibraryCatalogClient.shared.configure(endpoint)
            guard endpoint != nil else { return }
            // Load the curated collections once, quietly: a service without
            // them is normal, not an error worth interrupting the search for.
            if let fetched = try? await LibraryCatalogClient.shared.playlists() {
                catalogCollections = fetched.map {
                    Collection(id: $0.id, title: $0.title, provider: .library)
                }
            }
        }
    }

    /// Debounced so typing does not fire a request per keystroke. Remote search
    /// is a network round trip, unlike the local index.
    private func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            songs = []
            isSearching = false
            return
        }
        isSearching = true
        message = nil
        searchTask = Task {
            if !immediately {
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
            }
            await runSearch(keyword)
        }
    }

    private func runSearch(_ keyword: String) async {
        do {
            let found: [OnlineSong]
            switch provider {
            case .library:
                found = try await LibraryCatalogClient.shared.search(keyword).songs
            case .netease:
                found = try await NeteaseClient.shared.searchSongs(keyword)
            }
            guard !Task.isCancelled else { return }
            songs = found
            message = nil
        } catch {
            guard !Task.isCancelled else { return }
            songs = []
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isSearching = false
    }

    private func addToLibrary(_ selection: [OnlineSong]) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        _ = await libraryVM.ingestOnlineSongs(await hydrated(selection))
    }

    private func playNow(_ song: OnlineSong) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        let tracks = await libraryVM.ingestOnlineSongs(await hydrated([song]))
        guard let track = tracks.first else { return }
        // The audio is fetched by the preparation actor; this returns at once
        // and the track starts when the bytes land.
        playbackCoordinator.playTrack(track, inQueueFrom: tracks)
    }

    /// The listener's own NetEase playlists — "my music", daily picks and the
    /// rest. This is what most people mean by listening to what is in their
    /// NetEase account, so it is loaded as soon as that tab is usable.
    private func loadNeteaseCollections() async {
        guard neteaseCollections.isEmpty, account.isSignedIn else { return }
        guard let uid = account.account?.uid, !uid.isEmpty else { return }
        guard let fetched = try? await NeteaseClient.shared.userPlaylists(uid: uid) else { return }
        neteaseCollections = fetched.map {
            Collection(id: $0.id, title: $0.name, provider: .netease)
        }
    }

    private func importCollection(_ collection: Collection) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let fetched: [OnlineSong]
            switch collection.provider {
            case .library:
                fetched = try await LibraryCatalogClient.shared.playlist(id: collection.id).songs
            case .netease:
                fetched = try await NeteaseClient.shared.playlistSongs(playlistID: collection.id)
            }
            // Lyrics and catalog audio URLs are filled in here; a NetEase audio
            // URL is still left to play time because it expires.
            let ready = await hydrated(fetched)
            _ = await libraryVM.ingestOnlineSongs(ready, intoPlaylistNamed: collection.title)
            message = nil
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Search results carry no audio URL or lyrics — those live on the detail
    /// call. Fill them in before import so a freshly added track can play and
    /// show lyrics without a second trip.
    private func hydrated(_ selection: [OnlineSong]) async -> [OnlineSong] {
        var out: [OnlineSong] = []
        out.reserveCapacity(selection.count)
        for song in selection {
            switch song.provider {
            case .library:
                if song.streamURL == nil,
                   let detailed = try? await LibraryCatalogClient.shared.song(id: song.remoteID) {
                    out.append(detailed)
                } else {
                    out.append(song)
                }
            case .netease:
                var copy = song
                // The audio URL is deliberately NOT resolved here: NetEase signs
                // it with a short expiry, so it is fetched at play time instead.
                copy.lyricLRC = try? await NeteaseClient.shared.lyric(songID: song.remoteID)
                out.append(copy)
            }
        }
        return out
    }
}

// MARK: - Row

@MainActor
private struct OnlineSongRow: View {
    let song: OnlineSong
    let onPlay: () -> Void
    let onAdd: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: song.coverURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                // The catalog stores a Uyghur title and a Latin original; show
                // the second one only when it actually differs.
                if let original = song.originalTitle,
                   !original.isEmpty,
                   original != song.title {
                    Text(original)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(song.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if song.duration > 0 {
                Text(Self.formatted(song.duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if isHovering {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("加入曲库")

                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                }
                .buttonStyle(.plain)
                .help("加入曲库并播放")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onPlay)
    }

    private static func formatted(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
