//
//  OnlineSettingsView.swift
//  kmgccc_player
//
//  Settings pane for the two online sources: the in-house catalog service and
//  the listener's own NetEase account.
//
//  Assembled entirely from the existing Settings vocabulary —
//  `SettingsHeaderLabel`, `SettingsSection`, `settingsDescriptionStyle()` and
//  the standard control set — so it reads as part of the same app rather than
//  a bolted-on panel. The closest precedent is `ExternalPlaybackSettingsView`,
//  whose permission rows this mirrors.
//

import SwiftUI

@MainActor
struct OnlineSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.settingsAppForegroundColors) private var appColors

    @State private var account = NeteaseAccountStore.shared

    @State private var baseURLDraft: String = AppSettings.shared.onlineCatalogBaseURL
    @State private var tokenDraft: String = AppSettings.shared.onlineCatalogToken
    @State private var cacheBudgetGB: Double = AppSettings.shared.onlineMediaCacheBudgetGB

    private enum ProbeState: Equatable {
        case idle
        case probing
        case reachable(name: String, songCount: Int?)
        case failed(String)
    }
    @State private var probe: ProbeState = .idle
    @State private var showQRSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("在线音乐", systemImage: "antenna.radiowaves.left.and.right")

            catalogSection
            neteaseSection
            cacheSection
        }
    }

    // MARK: - Catalog

    private var catalogSection: some View {
        SettingsSection("曲库服务") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("服务地址") {
                    TextField("https://music.example.com", text: $baseURLDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .onSubmit(applyCatalogSettings)
                }

                LabeledContent("访问口令") {
                    SecureField("没设就留空", text: $tokenDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .onSubmit(applyCatalogSettings)
                }

                HStack(spacing: 10) {
                    Button("保存并测试连接") {
                        applyCatalogSettings()
                        Task { await runProbe() }
                    }
                    .disabled(probe == .probing)

                    probeStatusLabel
                }

                Text("填你自己那台服务的地址。曲库的搜索、专题和音源地址都从它拿 —— 它那边已经绕开了上游列表接口的分页和字段缺口，App 这边不用再绕一遍。")
                    .settingsDescriptionStyle()
            }
        }
    }

    @ViewBuilder
    private var probeStatusLabel: some View {
        switch probe {
        case .idle:
            EmptyView()
        case .probing:
            ProgressView().controlSize(.small)
        case let .reachable(name, songCount):
            Label(
                songCount.map { "\(name) · \($0) 首" } ?? name,
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.system(size: SettingsStyleTokens.rowValueFontSize))
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: SettingsStyleTokens.rowValueFontSize))
                .lineLimit(2)
        }
    }

    // MARK: - NetEase

    private var neteaseSection: some View {
        SettingsSection("网易云音乐") {
            VStack(alignment: .leading, spacing: 14) {
                if account.isSignedIn {
                    LabeledContent("已登录") {
                        HStack(spacing: 8) {
                            Text(account.account?.nickname ?? "—")
                            if account.account?.isVIP == true {
                                Text("会员")
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(themeStore.accentColor.opacity(0.18), in: Capsule())
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Button("刷新账号状态") {
                            Task { await account.refreshAccount() }
                        }
                        Button("退出登录", role: .destructive) {
                            Task { await account.signOut() }
                        }
                    }
                } else {
                    Button("扫码登录") { showQRSheet = true }
                }

                if let message = account.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: SettingsStyleTokens.rowValueFontSize))
                }

                Text("用网易云 App 扫码，登录的是你自己的账号 —— 会员歌曲能不能听按你的账号算，登录信息只存在这台 Mac 上。")
                    .settingsDescriptionStyle()
            }
        }
        .sheet(isPresented: $showQRSheet) {
            NeteaseQRSignInSheet()
                .environmentObject(themeStore)
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        SettingsSection("在线音频缓存") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("缓存上限") {
                    HStack(spacing: 10) {
                        Slider(value: $cacheBudgetGB, in: 1...64, step: 1)
                            .frame(maxWidth: 240)
                        Text("\(Int(cacheBudgetGB)) GB")
                            .monospacedDigit()
                            .font(.system(size: SettingsStyleTokens.rowValueFontSize))
                    }
                }

                Text("在线的歌要先取下来才能播 —— 这样频谱、无缝衔接、拖动进度都和本地歌一模一样。超过上限时，最久没听的先删。")
                    .settingsDescriptionStyle()
            }
            .onChange(of: cacheBudgetGB) { _, newValue in
                settings.onlineMediaCacheBudgetGB = newValue
                Task {
                    await OnlineMediaCache.shared.setBudgetBytes(
                        Int64(newValue) * 1024 * 1024 * 1024
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private func applyCatalogSettings() {
        settings.onlineCatalogBaseURL = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.onlineCatalogToken = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = settings.onlineCatalogEndpoint
        Task { await LibraryCatalogClient.shared.configure(endpoint) }
    }

    private func runProbe() async {
        guard settings.onlineCatalogEndpoint != nil else {
            probe = .failed("先填服务地址")
            return
        }
        probe = .probing
        do {
            let health = try await LibraryCatalogClient.shared.ping()
            probe = .reachable(name: health.name ?? "曲库", songCount: health.songCount)
        } catch {
            probe = .failed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}
