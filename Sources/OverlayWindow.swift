import AppKit
import AVFoundation
import SwiftUI

let alertRampSeconds = 15.0

/// Sawtooth buzz that ramps from silent to full volume over the same time as the red fade.
final class Buzzer {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?

    func start() {
        guard source == nil else { return }
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

        let rampSamples = sampleRate * alertRampSeconds
        var phase = 0.0
        var elapsed = 0.0
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let out = UnsafeMutableAudioBufferListPointer(bufferList)[0].mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<Int(frameCount) {
                let volume = 0.4 * min(elapsed / rampSamples, 1)
                out[frame] = Float(volume * (phase * 2 - 1))
                phase = (phase + 110 / sampleRate).truncatingRemainder(dividingBy: 1)
                elapsed += 1
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
        try? engine.start()
    }

    func stop() {
        guard let node = source else { return }
        engine.stop()
        engine.detach(node)
        source = nil
    }
}

class OverlayWindow {
    private var windows: [NSWindow] = []
    private let buzzer = Buzzer()

    var isShowing: Bool { !windows.isEmpty }

    func show() {
        guard windows.isEmpty else { return }
        buzzer.start()

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
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let hostingView = NSHostingView(rootView: OverlayView())
            window.contentView = hostingView
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func dismiss() {
        buzzer.stop()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}

struct OverlayView: View {
    @State private var redOpacity = 0.0

    var body: some View {
        ZStack {
            Color.red.opacity(redOpacity)

            VStack(spacing: 16) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 72))
                    .foregroundColor(.white)

                Text("Don't touch your face!")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.linear(duration: alertRampSeconds)) {
                redOpacity = 1
            }
        }
    }
}
