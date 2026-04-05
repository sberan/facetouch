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
        session?.stopRunning()
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

    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        let faceRequest = VNDetectFaceLandmarksRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 2

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([faceRequest, handRequest])

        let faces = faceRequest.results ?? []
        let hands = handRequest.results ?? []
        let faceBounds = faces.map { $0.boundingBox }

        // Mouth-covered detection
        var isMouthCovered = false
        var delta = 0.0
        if let face = faces.first {
            (isMouthCovered, delta) = detectMouthCovered(pixelBuffer: pixelBuffer, face: face)
        }

        var handPoints: [CGPoint] = []
        for hand in hands {
            let joints: [VNHumanHandPoseObservation.JointName] = [
                .indexTip, .middleTip, .ringTip, .littleTip, .thumbTip,
                .indexMCP, .middleMCP, .ringMCP, .littleMCP, .wrist
            ]
            for joint in joints {
                if let point = try? hand.recognizedPoint(joint), point.confidence > 0.3 {
                    handPoints.append(point.location)
                }
            }
        }

        let isTouching = !faces.isEmpty && handPoints.contains { point in
            faceBounds.contains { face in
                let expanded = face.insetBy(dx: -face.width * 0.2, dy: -face.height * 0.2)
                return expanded.contains(point)
            }
        }

        DispatchQueue.main.async {
            self.faceDetected = !faces.isEmpty
            self.handsDetected = !hands.isEmpty
            self.touching = isTouching
            self.mouthCovered = isMouthCovered
            self.mouthColorDelta = delta
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
