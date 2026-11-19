import Cocoa
import WebKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var serverProcess: Process?
    private var port: UInt16 = 3000
    private var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    private var dataDir: URL!
    private var logFileURL: URL!
    private var isShuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupDirectories()
        setupMenu()
        setupWindow()
        showLoadingScreen()

        port = findAvailablePort(preferred: 3000)
        startBackendServer()
        waitForServerReady(attempts: 120)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        isShuttingDown = true
        stopBackendServer()
    }

    // MARK: - Directories & Database Bootstrap

    private func setupDirectories() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dataDir = appSupport.appendingPathComponent("OpenSourceHub", isDirectory: true)
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/OpenSourceHub", isDirectory: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        logFileURL = logsDir.appendingPathComponent("server.log")

        // Rotate log if > 5 MB
        if let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? UInt64, size > 5 * 1024 * 1024 {
            let oldLog = logsDir.appendingPathComponent("server.old.log")
            try? fm.removeItem(at: oldLog)
            try? fm.moveItem(at: logFileURL, to: oldLog)
        }

        // Bootstrap clean SQLite database from template on first launch
        let dbURL = dataDir.appendingPathComponent("hub.db")
        if !fm.fileExists(atPath: dbURL.path) {
            if let resourceURL = Bundle.main.resourceURL {
                let templateURL = resourceURL.appendingPathComponent("server/hub-template.db")
                if fm.fileExists(atPath: templateURL.path) {
                    try? fm.copyItem(at: templateURL, to: dbURL)
                }
            }
        }
    }

    // MARK: - Window & WebView

    private func setupWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 1360, height: 860)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenSource Hub"
        window.minSize = NSSize(width: 960, height: 640)
        window.center()
        window.setFrameAutosaveName("OpenSourceHubMainWindow")
        window.delegate = self

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: contentRect, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.autoresizingMask = [.width, .height]

        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showLoadingScreen() {
        let html = """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8" />
        <style>
          :root { color-scheme: light dark; }
          body {
            margin: 0; height: 100vh; display: flex; flex-direction: column;
            align-items: center; justify-content: center;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
            background: #f8fafc; color: #0f172a;
          }
          @media (prefers-color-scheme: dark) {
            body { background: #0b0f19; color: #e2e8f0; }
            .sub { color: #94a3b8; }
          }
          .spinner {
            width: 32px; height: 32px; border: 3px solid rgba(99,102,241,.2);
            border-top-color: #6366f1; border-radius: 50%;
            animation: spin .8s linear infinite; margin-bottom: 16px;
          }
          @keyframes spin { to { transform: rotate(360deg); } }
          h1 { font-size: 18px; font-weight: 600; margin: 0 0 6px; }
          .sub { font-size: 13px; color: #64748b; }
        </style>
        </head>
        <body>
          <div class="spinner"></div>
          <h1>OpenSource Hub</h1>
          <div class="sub">正在启动本地服务与后台同步引擎…</div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func showErrorScreen(_ message: String) {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html>
        <html lang="zh-CN">
        <head><meta charset="utf-8" />
        <style>
          :root { color-scheme: light dark; }
          body {
            margin: 0; height: 100vh; display: flex; flex-direction: column;
            align-items: center; justify-content: center; padding: 32px; text-align: center;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
            background: #f8fafc; color: #0f172a;
          }
          @media (prefers-color-scheme: dark) { body { background: #0b0f19; color: #e2e8f0; } }
          h1 { font-size: 18px; margin-bottom: 8px; }
          p { font-size: 13px; max-width: 520px; line-height: 1.6; opacity: .8; }
          code { font-size: 12px; opacity: .75; }
        </style>
        </head>
        <body>
          <h1>本地服务启动失败</h1>
          <p>\(escaped)</p>
          <p>请通过顶部菜单栏「OpenSource Hub → 查看运行日志」排查详情。</p>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - Port & Backend Process

    private func findAvailablePort(preferred: UInt16) -> UInt16 {
        if isPortAvailable(preferred) { return preferred }
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return preferred }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else { return preferred }
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRes = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        guard nameRes == 0 else { return preferred }
        return UInt16(bigEndian: assigned.sin_port)
    }

    private func isPortAvailable(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return res == 0
    }

    private func startBackendServer() {
        guard let resourceURL = Bundle.main.resourceURL else {
            showErrorScreen("应用资源目录缺失。")
            return
        }
        let nodeURL = resourceURL.appendingPathComponent("bin/node")
        let serverDir = resourceURL.appendingPathComponent("server", isDirectory: true)
        let launcherURL = serverDir.appendingPathComponent("launcher.cjs")

        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: nodeURL.path) else {
            showErrorScreen("找不到内置 Node 运行时：\(nodeURL.path)")
            return
        }
        guard fm.fileExists(atPath: launcherURL.path) else {
            showErrorScreen("找不到服务入口脚本：\(launcherURL.path)")
            return
        }

        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: logFileURL)
        logHandle?.seekToEndOfFile()
        if let header = "\n=== OpenSource Hub Launch \(ISO8601DateFormatter().string(from: Date())) (port \(port)) ===\n".data(using: .utf8) {
            logHandle?.write(header)
        }

        let proc = Process()
        proc.executableURL = nodeURL
        proc.arguments = [launcherURL.path]
        proc.currentDirectoryURL = serverDir

        var env = ProcessInfo.processInfo.environment
        env["NODE_ENV"] = "production"
        env["HOSTNAME"] = "127.0.0.1"
        env["PORT"] = String(port)
        env["DATABASE_URL"] = "file:\(dataDir.appendingPathComponent("hub.db").path)"
        env["NEXT_TELEMETRY_DISABLED"] = "1"
        env["TZ"] = TimeZone.current.identifier
        env["OPENSOURCE_HUB_DATA_DIR"] = dataDir.path
        proc.environment = env

        if let logHandle = logHandle {
            proc.standardOutput = logHandle
            proc.standardError = logHandle
        }

        proc.terminationHandler = { [weak self] p in
            guard let self = self, !self.isShuttingDown else { return }
            DispatchQueue.main.async {
                self.showErrorScreen("后台服务意外退出（退出码 \(p.terminationStatus)）。")
            }
        }

        do {
            try proc.run()
            serverProcess = proc
        } catch {
            showErrorScreen("无法启动内置 Node 服务：\(error.localizedDescription)")
        }
    }

    private func waitForServerReady(attempts: Int) {
        guard !isShuttingDown else { return }
        if attempts <= 0 {
            showErrorScreen("等待本地服务响应超时（端口 \(port)）。")
            return
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/status"))
        req.timeoutInterval = 1.0
        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            guard let self = self, !self.isShuttingDown else { return }
            if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                DispatchQueue.main.async {
                    self.webView.load(URLRequest(url: self.baseURL))
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.waitForServerReady(attempts: attempts - 1)
                }
            }
        }.resume()
    }

    private func stopBackendServer() {
        guard let proc = serverProcess, proc.isRunning else { return }
        proc.terminate()
        let deadline = Date().addingTimeInterval(3.0)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        serverProcess = nil
    }

    // MARK: - WKNavigationDelegate & WKUIDelegate

    private func isInternalURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return url.scheme == "about" }
        return (host == "127.0.0.1" || host == "localhost") && (url.port == Int(port))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "http" || url.scheme == "https" {
            if isInternalURL(url) {
                decisionHandler(.allow)
            } else {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isInternalURL(url) {
                webView.load(URLRequest(url: url))
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "OpenSource Hub"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "请确认"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { resp in completionHandler(resp == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "OpenSource Hub"
        alert.informativeText = prompt
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { resp in
            completionHandler(resp == .alertFirstButtonReturn ? input.stringValue : nil)
        }
    }

    // MARK: - Menu Bar

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 OpenSource Hub", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "打开数据目录…", action: #selector(openDataFolder), keyEquivalent: "")
        appMenu.addItem(withTitle: "查看运行日志…", action: #selector(openLogFile), keyEquivalent: "")
        appMenu.addItem(withTitle: "在默认浏览器中打开", action: #selector(openInBrowser), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 OpenSource Hub", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 OpenSource Hub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // Edit Menu (enables Cmd+C/V/X/A/Z in WKWebView)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(withTitle: "重新加载", action: #selector(reloadPage), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "后退", action: #selector(goBack), keyEquivalent: "[")
        viewMenu.addItem(withTitle: "前进", action: #selector(goForward), keyEquivalent: "]")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "放大", action: #selector(zoomIn), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "缩小", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "实际大小", action: #selector(zoomReset), keyEquivalent: "0")
        viewMenuItem.submenu = viewMenu

        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openDataFolder() { NSWorkspace.shared.open(dataDir) }
    @objc private func openLogFile() { NSWorkspace.shared.open(logFileURL) }
    @objc private func openInBrowser() { NSWorkspace.shared.open(baseURL) }
    @objc private func reloadPage() { webView.reload() }
    @objc private func goBack() { if webView.canGoBack { webView.goBack() } }
    @objc private func goForward() { if webView.canGoForward { webView.goForward() } }
    @objc private func zoomIn() { webView.pageZoom = min(webView.pageZoom + 0.1, 2.0) }
    @objc private func zoomOut() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc private func zoomReset() { webView.pageZoom = 1.0 }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
