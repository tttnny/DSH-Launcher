import AppKit
import SwiftUI

// ============================================================
// DSH 主窗口（SwiftUI）
// 承载菜单栏以外的全部能力：dsh 信息、服务启动/重启/关闭、
// 安装/卸载/更新、profile 选择启动、服务日志、App 设置。
// 状态与操作全部来自 AppModel（main.swift），本文件只负责视图。
// ============================================================

/// 窗口工厂：AppDelegate 创建/复用单例主窗口时调用。
/// App 保持无 Dock 图标（accessory），关窗仅隐藏，从菜单栏「显示主窗口」找回。
enum MainWindowFactory {
    static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "DSH 控制台"
        window.contentView = NSHostingView(rootView: MainWindowView())
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

// MARK: - 根视图

struct MainWindowView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                infoSection
                controlSection
                profileSection
                logSection
                settingsSection
            }
            .padding(16)
        }
        .frame(width: 546)
    }

    // MARK: 状态推导

    private var stateColor: Color {
        switch model.state {
        case .running: return .green
        case .starting, .installing, .portBusy: return .orange
        case .crashed: return .red
        case .notInstalled, .stopped: return .gray
        }
    }

    private var stateText: String {
        switch model.state {
        case .running: return "运行中 · 端口 3080"
        case .starting: return "正在启动…"
        case .installing: return "dsh 安装中…"
        case .notInstalled: return "dsh 未安装"
        case .portBusy: return "端口 3080 被其他程序占用"
        case .crashed: return "异常退出（已停止，可手动重启）"
        case .stopped: return "未运行"
        }
    }

    private var canStart: Bool {
        dshInstalled() && !model.busy && model.state != .starting && model.state != .installing
    }

    private var canStop: Bool {
        !model.busy && (model.state == .running || model.state == .crashed)
    }

    private var selectedProfileInfo: DshProfile? {
        model.profiles.first { $0.name == model.selectedProfile }
    }

    // MARK: dsh 信息

    private var infoSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Circle().fill(stateColor).frame(width: 9, height: 9)
                    Text(stateText).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if model.updateAvailable, let v = model.latestRemoteVersion {
                        Text(model.updateIsPreview ? "可更新 → v\(v)（预发布）" : "可更新 → v\(v)")
                            .font(.caption).foregroundColor(.orange)
                    }
                }
                if !model.envNote.isEmpty {
                    Text(model.envNote).font(.caption).foregroundColor(.orange)
                }
                Divider()
                infoRow("dsh 版本", model.localVersion.map { "v\($0)" } ?? "未安装")
                npmRow
                githubRow
                infoRow("运行 Profile",
                        model.state == .running
                            ? (model.runningProfile ?? "外部实例（非本 App 启动）")
                            : "—")
                infoRow("安装位置", dshInstallLocation)
                infoRow("Node", abbreviateHome(resolveNodePath()))
                infoRow("端口", "3080（仅 127.0.0.1）")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("dsh 信息").font(.headline)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
    }

    /// npm 频道行：最新版本 + 预发布/tag 徽标
    private var npmRow: some View {
        HStack(alignment: .top) {
            Text("npm 最新版")
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .leading)
            if let v = model.npmLatestVersion {
                HStack(spacing: 6) {
                    Text("v\(v)").textSelection(.enabled)
                    if model.npmIsPrerelease {
                        let tagLabel = model.npmTag.flatMap { $0 != "latest" ? $0 : nil } ?? "预发布"
                        captionBadge(tagLabel)
                    }
                }
                Spacer()
            } else {
                Text(model.checkingUpdates ? "获取中…" : "未检查")
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 12))
    }

    /// GitHub Release 频道行：最新版本 + 「预发布」「npm 未发布」徽标 + 查看链接。
    /// 该频道仅信息展示——GitHub release 无产物，App 不提供自动安装。
    private var githubRow: some View {
        HStack(alignment: .top) {
            Text("GitHub Release")
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .leading)
            if let v = model.githubLatestVersion {
                HStack(spacing: 6) {
                    Text("v\(v)").textSelection(.enabled)
                    if model.githubIsPrerelease {
                        captionBadge("预发布")
                    }
                    if isNewerThanNpm(v) {
                        captionBadge("npm 未发布")
                    }
                }
                Spacer()
                Button("查看 Release") {
                    if let s = model.githubReleaseURL, let url = URL(string: s) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            } else {
                Text(model.checkingGithub ? "获取中…" : "未获取")
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 12))
    }

    private func captionBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.14)))
    }

    /// 该版本是否比 npm 频道已知最新版还新（即 npm 未发布）
    private func isNewerThanNpm(_ v: String) -> Bool {
        guard let npm = model.npmLatestVersion else { return false }
        return isNewerVersion(v, than: npm)
    }

    /// 启动失败摘要：取 message 第一段（去掉"日志尾部"等冗余）
    private func errSummary(_ message: String) -> String {
        let first = message.components(separatedBy: "\n\n").first ?? message
        return first.replacingOccurrences(of: "\n", with: " ")
    }

    private var dshInstallLocation: String {
        guard let path = resolveDshLauncher(nodePath: resolveNodePath()) else { return "未安装" }
        return abbreviateHome(path)
    }

    private func abbreviateHome(_ path: String) -> String {
        path.hasPrefix(homeDir.path) ? "~" + path.dropFirst(homeDir.path.count) : path
    }

    // MARK: 服务控制

    private var controlSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        model.startRequested()
                    } label: {
                        Label("启动", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)

                    Button {
                        model.restartRequested()
                    } label: {
                        Label("重启", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canStart)

                    Button {
                        model.stopRequested()
                    } label: {
                        Label("关闭", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canStop)

                    Spacer()

                    if model.busy {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("操作进行中…").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                HStack(spacing: 10) {
                    if dshInstalled() {
                        Button {
                            model.uninstallRequested()
                        } label: {
                            Label("卸载 dsh…", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.busy)
                    } else {
                        Button {
                            model.installRequested()
                        } label: {
                            Label("安装 dsh", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                    }
                    updateButton
                    Spacer()
                }
                if let err = model.lastStartError {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("上次启动失败，可点「重启」重试；详见下方服务日志").font(.caption).foregroundColor(.red)
                        Text(errSummary(err)).font(.caption2).foregroundColor(.secondary)
                            .lineLimit(2).truncationMode(.tail)
                    }
                } else if model.state == .crashed {
                    Text("服务进程异常退出且不会自动重启（崩溃不自愈），可点「重启」重新拉起；详见服务日志。")
                        .font(.caption).foregroundColor(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("服务控制").font(.headline)
        }
    }

    @ViewBuilder private var updateButton: some View {
        if dshInstalled() {
            if model.updatingInProgress {
                Button {
                } label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("dsh 更新中…")
                    }
                }
                .disabled(true)
            } else if model.checkingUpdates || model.checkingGithub {
                Button {
                } label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("检查更新…")
                    }
                }
                .disabled(true)
            } else if model.updateAvailable, let v = model.latestRemoteVersion {
                HStack(spacing: 6) {
                    Button {
                        model.updateRequested()
                    } label: {
                        Text(model.updateIsPreview ? "更新 → v\(v)（预发布）" : "更新 → v\(v)")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    // 等上游修复期间可忽略该版本，避免误点升级又踩到不兼容
                    Button("忽略此版本") {
                        model.ignoreLatestUpgrade()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            } else if let ignored = model.ignoredUpgradeVersion {
                HStack(spacing: 4) {
                    Text("已忽略更新 v\(ignored)").font(.caption).foregroundColor(.secondary)
                    Button("取消") {
                        model.unignoreUpgrade()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            } else {
                Button("检查更新") {
                    model.updateRequested()
                }
                .buttonStyle(.bordered)
                .disabled(model.busy)
            }
        }
    }

    // MARK: Profile

    private var profileSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("启动 Profile", selection: Binding(
                        get: { model.selectedProfile },
                        set: { model.selectProfile($0) })) {
                        ForEach(model.profiles) { p in
                            Text(p.name).tag(p.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 250)
                    .disabled(model.busy)

                    Spacer()

                    if let p = selectedProfileInfo {
                        Button("打开目录") {
                            model.openProfileDir(p)
                        }
                        .disabled(model.busy)
                    }
                }
                if let p = selectedProfileInfo {
                    Text(p.bundles.isEmpty
                         ? "bundles：未声明（首次启动时由 dsh 从模板自动初始化）"
                         : "bundles：\(p.bundles.joined(separator: "、"))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("选中 profile 后点「启动」即以 `dsh --profile <name> --port 3080` 运行；服务运行中切换会弹确认。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Profile（~/.dsh/profiles）").font(.headline)
        }
    }

    // MARK: 服务日志

    private var logSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ServiceLogView(text: model.logText)
                    .frame(height: 150)
                Text("~/Library/Logs/DSHLauncher/dsh-web.log（实时刷新）")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("服务日志").font(.headline)
        }
        .onAppear { model.startLogStream() }
        .onDisappear { model.stopLogStream() }
    }

    // MARK: 设置

    private var settingsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("登录时自动启动本 App（不影响 dsh 服务）", isOn: Binding(
                    get: { model.autoAppOn },
                    set: { model.setAutoApp($0) }))
                    .toggleStyle(.checkbox)
                    .disabled(model.busy)
                HStack {
                    Button("打开数据目录 ~/.dsh") {
                        model.openDataDir()
                    }
                    Button("打开日志目录") {
                        model.openLogDir()
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("设置").font(.headline)
        }
    }
}

// MARK: - 服务日志视图（NSTextView 封装，自动滚动到底部）

struct ServiceLogView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            tv.scrollToEndOfDocument(nil)
        }
    }
}
