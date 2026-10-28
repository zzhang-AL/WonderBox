import AppKit
import SwiftUI

@main
struct WonderBoxApplication: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(DockPresenceController.self) private var dockPresence
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("accent") private var accent = AccentChoice.ocean.rawValue
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage(MenuBarIconStyle.storageKey) private var menuBarIconStyle = MenuBarIconStyle.defaultStyle
    @AppStorage("awakeDuration") private var awakeDuration = AwakeDuration.oneHour.rawValue
    @AppStorage("keepDisplayAwake") private var keepDisplayAwake = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    private var selectedAccent: AccentChoice {
        AccentChoice(rawValue: accent) ?? .ocean
    }

    private var selectedAwakeDuration: AwakeDuration {
        AwakeDuration(rawValue: awakeDuration) ?? .oneHour
    }

    var body: some Scene {
        // A single window: every window shares `model.selection`, so a second one would only mirror the first.
        Window("WonderBox", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.metrics)
                .preferredColorScheme(selectedAppearance.colorScheme)
                .tint(selectedAccent.color)
                .frame(minWidth: 980, minHeight: 660)
                .reportsMainWindow(to: dockPresence)
                .onAppear { model.startMonitoring(); model.startApplicationServices() }
                .onOpenURL { url in
                    guard url.scheme == "wonderbox", url.host == "uninstall-review" else { return }
                    dockPresence.willShowMainWindow()
                    openWindow(id: "main")
                    Task { await model.uninstallWatcher.checkPendingEvents() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.startMonitoring()
                        model.startApplicationServices()
                    } else if phase == .background {
                        model.stopMonitoring()
                    }
                }
        }
        .defaultSize(width: 1_180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                if UpdateController.isSupported {
                    Button("Check for Updates…") {
                        model.selection = .settings
                        dockPresence.willShowMainWindow()
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                        model.updater.check()
                    }
                }
            }
            CommandMenu("Tools") {
                CurrentSectionRefreshButton(controller: model.sectionRefresh, section: model.selection ?? .overview)
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button(model.sleepPreventer.isActive ? "Stop Keeping Awake" : "Keep Awake Indefinitely") {
                    if model.sleepPreventer.isActive {
                        model.sleepPreventer.disable()
                    } else {
                        model.sleepPreventer.enable(
                            duration: selectedAwakeDuration.seconds,
                            keepDisplayAwake: keepDisplayAwake
                        )
                    }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel(preventer: model.sleepPreventer, optimizer: model.memoryOptimizer)
                .environmentObject(model)
                .environmentObject(model.metrics)
                .environmentObject(dockPresence)
                .preferredColorScheme(selectedAppearance.colorScheme)
        } label: {
            Image(nsImage: MenuBarAppIcon.image(for: menuBarIconStyle))
                .accessibilityLabel("WonderBox")
        }
        .menuBarExtraStyle(.window)
    }
}
