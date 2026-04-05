import AVFoundation
import Vision
import AppKit

// MARK: - Mouth-covered detection via color comparison

/// Returns (isCovered, colorDelta)
func detectMouthCovered(pixelBuffer: CVPixelBuffer, face: VNFaceObservation) -> (Bool, Double) {
    guard let lm = face.landmarks,
          let outerLips = lm.outerLips,
          let nose = lm.nose else { return (false, 0) }

    let box = face.boundingBox
    let mouthPts = outerLips.normalizedPoints.map {
        CGPoint(x: box.origin.x + $0.x * box.width,
                y: box.origin.y + $0.y * box.height)
    }
    guard let mouthRGB = sampleRGBAroundPoints(pixelBuffer: pixelBuffer, points: mouthPts) else { return (false, 0) }

    let nosePts = nose.normalizedPoints
    let noseCenterX = nosePts.map { $0.x }.reduce(0, +) / CGFloat(nosePts.count)
    let noseCenterY = nosePts.map { $0.y }.reduce(0, +) / CGFloat(nosePts.count)
    let cheekRect = CGRect(
        x: box.origin.x + (noseCenterX - 0.30) * box.width,
        y: box.origin.y + (noseCenterY - 0.08) * box.height,
        width: box.width * 0.12,
        height: box.height * 0.10
    )
    guard let cheekRGB = sampleRGBInRect(pixelBuffer: pixelBuffer, rect: cheekRect) else { return (false, 0) }

    let dr = mouthRGB.r - cheekRGB.r
    let dg = mouthRGB.g - cheekRGB.g
    let db = mouthRGB.b - cheekRGB.b
    let delta = sqrt(dr * dr + dg * dg + db * db)
    return (delta > 40, delta)
}

private func sampleRGBAroundPoints(pixelBuffer: CVPixelBuffer, points: [CGPoint]) -> (r: Double, g: Double, b: Double)? {
    guard !points.isEmpty else { return nil }
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let buf = base.assumingMemoryBound(to: UInt8.self)

    var totalR = 0.0, totalG = 0.0, totalB = 0.0, count = 0.0
    for pt in points {
        let px = Int(pt.x * CGFloat(width))
        let py = Int((1 - pt.y) * CGFloat(height))
        for dy in -2...2 {
            for dx in -2...2 {
                let x = min(max(px + dx, 0), width - 1)
                let y = min(max(py + dy, 0), height - 1)
                let offset = y * bytesPerRow + x * 4  // BGRA
                totalB += Double(buf[offset])
                totalG += Double(buf[offset + 1])
                totalR += Double(buf[offset + 2])
                count += 1
            }
        }
    }
    guard count > 0 else { return nil }
    return (r: totalR / count, g: totalG / count, b: totalB / count)
}

private func sampleRGBInRect(pixelBuffer: CVPixelBuffer, rect: CGRect) -> (r: Double, g: Double, b: Double)? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let buf = base.assumingMemoryBound(to: UInt8.self)

    let x0 = max(Int(rect.origin.x * CGFloat(width)), 0)
    let x1 = min(Int((rect.origin.x + rect.width) * CGFloat(width)), width - 1)
    let y0Top = max(Int((1 - rect.origin.y - rect.height) * CGFloat(height)), 0)
    let y1Top = min(Int((1 - rect.origin.y) * CGFloat(height)), height - 1)
    guard x1 > x0, y1Top > y0Top else { return nil }

    var totalR = 0.0, totalG = 0.0, totalB = 0.0, count = 0.0
    for y in stride(from: y0Top, to: y1Top, by: 2) {
        for x in stride(from: x0, to: x1, by: 2) {
            let offset = y * bytesPerRow + x * 4
            totalB += Double(buf[offset])
            totalG += Double(buf[offset + 1])
            totalR += Double(buf[offset + 2])
            count += 1
        }
    }
    guard count > 0 else { return nil }
    return (r: totalR / count, g: totalG / count, b: totalB / count)
}

final class FaceTouchDetector: NSObject {
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var timer: Timer?
    private var framesToAnalyze = 0
    private var continuousMode = false
    private let onResult: (CheckResult) -> Void
    private let onCheckStarted: () -> Void
    private let queue = DispatchQueue(label: "facetouch.capture", qos: .utility)
    private let history = CheckHistory.shared
    var interval: TimeInterval = 10.0
    var paused = false

    init(onResult: @escaping (CheckResult) -> Void, onCheckStarted: @escaping () -> Void) {
        self.onResult = onResult
        self.onCheckStarted = onCheckStarted
    }

    private var screenObservers: [NSObjectProtocol] = []

    func start() {
        setupCamera()
        restartTimer()
        captureFrames()

        // Pause when screen sleeps, resume when it wakes
        let nc = NSWorkspace.shared.notificationCenter
        screenObservers.append(nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pause()
        })
        screenObservers.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard self?.paused == true else { return }
            self?.resume()
        })
    }

    func restartTimer() {
        timer?.invalidate()
        guard !paused else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, !self.continuousMode else { return }
            self.captureFrames()
        }
    }

    func pause() {
        paused = true
        timer?.invalidate()
        timer = nil
        continuousMode = false
        framesToAnalyze = 0
        captureSession?.stopRunning()
    }

    func resume() {
        paused = false
        restartTimer()
        captureFrames()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        captureSession?.stopRunning()
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .hd1280x720

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            history.add(.error("No camera available"))
            return
        }

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

        self.captureSession = session
        self.videoOutput = output
    }

    private func captureFrames() {
        guard !paused else { return }
        onCheckStarted()
        framesToAnalyze = 5

        queue.async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    private func stopCamera() {
        queue.async { [weak self] in
            self?.captureSession?.stopRunning()
        }
    }

    private func enterContinuousMode() {
        guard !continuousMode else { return }
        continuousMode = true
    }

    private func exitContinuousMode() {
        guard continuousMode else { return }
        continuousMode = false
        stopCamera()
    }

    private func analyze(pixelBuffer: CVPixelBuffer) {
        let faceRequest = VNDetectFaceLandmarksRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 2

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([faceRequest, handRequest])
        } catch {
            history.add(.error(error.localizedDescription))
            onResult(.error(error.localizedDescription))
            return
        }

        let faces = faceRequest.results ?? []
        let hands = handRequest.results ?? []

        guard let face = faces.first else {
            if framesToAnalyze > 0 { return }
            if continuousMode { exitContinuousMode() }
            stopCamera()
            history.add(.noFaceDetected)
            onResult(.noFaceDetected)
            return
        }

        framesToAnalyze = 0

        // Check mouth covered
        let (mouthCovered, _) = detectMouthCovered(pixelBuffer: pixelBuffer, face: face)
        if mouthCovered {
            history.add(.mouthCovered)
            onResult(.mouthCovered)
            enterContinuousMode()
            return
        }

        guard !hands.isEmpty else {
            if continuousMode { exitContinuousMode() }
            stopCamera()
            history.add(.clear)
            onResult(.clear)
            return
        }

        let faceBounds = faces.map { $0.boundingBox }

        var handPoints: [CGPoint] = []
        for hand in hands {
            let jointNames: [VNHumanHandPoseObservation.JointName] = [
                .indexTip, .middleTip, .ringTip, .littleTip, .thumbTip,
                .indexMCP, .middleMCP, .ringMCP, .littleMCP,
                .wrist
            ]
            for joint in jointNames {
                if let point = try? hand.recognizedPoint(joint), point.confidence > 0.3 {
                    handPoints.append(point.location)
                }
            }
        }

        let touching = handPoints.contains { point in
            faceBounds.contains { face in
                let expanded = face.insetBy(dx: -face.width * 0.2, dy: -face.height * 0.2)
                return expanded.contains(point)
            }
        }

        if touching {
            history.add(.faceTouch)
            onResult(.faceTouch)
            enterContinuousMode()
        } else {
            if continuousMode { exitContinuousMode() }
            stopCamera()
            history.add(.clear)
            onResult(.clear)
        }
    }

}

extension FaceTouchDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if continuousMode {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            analyze(pixelBuffer: pixelBuffer)
        } else {
            guard framesToAnalyze > 0 else { return }
            framesToAnalyze -= 1
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            analyze(pixelBuffer: pixelBuffer)
        }
    }
}
