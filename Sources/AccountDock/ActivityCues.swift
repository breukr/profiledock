import AppKit
import SwiftUI
import QuartzCore
import DockCore

/// One coordinator for every display: visual cues may repeat across screens, audio never does.
@MainActor
final class ActivityCues {
    private var panels: [NSPanel] = []
    private var hide: DispatchWorkItem?
    private var pending: ActivitySignal?
    private var delivery: Task<Void, Never>?
    private var recent: [String: Date] = [:]
    private var sound: NSSound?
    private var lastSound = Date.distantPast

    func receive(_ event: ActivityEvent, model: DockModel) {
        let key = event.profileID + ":" + event.signal.rawValue
        let now = Date()
        guard now.timeIntervalSince(recent[key] ?? .distantPast) >= 5 else { return }
        recent = recent.filter { now.timeIntervalSince($0.value) < 60 }
        recent[key] = now
        // Combine simultaneous task events; input requests take precedence over completion.
        if pending != .needsInput { pending = event.signal }
        guard delivery == nil else { return }
        delivery = Task { [weak self, weak model] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let model else { return }
            self.delivery = nil
            guard let signal = self.pending else { return }
            self.pending = nil
            self.present(signal, model: model)
        }
    }

    func present(_ signal: ActivitySignal, model: DockModel, preview: Bool = false) {
        dismiss()
        if preview || model.preferences.activityCues != false {
            for screen in NSScreen.screens {
                let layout = IslandController.layout(screen: screen, model: model)
                let positions = ActivityCueLayout(screen: screen.frame, obstacle: layout.collapsed, floating: model.placement != .topCenter)
                for frame in [positions.left, positions.right] where frame.width >= 16 {
                    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.title = signal == .needsInput ? "ProfileDock: input needed" : "ProfileDock: task finished"
                    panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
                    panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
                    let view = NSHostingView(rootView: ActivityCueView(signal: signal))
                    view.sizingOptions = []; view.wantsLayer = true
                    panel.contentView = view
                    panel.orderFrontRegardless()
                    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        let pulse = CABasicAnimation(keyPath: "opacity")
                        pulse.fromValue = 0.35; pulse.toValue = 1; pulse.duration = 0.38
                        pulse.autoreverses = true; pulse.repeatCount = 2
                        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        view.layer?.add(pulse, forKey: "attention")
                    }
                    panels.append(panel)
                }
            }
            let item = DispatchWorkItem { [weak self] in self?.dismiss() }
            hide = item; DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
        }
        if model.preferences.activitySounds == true, preview || Date().timeIntervalSince(lastSound) >= 2 {
            sound?.stop()
            if let url = Bundle.main.url(forResource: signal.rawValue, withExtension: "wav", subdirectory: "Sounds"), let next = NSSound(contentsOf: url, byReference: true) {
                next.volume = Float(min(0.5, max(0, model.preferences.activitySoundVolume ?? 0.18)))
                sound = next; lastSound = Date(); next.play()
            }
        }
    }

    func dismiss() { hide?.cancel(); hide = nil; panels.forEach { $0.orderOut(nil) }; panels.removeAll() }
    func shutdown() { delivery?.cancel(); delivery = nil; pending = nil; dismiss(); sound?.stop() }
    var visiblePanelCount: Int { panels.count }
}

private struct ActivityCueView: View {
    let signal: ActivitySignal
    var body: some View {
        Image(systemName: signal == .needsInput ? "hand.raised.fill" : "checkmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(signal == .needsInput ? Color.orange : Color.green)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black, in: Capsule())
            .overlay(Capsule().stroke((signal == .needsInput ? Color.orange : Color.green).opacity(0.4), lineWidth: 1))
            .padding(1)
            .accessibilityLabel(signal == .needsInput ? "A task needs your input" : "A task finished")
    }
}
