import AppKit
import SwiftUI

class OverlayWindow {
    private var windows: [NSWindow] = []

    var isShowing: Bool { !windows.isEmpty }

    func show() {
        guard windows.isEmpty else { return }

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let hostingView = NSHostingView(rootView: OverlayView(dismiss: { [weak self] in
                self?.dismiss()
            }))
            window.contentView = hostingView
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func dismiss() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}

struct OverlayView: View {
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.red.opacity(0.45)

            VStack(spacing: 16) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 72))
                    .foregroundColor(.white)

                Text("Don't touch your face!")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.white)

                Text("Click anywhere to dismiss")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .ignoresSafeArea()
        .onTapGesture { dismiss() }
    }
}
