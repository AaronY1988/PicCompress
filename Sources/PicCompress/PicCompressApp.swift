import SwiftUI
import AppKit

// MARK: - 入口分流

/// 带 `--cli` 启动时走命令行；否则正常起 GUI。
/// 访达的右键快速操作就是调这个可执行文件加 `--cli`。
@main
enum EntryPoint {
    static func main() {
        // 开发钩子的 argv → env 翻译，必须在这里（任何钩子读 env 之前）。
        // 细节见 `DevEnvBridge`。
        DevEnvBridge.install(from: CommandLine.arguments)

        if CLIRunner.isCLI {
            exit(CLIRunner.run())
        }
        PicCompressApp.main()
    }
}

// MARK: - 界面

struct PicCompressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: WindowID.main) {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        // 700 是改版（方案一「工作台」）量出来的高度。
        //
        // 改版前是 940：右侧七组设置平铺，把窗口撑得比内容高出一大截，
        // 左边三张图只占顶部三分之一，下面全是空的。
        // 现在设置收进三张卡（第三张默认收起），高度跟着内容降到 700。
        .defaultSize(width: 1020, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

enum WindowID {
    static let main = "main"
}

// MARK: - 界面与访达之间的通道

@MainActor
final class ServiceBridge: ObservableObject {
    static let shared = ServiceBridge()

    /// 拖到程序坞图标上、或"打开方式"打开的图片
    @Published var incomingURLs: [URL] = []
    /// 右键快速操作跑完后的结果，用来弹一句提示
    @Published var serviceSummary: String?

    func ingest(_ urls: [URL]) {
        incomingURLs.append(contentsOf: urls)
    }

    func consume() {
        incomingURLs.removeAll()
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 由 ContentView 注入：让 SwiftUI 重新建出主窗口。
    static var reopenWindow: (@MainActor () -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 注册"服务"提供者，访达右键菜单里的快速操作靠它
        NSApp.servicesProvider = self
    }

    /// 关掉最后一个窗口后不要退出，留在程序坞里
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点程序坞图标（或命令行 `open`）时走这里。
    /// SwiftUI 的 WindowGroup 在窗口被关闭后不会自己重建，必须手动处理，
    /// 否则就出现"点了图标没反应"。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }

        // 情况一：窗口只是被最小化或藏到后面 → 直接还原、前置
        if let window = sender.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return false
        }

        // 情况二：窗口已经被关掉 → 让 SwiftUI 重新打开
        Self.reopenWindow?()
        return false
    }

    // MARK: 把图片拖到 App 图标上 / 用"打开方式"打开

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }

        if let window = application.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            Self.reopenWindow?()
        }
        ServiceBridge.shared.ingest(urls)
    }

    // MARK: 访达右键 → 快速操作

    @objc func compressFromFinderService(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else {
            error.pointee = "没有读到可处理的文件" as NSString
            return
        }
        runHeadlessService(on: urls)
    }

    /// 起一个自己的命令行副本去干活，跑完把结果带回来。
    /// 用独立进程的好处：不占界面线程，几百张图也不会把窗口卡住。
    private func runHeadlessService(on urls: [URL]) {
        guard let executable = Bundle.main.executableURL else { return }

        let task = Process()
        task.executableURL = executable
        task.arguments = ["--cli", "--quiet", "--remembered", "--keep-originals"]
            + urls.map { $0.path }

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        task.terminationHandler = { process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            Task { @MainActor in
                let summary = text.isEmpty
                    ? "处理完成（退出码 \(process.terminationStatus)）"
                    : text
                if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    window.makeKeyAndOrderFront(nil)
                } else {
                    Self.reopenWindow?()
                }
                ServiceBridge.shared.serviceSummary = summary
            }
        }

        do {
            try task.run()
        } catch {
            ServiceBridge.shared.serviceSummary = "无法启动压缩进程：\(error.localizedDescription)"
        }
    }
}
