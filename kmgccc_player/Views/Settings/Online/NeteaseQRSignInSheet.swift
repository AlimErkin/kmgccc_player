//
//  NeteaseQRSignInSheet.swift
//  kmgccc_player
//
//  QR sign-in for NetEase Cloud Music.
//
//  The handshake is: ask for a unikey, render `music.163.com/login?codekey=…`
//  as a QR code locally, then poll until the phone confirms. Nothing about the
//  listener's credentials passes through any server of ours — the cookie comes
//  straight back from music.163.com and stays on this Mac.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
struct NeteaseQRSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var account = NeteaseAccountStore.shared

    private enum Stage: Equatable {
        case preparing
        case waitingForScan
        case scannedAwaitingConfirm
        case expired
        case succeeded
        case failed(String)
    }

    @State private var stage: Stage = .preparing
    @State private var qrImage: NSImage?
    @State private var session: NeteaseQRSession?
    @State private var pollTask: Task<Void, Never>?

    /// NetEase's own client polls at roughly this cadence; faster adds nothing
    /// and only invites throttling.
    private let pollInterval: Duration = .seconds(2)

    var body: some View {
        VStack(spacing: 18) {
            Text("扫码登录网易云音乐")
                .font(.system(size: 16, weight: .semibold))

            qrPanel

            Text(statusText)
                .font(.system(size: SettingsStyleTokens.rowValueFontSize))
                .foregroundStyle(statusIsProblem ? .orange : .secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if case .expired = stage {
                    Button("重新生成") { start() }
                        .keyboardShortcut(.defaultAction)
                } else if case .failed = stage {
                    Button("重试") { start() }
                        .keyboardShortcut(.defaultAction)
                }
                Button("关闭") { dismiss() }
            }
        }
        .padding(28)
        .frame(width: 340)
        .background(ThemedBaseBackgroundColorView())
        .tint(themeStore.accentColor)
        .onAppear { start() }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Panel

    @ViewBuilder
    private var qrPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SettingsStyleTokens.sectionCornerRadius)
                .fill(.white)
                .frame(width: 220, height: 220)

            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 196, height: 196)
                    .opacity(stage == .expired ? 0.15 : 1)
            } else {
                ProgressView().controlSize(.large)
            }

            if stage == .scannedAwaitingConfirm {
                // Mirrors what the official client shows once the phone has
                // read the code: the QR stops being the thing to look at.
                RoundedRectangle(cornerRadius: SettingsStyleTokens.sectionCornerRadius)
                    .fill(.white.opacity(0.88))
                    .frame(width: 220, height: 220)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(themeStore.accentColor)
            }

            if stage == .expired {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        switch stage {
        case .preparing: return "正在取二维码…"
        case .waitingForScan: return "用网易云音乐 App 扫这个码"
        case .scannedAwaitingConfirm: return "已扫码，在手机上点确认"
        case .expired: return "二维码过期了，重新生成一个"
        case .succeeded: return "登录成功"
        case let .failed(message): return message
        }
    }

    private var statusIsProblem: Bool {
        switch stage {
        case .expired, .failed: return true
        default: return false
        }
    }

    // MARK: - Flow

    private func start() {
        pollTask?.cancel()
        qrImage = nil
        stage = .preparing

        pollTask = Task {
            do {
                let newSession = try await NeteaseClient.shared.beginQRSignIn()
                guard !Task.isCancelled else { return }
                session = newSession
                qrImage = Self.makeQRImage(from: newSession.loginURL)
                stage = .waitingForScan
                await poll(newSession)
            } catch {
                guard !Task.isCancelled else { return }
                stage = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }

    private func poll(_ session: NeteaseQRSession) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else { return }

            let status: NeteaseQRStatus
            do {
                status = try await NeteaseClient.shared.pollQRSignIn(session)
            } catch {
                // A single hiccup mid-handshake should not throw the listener
                // back to the start; keep polling until the code itself expires.
                continue
            }
            guard !Task.isCancelled else { return }

            switch status {
            case .waitingForScan:
                stage = .waitingForScan
            case .scannedAwaitingConfirm:
                stage = .scannedAwaitingConfirm
            case .expired:
                stage = .expired
                return
            case let .authorized(cookie):
                stage = .succeeded
                await account.adopt(cookie: cookie)
                try? await Task.sleep(for: .milliseconds(600))
                dismiss()
                return
            case .other:
                // 803-without-cookie and other transient codes: keep waiting.
                continue
            }
        }
    }

    // MARK: - QR rendering

    /// Rendered locally with Core Image, so the login URL never goes to a
    /// third-party QR service.
    private static func makeQRImage(from url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // The generator emits roughly one pixel per module; scale up before
        // rasterizing so the code stays crisp at display size.
        let scale: CGFloat = 12
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: scaled.extent.size)
    }
}
