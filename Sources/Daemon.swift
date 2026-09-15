import AppKit
import Foundation

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let server: SocketServer

    init(server: SocketServer) {
        self.server = server
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }
}

/// `serve` — the only verb that builds an NSApplication. Everything else is a
/// socket client and must stay a plain CLI process.
enum Daemon {
    private static var delegate: AppDelegate?
    private static var controller: StatusItemController?

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let statusItem = StatusItemController()
        controller = statusItem

        let server = SocketServer { request in
            handle(request, controller: statusItem)
        }
        do {
            try server.start()
        } catch {
            log("fatal: \(error)")
            exit(1)
        }
        log("listening on \(SocketPath.default), target=\(Settings.targetInputSourceID)")

        let appDelegate = AppDelegate(server: server)
        delegate = appDelegate
        app.delegate = appDelegate
        app.run()
        exit(0)
    }

    /// Always runs on the main queue.
    static func handle(_ request: String, controller: StatusItemController) -> String {
        switch request {
        case "ping":
            return "pong"

        case "get":
            guard let id = InputSources.currentSourceID() else { return "err no-current-source" }
            return "ok \(id)"

        case "switch":
            controller.noteSwitchRequest()
            guard Settings.enabled else { return "ok disabled" }
            switch InputSources.select(id: Settings.targetInputSourceID) {
            case .switched: return "ok switched"
            case .noop: return "ok noop"
            case let .failed(why):
                log("switch failed: \(why)")
                return "err \(why)"
            }

        case "":
            return "err empty-command"

        default:
            return "err unknown-command"
        }
    }
}
