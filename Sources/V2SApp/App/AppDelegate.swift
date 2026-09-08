import AppKit
import Combine
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var appModel = AppModel()
    private lazy var updaterService = UpdaterService()
    private lazy var launchAtLoginService = LaunchAtLoginService()
    private let dockVisibilityController = DockVisibilityController()
    private lazy var transcriptWindowController = TranscriptWindowController(model: appModel)
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var overlayWindowController: OverlayWindowController?
    private var singleInstanceWakeObserver: NSObjectProtocol?
    private var singleInstanceLockDescriptor: Int32 = -1
    private var sourceRefreshTimer: Timer?
    private var didInitializeApplication = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["V2S_TESTING"] != "1" else { return }
        if acquireSingleInstanceLock() == false {
            if handOffToExistingInstanceIfPossible() {
                return
            }

            // A held lock is authoritative. Never kill an owner merely for a slow UI reply.
            guard waitForSingleInstanceLock(timeout: 2.0) else {
                NSApp.terminate(nil)
                return
            }
        } else if singleInstanceLockDescriptor < 0 {
            // If Application Support is unavailable we cannot keep a flock lock,
            // but a best-effort handoff still avoids opening duplicate windows.
            if handOffToExistingInstanceIfPossible() {
                return
            }
        }

        didInitializeApplication = true
        NSApp.setActivationPolicy(.accessory)

        let settingsWindowController = SettingsWindowController(
            model: appModel,
            updaterService: updaterService,
            launchAtLoginService: launchAtLoginService,
            dockVisibilityController: dockVisibilityController,
            showTranscript: { [weak self] in
                self?.transcriptWindowController.showTranscript()
            },
            quitApp: {
                NSApp.terminate(nil)
            }
        )
        let overlayWindowController = OverlayWindowController(
            model: appModel,
            showTranscript: { [weak self] in
                self?.transcriptWindowController.showTranscript()
            }
        )
        let statusBarController = StatusBarController(
            model: appModel,
            openAdvancedSettings: { [weak settingsWindowController] in
                settingsWindowController?.showSettings()
            },
            showTranscript: { [weak self] in
                self?.transcriptWindowController.showTranscript()
            },
            quitApp: {
                NSApp.terminate(nil)
            }
        )

        self.settingsWindowController = settingsWindowController
        self.overlayWindowController = overlayWindowController
        self.statusBarController = statusBarController
        installSingleInstanceWakeObserver()

        overlayWindowController.trayIconRectProvider = { [weak self] in
            self?.statusBarController?.statusItemScreenRect
        }

        settingsWindowController.showSettings()

        appModel.$sessionState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.updateSourceRefreshTimer(for: state)
            }
            .store(in: &cancellables)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        settingsWindowController?.showSettings()
        return false
    }

    // MARK: - Single-instance enforcement

    private func handOffToExistingInstanceIfPossible() -> Bool {
        let identifier = singleInstanceIdentifier
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existingApplications = runningApplicationsForSingleInstance()
            .filter { $0.processIdentifier != currentPID && $0.isTerminated == false }
            .sorted { $0.processIdentifier < $1.processIdentifier }

        guard existingApplications.isEmpty == false else {
            return false
        }

        let requestID = UUID().uuidString
        let wakeRequestedName = Self.singleInstanceWakeRequestedNotificationName(for: identifier)
        let wakeAcknowledgedName = Self.singleInstanceWakeAcknowledgedNotificationName(for: identifier)
        let center = DistributedNotificationCenter.default()
        var acknowledgedPID: pid_t?

        let ackObserver = center.addObserver(
            forName: wakeAcknowledgedName,
            object: identifier,
            queue: .main
        ) { notification in
            guard let receivedRequestID = notification.userInfo?["requestID"] as? String,
                  receivedRequestID == requestID else {
                return
            }

            if let pid = notification.userInfo?["pid"] as? NSNumber {
                acknowledgedPID = pid.int32Value
            } else {
                acknowledgedPID = existingApplications.first?.processIdentifier
            }
        }

        center.postNotificationName(
            wakeRequestedName,
            object: identifier,
            userInfo: ["requestID": requestID],
            deliverImmediately: true
        )
        existingApplications.first?.activate(options: [.activateAllWindows])

        let deadline = Date().addingTimeInterval(Self.singleInstanceWakeAcknowledgementTimeout)
        while acknowledgedPID == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.04))
        }
        center.removeObserver(ackObserver)

        // A missing acknowledgement means busy or older, not safe to terminate.
        // Leave the running instance and its in-memory transcript intact.
        NSApp.terminate(nil)
        return true
    }

    private func runningApplicationsForSingleInstance() -> [NSRunningApplication] {
        if let bundleIdentifier = Bundle.main.bundleIdentifier, bundleIdentifier.isEmpty == false {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        }

        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath().path == bundlePath
        }
    }

    private var singleInstanceIdentifier: String {
        if let bundleIdentifier = Bundle.main.bundleIdentifier, bundleIdentifier.isEmpty == false {
            return bundleIdentifier
        }

        let executableName = Bundle.main.executableURL?.lastPathComponent
            ?? ProcessInfo.processInfo.processName
        return "local.\(executableName)"
    }

    private func acquireSingleInstanceLock() -> Bool {
        guard let lockURL = singleInstanceLockURL() else {
            return true
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return true
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        singleInstanceLockDescriptor = descriptor
        writeSingleInstanceLockMetadata(to: descriptor)
        return true
    }

    private func waitForSingleInstanceLock(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if acquireSingleInstanceLock() {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return acquireSingleInstanceLock()
    }

    private func releaseSingleInstanceLock() {
        guard singleInstanceLockDescriptor >= 0 else {
            return
        }
        flock(singleInstanceLockDescriptor, LOCK_UN)
        close(singleInstanceLockDescriptor)
        singleInstanceLockDescriptor = -1
    }

    private func singleInstanceLockURL() -> URL? {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let directoryURL = applicationSupportURL.appendingPathComponent("v2s", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let sanitizedIdentifier = singleInstanceIdentifier.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-" ? character : "_"
        }
        return directoryURL.appendingPathComponent("\(String(sanitizedIdentifier)).lock")
    }

    private func writeSingleInstanceLockMetadata(to descriptor: Int32) {
        let metadata = [
            "pid=\(ProcessInfo.processInfo.processIdentifier)",
            "identifier=\(singleInstanceIdentifier)",
            "path=\(Bundle.main.bundleURL.resolvingSymlinksInPath().path)"
        ]
        .joined(separator: "\n")
        ftruncate(descriptor, 0)
        lseek(descriptor, 0, SEEK_SET)
        _ = metadata.withCString { write(descriptor, $0, strlen($0)) }
    }

    private func installSingleInstanceWakeObserver() {
        guard singleInstanceWakeObserver == nil else {
            return
        }

        let identifier = singleInstanceIdentifier
        let wakeRequestedName = Self.singleInstanceWakeRequestedNotificationName(for: identifier)
        let wakeAcknowledgedName = Self.singleInstanceWakeAcknowledgedNotificationName(for: identifier)
        singleInstanceWakeObserver = DistributedNotificationCenter.default().addObserver(
            forName: wakeRequestedName,
            object: identifier,
            queue: .main
        ) { [weak self] notification in
            guard let requestID = notification.userInfo?["requestID"] as? String else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.settingsWindowController?.showSettings()
                NSApp.activate(ignoringOtherApps: true)
                DistributedNotificationCenter.default().postNotificationName(
                    wakeAcknowledgedName,
                    object: identifier,
                    userInfo: [
                        "requestID": requestID,
                        "pid": NSNumber(value: ProcessInfo.processInfo.processIdentifier)
                    ],
                    deliverImmediately: true
                )
            }
        }
    }

    // MARK: - Source refresh timer

    private func installSourceRefreshTimer(interval: TimeInterval) {
        sourceRefreshTimer?.invalidate()
        sourceRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appModel.refreshSources()
            }
        }
    }

    private func updateSourceRefreshTimer(for state: SessionState) {
        guard state == .running else {
            sourceRefreshTimer?.invalidate()
            sourceRefreshTimer = nil
            return
        }

        installSourceRefreshTimer(interval: 5.0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["V2S_TESTING"] != "1" else { return }
        // A duplicate instance must not initialize a model or overwrite the owner's settings on exit.
        guard didInitializeApplication else {
            releaseSingleInstanceLock()
            return
        }
        if let singleInstanceWakeObserver {
            DistributedNotificationCenter.default().removeObserver(singleInstanceWakeObserver)
            self.singleInstanceWakeObserver = nil
        }
        sourceRefreshTimer?.invalidate()
        sourceRefreshTimer = nil
        cancellables.removeAll()
        appModel.persistSettings()
        appModel.flushSettings()
        // The next owner may read only after the final snapshot has reached disk.
        releaseSingleInstanceLock()
    }
}

private extension AppDelegate {
    nonisolated static let singleInstanceWakeAcknowledgementTimeout: TimeInterval = 0.35

    nonisolated static func singleInstanceWakeRequestedNotificationName(
        for identifier: String
    ) -> Notification.Name {
        Notification.Name("\(identifier).singleInstanceWakeRequested")
    }

    nonisolated static func singleInstanceWakeAcknowledgedNotificationName(
        for identifier: String
    ) -> Notification.Name {
        Notification.Name("\(identifier).singleInstanceWakeAcknowledged")
    }
}
