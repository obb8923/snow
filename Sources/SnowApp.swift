import SwiftUI
import AppKit
import Combine
import QuartzCore

@main
struct SnowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Snow", systemImage: "snowflake") {
            SettingsView()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlays: [OverlayWindow] = []
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var enabledSub: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildOverlays()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        enabledSub = Settings.shared.$enabled.sink { [weak self] on in
            self?.overlays.forEach { on ? $0.orderFrontRegardless() : $0.orderOut(nil) }
        }
    }

    @objc private func screensChanged() { buildOverlays() }

    private func buildOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = NSScreen.screens.map { OverlayWindow(screen: $0) }
        SnowEngine.shared.setScreens(NSScreen.screens.map { cgRect(fromCocoa: $0.frame) })
        if Settings.shared.enabled { overlays.forEach { $0.orderFrontRegardless() } }
        link?.invalidate()
        link = overlays.first?.overlayView.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        lastTime = 0
    }

    @objc private func tick(_ l: CADisplayLink) {
        let t = l.timestamp
        let dt = lastTime == 0 ? 1.0 / 60 : min(1.0 / 20, t - lastTime)
        lastTime = t
        guard Settings.shared.enabled else { return }
        SnowEngine.shared.step(CGFloat(dt))
        overlays.forEach { $0.overlayView.needsDisplay = true }
    }
}

struct SettingsView: View {
    @ObservedObject private var s = Settings.shared
    @State private var axTrusted = WindowTracker.accessibilityTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("눈 내리기", isOn: $s.enabled).toggleStyle(.switch)
            Divider()
            SliderRow(title: "눈 양", value: $s.amount, range: 0...600, step: 5) { "\(Int($0))" }
            SliderRow(title: "떨어지는 속도", value: $s.speed, range: 0.2...2.5, step: 0.1) { String(format: "%.1f×", $0) }
            SliderRow(title: "눈송이 크기", value: $s.size, range: 0.4...3, step: 0.1) { String(format: "%.1f×", $0) }
            SliderRow(title: "바람", value: $s.wind, range: -10...10, step: 1) { $0 > 0 ? "+\(Int($0))" : "\(Int($0))" }
            SliderRow(title: "접착력", value: $s.stick, range: 0...1, step: 0.01) { "\(Int($0 * 100))%" }
            SliderRow(title: "녹는 속도", value: $s.melt, range: 0...10, step: 1) { "\(Int($0))" }
            if !axTrusted {
                Divider()
                Text("Dock 위에 쌓이려면 손쉬운 사용 권한이 필요합니다. 목록에 Snow가 이미 있으면 − 로 지우고 다시 추가하세요.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("손쉬운 사용 설정 열기") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            Divider()
            HStack {
                Button("쌓인 눈 치우기") { SnowEngine.shared.clear() }
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear { axTrusted = WindowTracker.accessibilityTrusted }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            axTrusted = WindowTracker.accessibilityTrusted
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
