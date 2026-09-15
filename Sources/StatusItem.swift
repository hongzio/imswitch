import AppKit
import Carbon
import Foundation

/// Menu bar UI. The whole menu is rebuilt in `menuWillOpen` so input sources
/// added or removed since the last open show up immediately — this is what
/// keeps the target list out of the source code.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var lastSwitchRequest: Date?

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "imswitch") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "im"
            }
        }
        menu.delegate = self
        statusItem.menu = menu
        refreshAppearance()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Called on the main queue from the socket handler.
    func noteSwitchRequest() {
        lastSwitchRequest = Date()
    }

    private func refreshAppearance() {
        statusItem.button?.appearsDisabled = !Settings.enabled
    }

    @objc private func inputSourceChanged() {
        // Only matters while the menu is already open; menuWillOpen covers the
        // rest. Rebuilding an open menu in place keeps the "현재:" line honest.
        guard menu.numberOfItems > 0, statusItem.button?.isHighlighted == true else { return }
        rebuild()
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()

        let current = NSMenuItem(
            title: "현재: \(InputSources.currentSourceName() ?? "알 수 없음")",
            action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)

        menu.addItem(.separator())

        let header = NSMenuItem(title: "전환 대상", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let target = Settings.targetInputSourceID
        let sources = InputSources.list()
        if sources.isEmpty {
            let empty = NSMenuItem(title: "  (입력기를 찾을 수 없음)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for source in sources {
            let item = NSMenuItem(
                title: source.name, action: #selector(selectTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source.id
            item.state = (source.id == target) ? .on : .off
            item.indentationLevel = 1
            item.toolTip = source.id
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: "활성화", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = Settings.enabled ? .on : .off
        menu.addItem(toggle)

        let test = NSMenuItem(
            title: "지금 전환 (테스트)", action: #selector(switchNow(_:)), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        let stamp = lastSwitchRequest.map { Self.clock.string(from: $0) } ?? "없음"
        let last = NSMenuItem(title: "마지막 요청: \(stamp)", action: nil, keyEquivalent: "")
        last.isEnabled = false
        menu.addItem(last)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "종료", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func selectTarget(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.targetInputSourceID = id
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        Settings.enabled = !Settings.enabled
        refreshAppearance()
    }

    @objc private func switchNow(_ sender: NSMenuItem) {
        switch InputSources.select(id: Settings.targetInputSourceID) {
        case let .switched(id): log("manual switch -> \(id)")
        case .noop: break
        case let .failed(why): log("manual switch failed: \(why)")
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
