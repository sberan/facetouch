import SwiftUI
import AVFoundation
import Vision
import AppKit

// MARK: - Shared Camera Session

class SharedCameraSession: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var session: AVCaptureSession?
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    private let queue = DispatchQueue(label: "facetouch.camera", qos: .userInitiated)
    var frameHandler: ((CMSampleBuffer) -> Void)?
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .hd1280x720

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera) else { return }

        do {
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            camera.unlockForConfiguration()
        } catch {}

        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.previewLayer = layer
        self.session = session
        self.isRunning = true

        queue.async { session.startRunning() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        frameHandler = nil
        queue.sync { session?.stopRunning() }
        session = nil
        previewLayer = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameHandler?(sampleBuffer)
    }
}

// MARK: - Touch Detection Controller

class TouchDetectionController: ObservableObject {
    @Published var touching = false
    @Published var mouthCovered = false
    @Published var mouthColorDelta: Double = 0
    @Published var faceDetected = false
    @Published var handsDetected = false
    @Published var statusText = "Starting camera..."
    @Published var debugShapes = DebugShapes()

    /// Vision-normalized geometry (origin bottom-left) for drawing over the preview.
    struct DebugShapes {
        var imageSize = CGSize(width: 1280, height: 720)
        var faceOutlines: [[CGPoint]] = []
        var handBones: [(bone: HandBone, touching: Bool)] = []
        var reach: CGFloat = 0.02
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        let faceRequest = VNDetectFaceLandmarksRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 2

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([faceRequest, handRequest])

        let faces = faceRequest.results ?? []
        let hands = handRequest.results ?? []

        // Mouth-covered detection
        var isMouthCovered = false
        var delta = 0.0
        if let face = faces.first {
            (isMouthCovered, delta) = detectMouthCovered(pixelBuffer: pixelBuffer, face: face)
        }

        let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let bones = hands.flatMap(handBones)
        let isTouching = faces.contains { handTouchesFace(bones: bones, face: $0, aspect: aspect) }

        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let shapes = DebugShapes(
            imageSize: imageSize,
            faceOutlines: faces.map(faceOutline),
            handBones: bones.map { b in
                (b, faces.contains { handTouchesFace(bones: [b], face: $0, aspect: aspect) })
            },
            reach: faces.first.map(touchReach) ?? 0.02
        )

        DispatchQueue.main.async {
            self.faceDetected = !faces.isEmpty
            self.handsDetected = !hands.isEmpty
            self.touching = isTouching
            self.mouthCovered = isMouthCovered
            self.mouthColorDelta = delta
            self.debugShapes = shapes
            if isMouthCovered {
                self.statusText = "MOUTH COVERED"
            } else if isTouching {
                self.statusText = "FACE TOUCH DETECTED"
            } else if faces.isEmpty {
                self.statusText = "No face detected"
            } else if hands.isEmpty {
                self.statusText = "Face detected — hands not visible"
            } else {
                self.statusText = "Clear — no face touching"
            }
        }
    }
}

// MARK: - Camera Preview

struct CameraPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.transform = CATransform3DMakeScale(-1, 1, 1)
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        layer.frame = nsView.bounds
    }
}

// MARK: - Detection Overlay

struct DetectionOverlay: View {
    let shapes: TouchDetectionController.DebugShapes

    var body: some View {
        Canvas { context, size in
            // Matches the preview layer's aspect-fill.
            let scale = max(size.width / shapes.imageSize.width, size.height / shapes.imageSize.height)
            let drawn = CGSize(width: shapes.imageSize.width * scale, height: shapes.imageSize.height * scale)
            let origin = CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)

            func toView(_ p: CGPoint) -> CGPoint {
                CGPoint(x: origin.x + p.x * drawn.width, y: origin.y + (1 - p.y) * drawn.height)
            }
            func toView(_ r: CGRect) -> CGRect {
                let a = toView(CGPoint(x: r.minX, y: r.minY)), b = toView(CGPoint(x: r.maxX, y: r.maxY))
                return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            }

            for outline in shapes.faceOutlines where outline.count > 2 {
                var path = Path()
                path.addLines(outline.map(toView))
                path.closeSubpath()
                context.stroke(path, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
            let padWidth = shapes.reach * drawn.width * 2
            for item in shapes.handBones {
                let a = toView(item.bone.a), b = toView(item.bone.b)
                var bone = Path()
                bone.move(to: a)
                bone.addLine(to: b)
                let color: Color = item.touching ? .red : .orange
                context.stroke(bone, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: padWidth, lineCap: .round))
                context.stroke(bone, with: .color(color), lineWidth: 2)
                for c in [a, b] {
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Test Mode View

struct TestModeView: View {
    @StateObject var camera = SharedCameraSession()
    @StateObject var touchController = TouchDetectionController()

    func cleanup() {
        camera.stop()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let layer = camera.previewLayer {
                CameraPreview(layer: layer)
                    .frame(minWidth: 520, minHeight: 390)
                    .overlay { DetectionOverlay(shapes: touchController.debugShapes) }
                    .overlay(alignment: .top) {
                        if touchController.mouthCovered {
                            Text("MOUTH COVERED!")
                                .font(.title.bold())
                                .foregroundColor(.white)
                                .padding(8)
                                .background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                                .padding(.top, 12)
                        } else if touchController.touching {
                            Text("FACE TOUCH!")
                                .font(.title.bold())
                                .foregroundColor(.white)
                                .padding(8)
                                .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                                .padding(.top, 12)
                        }
                    }
            } else {
                Rectangle()
                    .fill(.black)
                    .frame(minWidth: 520, minHeight: 390)
                    .overlay { ProgressView().controlSize(.large) }
            }

            HStack(spacing: 16) {
                Circle().fill(touchController.faceDetected ? .green : .gray).frame(width: 10, height: 10)
                Text("Face").font(.caption)
                Circle().fill(touchController.handsDetected ? .green : .gray).frame(width: 10, height: 10)
                Text("Hands").font(.caption)
                Text("Lip Δ \(Int(touchController.mouthColorDelta))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(touchController.mouthCovered ? .orange : .secondary)
                Spacer()
                Text(touchController.statusText)
                    .font(.caption)
                    .foregroundColor(touchController.touching || touchController.mouthCovered ? .red : .secondary)
            }
            .padding(10)
            .background(.bar)
        }
        .onAppear {
            camera.start()
            camera.frameHandler = { [weak touchController] sampleBuffer in
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                touchController?.processFrame(pixelBuffer)
            }
        }
    }
}
