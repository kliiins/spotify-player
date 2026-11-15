import SwiftUI
import AppKit
import QuartzCore
import ServiceManagement

final class SpotifyPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

final class AppController: NSObject, NSApplicationDelegate {

    var window: SpotifyPanel?
    var hostingView: NSHostingView<ContentView>?
    var hotKeyManager: HotKeyManager?

    private var serverProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {

        NSApp.setActivationPolicy(.accessory)

        createWindow()
        setupHotKey()

        NotificationCenter.default.addObserver(
            forName: .spotifyDJHide,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hideWindow(animated: true)
        }

        DispatchQueue.main.async {
            self.startServer()
            self.checkFirstRun()
        }

        setupLoginItem()
    }

    // MARK: - Window

    private func createWindow() {

        let contentView = ContentView()

        let hosting = NSHostingView(
            rootView: contentView
        )

        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: 640,
            height: 295
        )

        let panel = SpotifyPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 640,
                height: 295
            ),
            styleMask: [
                .borderless,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )

        panel.contentView = hosting

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 22
        panel.contentView?.layer?.masksToBounds = true
        panel.contentView?.layer?.borderWidth = 0

        panel.alphaValue = 0

        panel.minSize = NSSize(
            width: 640,
            height: 295
        )

        panel.maxSize = NSSize(
            width: 640,
            height: 295
        )

        window = panel
        hostingView = hosting

        panel.center()
    }

    // MARK: - Server

    private func startServer() {

        print("================================")
        print("Spotify Player: запуск сервера...")
        print("================================")

        guard serverProcess == nil else {
            print("⚠️ Серверный процесс уже существует")
            return
        }

        guard let serverFolderURL = Bundle.main.url(
            forResource: "SpotifyDJServer",
            withExtension: nil
        ) else {

            print("❌ SpotifyDJServer НЕ НАЙДЕН")

            print("Bundle:")
            print(Bundle.main.bundlePath)

            print("Resources:")

            if let resourcePath = Bundle.main.resourcePath {

                print(resourcePath)

                do {

                    let files = try FileManager.default.contentsOfDirectory(
                        atPath: resourcePath
                    )

                    for file in files {
                        print("  - \(file)")
                    }

                } catch {

                    print("❌ Не удалось прочитать Resources:")
                    print(error)
                }
            }

            return
        }

        print("📂 Папка сервера:")
        print(serverFolderURL.path)

        let executableURL = serverFolderURL
            .appendingPathComponent("SpotifyDJServer")

        print("🚀 Executable сервера:")
        print(executableURL.path)

        let fileManager = FileManager.default

        guard fileManager.fileExists(
            atPath: executableURL.path
        ) else {

            print("❌ Executable SpotifyDJServer НЕ НАЙДЕН")
            print(executableURL.path)

            return
        }

        guard fileManager.isExecutableFile(
            atPath: executableURL.path
        ) else {

            print("❌ SpotifyDJServer НЕ ИМЕЕТ ПРАВА НА ЗАПУСК")
            print(executableURL.path)

            return
        }

        let process = Process()

        process.executableURL = executableURL

        process.currentDirectoryURL = serverFolderURL

        // Сервер следит за этим PID и сам завершится, если приложение упадёт
        // или будет остановлено из Xcode — порт 8888 не останется занятым.
        var environment = ProcessInfo.processInfo.environment
        environment["SPOTIFY_DJ_PARENT_PID"] = String(
            ProcessInfo.processInfo.processIdentifier
        )
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = {
            handle in

            let data = handle.availableData

            if !data.isEmpty {

                if let text = String(
                    data: data,
                    encoding: .utf8
                ) {

                    print(
                        "SERVER:",
                        text,
                        terminator: ""
                    )
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = {
            handle in

            let data = handle.availableData

            if !data.isEmpty {

                if let text = String(
                    data: data,
                    encoding: .utf8
                ) {

                    print(
                        "SERVER ERROR:",
                        text,
                        terminator: ""
                    )
                }
            }
        }

        process.terminationHandler = {
            process in

            DispatchQueue.main.async {

                print(
                    "⚠️ SpotifyDJServer завершился. Код:",
                    process.terminationStatus
                )

                self.serverProcess = nil
            }
        }

        do {

            try process.run()

            serverProcess = process

            print("✅ SpotifyDJServer PROCESS запущен")

        } catch {

            print("❌ ОШИБКА ЗАПУСКА SpotifyDJServer:")
            print(error)
        }
    }

    // MARK: - First run

    /// Первый запуск: если нет ключей Spotify — открыть страницу настройки,
    /// если ключи есть, но вход не выполнен — открыть вход.
    private func checkFirstRun(attempt: Int = 0) {

        guard attempt < 20,
              let url = URL(string: "http://127.0.0.1:8888/native-status")
        else {
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in

            guard
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // сервер ещё стартует
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.checkFirstRun(attempt: attempt + 1)
                }
                return
            }

            let configured = json["configured"] as? Bool ?? false
            let loggedIn = json["logged_in"] as? Bool ?? false

            let path: String? = !configured ? "/setup" : (!loggedIn ? "/login" : nil)

            if let path, let pageURL = URL(string: "http://127.0.0.1:8888" + path) {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(pageURL)
                }
            }
        }.resume()
    }

    // MARK: - Login Item

    private func setupLoginItem() {

        if #available(macOS 13.0, *) {

            do {

                try SMAppService.mainApp.register()

                print("✅ Spotify Player добавлен в автозапуск")

            } catch {

                print(
                    "⚠️ Автозапуск не добавлен:",
                    error
                )
            }
        }
    }

    // MARK: - Hotkey

    private func setupHotKey() {

        let manager = HotKeyManager()

        hotKeyManager = manager

        manager.onHotKey = { [weak self] in

            DispatchQueue.main.async {

                guard let self else {
                    return
                }

                guard let window = self.window else {
                    return
                }

                if window.isVisible {

                    self.hideWindow(
                        animated: true
                    )

                } else {

                    self.showWindow(
                        animated: true
                    )
                }
            }
        }

        manager.start()
    }

    // MARK: - Show Window

    func showWindow(animated: Bool) {

        guard let window else {
            return
        }

        NSApp.activate(
            ignoringOtherApps: true
        )

        window.center()

        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 22
        window.contentView?.layer?.masksToBounds = true
        window.contentView?.layer?.borderWidth = 0

        window.alphaValue = animated ? 0 : 1

        window.makeKeyAndOrderFront(nil)
        window.makeKey()

        // сразу запускаем анимацию появления содержимого вместе с фейдом окна
        focusSearchField()

        if animated {

            NSAnimationContext.runAnimationGroup { context in

                context.duration = 0.22

                context.timingFunction =
                    CAMediaTimingFunction(
                        name: .easeOut
                    )

                window.animator().alphaValue = 1

            } completionHandler: {

                DispatchQueue.main.async {

                    NSApp.activate(
                        ignoringOtherApps: true
                    )

                    window.makeKey()

                    self.focusSearchField()
                }
            }

        } else {

            DispatchQueue.main.async {

                NSApp.activate(
                    ignoringOtherApps: true
                )

                window.makeKey()

                self.focusSearchField()
            }
        }
    }

    // MARK: - Hide Window

    func hideWindow(animated: Bool) {

        guard let window else {
            return
        }

        if animated {

            NSAnimationContext.runAnimationGroup { context in

                context.duration = 0.14

                context.timingFunction =
                    CAMediaTimingFunction(
                        name: .easeIn
                    )

                window.animator().alphaValue = 0

            } completionHandler: {

                DispatchQueue.main.async {

                    window.orderOut(nil)

                    window.alphaValue = 0
                }
            }

        } else {

            window.orderOut(nil)

            window.alphaValue = 0
        }

        NotificationCenter.default.post(
            name: .spotifyDJDidHide,
            object: nil
        )
    }

    // MARK: - Focus

    private func focusSearchField() {

        NotificationCenter.default.post(
            name: .spotifyDJFocus,
            object: nil
        )
    }

    // MARK: - Terminate

    func applicationWillTerminate(
        _ notification: Notification
    ) {

        if let process = serverProcess,
           process.isRunning {

            process.terminate()
        }

        hotKeyManager?.stop()
    }
}

@main
struct MyApp: App {

    @NSApplicationDelegateAdaptor(AppController.self)
    private var appController

    var body: some Scene {

        MenuBarExtra {

            Button("Открыть Spotify Player") {

                appController.showWindow(
                    animated: true
                )
            }
            .keyboardShortcut(" ", modifiers: .shift)

            Button("Войти в Spotify заново…") {

                if let url = URL(string: "http://127.0.0.1:8888/login") {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            Button("Выйти") {

                NSApp.terminate(nil)
            }

        } label: {

            // звуковая волна в кружке — аккуратно смотрится рядом с системными иконками
            Image(
                systemName: "waveform.circle.fill"
            )
            .symbolRenderingMode(.hierarchical)
        }
    }
}
