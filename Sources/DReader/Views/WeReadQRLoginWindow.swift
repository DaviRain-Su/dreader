import AppKit
import CoreImage
import SwiftUI

/// 原生扫码登录窗口：不加载网页，直接把确认链接渲染成大二维码居中；
/// 状态流转 等待→取码→扫码轮询→(OTP)→成功。窗口独立于主窗口，尺寸恒定。
@MainActor
enum WeReadQRLoginWindowController {
    private static var window: NSWindow?
    private static var flow: WeReadQRLoginFlow?

    static func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let flow = WeReadQRLoginFlow { close() }
        self.flow = flow
        let content = WeReadQRLoginView(flow: flow)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "微信读书 · 扫码登录"
        win.contentView = NSHostingView(rootView: content)
        win.center()
        win.isReleasedWhenClosed = false
        window = win
        flow.start()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关窗并停掉轮询（手动关闭或成功自动收窗共用）
    static func close() {
        flow?.stop()
        flow = nil
        window?.close()
        window = nil
    }
}

/// 登录状态机 + 轮询循环（与窗口生命周期解耦，关窗即停）
@MainActor
final class WeReadQRLoginFlow: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case qr(confirmURL: String)
        case otp(message: String)
        case running(status: String)
        case success
        case failed(message: String)
        case expired
    }

    @Published var phase: Phase = .connecting
    @Published var otpInput: String = ""
    private var task: Task<Void, Never>?
    private var otpContinuation: CheckedContinuation<String?, Never>?
    private var startedAt = Date()
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func start() {
        task?.cancel()
        otpContinuation?.resume(returning: nil)
        otpContinuation = nil
        otpInput = ""
        task = Task { [weak self] in
            await self?.run()
        }
    }

    /// 二维码过期/失败：重新立会话取新码
    func regenerate() {
        startedAt = Date()
        start()
    }

    /// 窗口被手动关闭时静默停流（不回调 onClose 二次关窗）
    func stop() {
        task?.cancel()
        task = nil
        otpContinuation?.resume(returning: nil)
        otpContinuation = nil
    }

    @discardableResult
    private func run() async -> Void {
        do {
            phase = .connecting
            startedAt = Date()
            let uid = try await WeReadQRLoginService.shared.beginSession()
            phase = .qr(confirmURL: WeReadQRLoginService.confirmURL(uid: uid))
            var otp = ""
            while !Task.isCancelled {
                if Date().timeIntervalSince(startedAt) > 300 {
                    phase = .expired
                    return
                }
                do {
                    let result = try await WeReadQRLoginService.shared.poll(uid: uid, otp: otp)
                    if result.succeed {
                        let header = try WeReadQRLoginService.shared.finalize(result)
                        WeReadContentService.shared.cookie = header
                        phase = .running(status: "正在验证登录态…")
                        // 验证不过不许假成功：直接把真实原因亮出来
                        do {
                            try await WeReadAuthService.validate()
                        } catch {
                            phase = .failed(
                                message: "扫码成功但登录态验证失败：\n\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)\n\n可点「改用内嵌网页登录」换通道。"
                            )
                            return
                        }
                        phase = .success
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard !Task.isCancelled else { return }
                        onClose()
                        return
                    }
                    switch result.logicCode {
                    case "NEED_OTP", "OTP_NOT_MATCH":
                        guard let code = await requestOTP(
                            message: result.logicCode == "OTP_NOT_MATCH"
                                ? "验证码不正确，请重新输入手机上的 4 位数字。"
                                : nil
                        ), !code.isEmpty else { return }
                        otp = code
                    case "OTP_EXPIRED":
                        otp = ""
                        guard let code = await requestOTP(message: "验证码已过期，请在手机上重新获取。") else { return }
                        otp = code
                    case "LOGIN_TIMEOUT":
                        phase = .expired
                        return
                    default:
                        // 未知状态码（含空轮询响应）：不判死，继续轮到会话过期
                        break
                    }
                } catch {
                    // transport 错误（超时/网络抖动）：继续轮到会话过期为止
                }
                // 服务端长轮询 ~5s 阻塞返回，这里只补 0.5s 间隔（KOReader 同款节奏）
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        } catch is CancellationError {
            // 停流：静默
        } catch {
            if !Task.isCancelled {
                phase = .failed(message: "获取登录二维码失败：\n\(LocalizedErrorText(error))")
            }
        }
    }

    private func requestOTP(message: String?) async -> String? {
        await withCheckedContinuation { continuation in
            otpContinuation = continuation
            otpInput = ""
            phase = .otp(message: message ?? "")
        }
    }

    func confirmOTP() {
        let trimmed = otpInput.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 4, trimmed.allSatisfy(\.isNumber) else {
            // 输入不完整：不消费 continuation，让用户改完再点
            return
        }
        otpContinuation?.resume(returning: trimmed)
        otpContinuation = nil
    }

    private func LocalizedErrorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// 窗口内容：标题 + 大二维码/状态面 + 说明，全部原生渲染
private struct WeReadQRLoginView: View {
    @ObservedObject var flow: WeReadQRLoginFlow

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                Text("微信读书 · 扫码登录")
                    .font(.system(size: 15, weight: .bold))
            }

            Group {
                switch flow.phase {
                case .connecting:
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("正在获取登录二维码…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 380)

                case .qr(let url):
                    VStack(spacing: 12) {
                        if let image = makeQRImage(url) {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: 300, height: 300)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                                )
                        } else {
                            Text(url)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: 320)
                        }
                        qrHint
                    }

                case .otp(let message):
                    VStack(spacing: 14) {
                        Image(systemName: "numbersign.circle")
                            .font(.system(size: 46))
                            .foregroundStyle(.secondary.opacity(0.7))
                        Text(message.isEmpty ? "请在微信读书 App 中查看 4 位验证码并输入：" : message)
                            .font(.system(size: 12.5))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.primary.opacity(0.85))
                        HStack(spacing: 10) {
                            TextField("4 位数字", text: $flow.otpInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 18, design: .monospaced))
                                .multilineTextAlignment(.center)
                                .frame(width: 140)
                                .onSubmit { flow.confirmOTP() }
                            Button {
                                flow.confirmOTP()
                            } label: {
                                Text("确认")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 7)
                                    .background(Color.primary.opacity(0.8))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 380)

                case .running(let status):
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.9)
                        Text(status)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 380)

                case .success:
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(Color.green)
                        Text("登录成功，Cookie 已自动保存")
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 380)

                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 44))
                            .foregroundStyle(Color.orange)
                        Text(message)
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        regenerateButtons
                    }
                    .frame(maxWidth: .infinity, minHeight: 380)

                case .expired:
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode.badge.elapsed")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary.opacity(0.7))
                        Text("二维码已过期")
                            .font(.system(size: 13, weight: .semibold))
                        Text("点击重新生成新的登录二维码。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        regenerateButtons
                    }
                    .frame(maxWidth: .infinity, minHeight: 380)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            Text("扫码即代表以你的账号完成网页版登录；DReader 只取登录态用于读取你有权限的书目，逐章限速。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
        .frame(width: 440, height: 610)
    }

    private var qrHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 12))
                .foregroundStyle(Color.green)
            Text("打开微信，扫一扫；或在微信读书 App 中扫码确认登录。")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.8))
        }
        .multilineTextAlignment(.leading)
    }

    private var regenerateButtons: some View {
        HStack(spacing: 12) {
            Button {
                flow.regenerate()
            } label: {
                Text("重新生成二维码")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // 原生通道异常时的网页兜底
            Button {
                // QR 窗口让位给网页窗口
                WeReadQRLoginWindowController.close()
                WeReadLoginWindowController.present()
            } label: {
                Text("改用内嵌网页登录")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// CIQRCodeGenerator：确认链接 → 高倍位图（SwiftUI .interpolation(.none) 保证扫得清）
    private func makeQRImage(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
