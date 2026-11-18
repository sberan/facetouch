import AVFoundation
import Vision
import AppKit

// MARK: - Touch zone

/// Convex outline of the face from Vision's landmarks, in Vision-normalized coordinates.
/// Landmarks stop at the eyebrows, so forehead points are added by pushing the brows away
/// from the chin by half the chin-to-brow distance.
func faceOutline(for face: VNFaceObservation) -> [CGPoint] {
    let box = face.boundingBox
    func inImage(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
        (region?.normalizedPoints ?? []).map { CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) }
    }
    let landmarks = face.landmarks
    var points = inImage(landmarks?.allPoints)
    let contour = inImage(landmarks?.faceContour)
    let brows = inImage(landmarks?.leftEyebrow) + inImage(landmarks?.rightEyebrow)
    if !contour.isEmpty && !brows.isEmpty {
        let chin = contour[contour.count / 2]
        let browX = brows.map(\.x).reduce(0, +) / CGFloat(brows.count)
        let browY = brows.map(\.y).reduce(0, +) / CGFloat(brows.count)
        let up = CGPoint(x: (browX - chin.x) * 0.5, y: (browY - chin.y) * 0.5)
        points += brows.map { CGPoint(x: $0.x + up.x, y: $0.y + up.y) }
    }
    if points.count < 3 {
        points = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                  CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
    }
    return convexHull(points)
}

/// How close a hand bone's center line must come to the face outline to count as touching,
/// as a fraction of image width: about half a finger's width plus a small margin.
func touchReach(for face: VNFaceObservation) -> CGFloat {
    face.boundingBox.width * 0.18
}

private func convexHull(_ points: [CGPoint]) -> [CGPoint] {
    let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    var lower: [CGPoint] = [], upper: [CGPoint] = []
    for p in sorted {
        while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
        lower.append(p)
    }
    for p in sorted.reversed() {
        while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
        upper.append(p)
    }
    return Array(lower.dropLast() + upper.dropLast())
}

/// A segment between two connected hand joints, in Vision-normalized coordinates.
/// A joint whose neighbours weren't detected becomes a zero-length bone so it still counts.
struct HandBone {
    let a: CGPoint
    let b: CGPoint
}

private let handChains: [[VNHumanHandPoseObservation.JointName]] = [
    [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
    [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
    [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
    [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
    [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip],
]

func handBones(_ hand: VNHumanHandPoseObservation) -> [HandBone] {
    func point(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
        guard let p = try? hand.recognizedPoint(joint), p.confidence > 0.3 else { return nil }
        return p.location
    }
    var bones: [HandBone] = []
    for chain in handChains {
        let points = chain.map(point)
        for (i, p) in points.enumerated() {
            guard let p else { continue }
            let next = i + 1 < points.count ? points[i + 1] : nil
            let prev = i > 0 ? points[i - 1] : nil
            if let next { bones.append(HandBone(a: p, b: next)) }
            else if prev == nil { bones.append(HandBone(a: p, b: p)) }
        }
    }
    return bones
}

/// Vision coordinates are normalized separately per axis, so x is scaled by the image aspect
/// ratio to make distances round instead of stretched.
func bone(_ bone: HandBone, touches outline: [CGPoint], reach: CGFloat, aspect: CGFloat) -> Bool {
    func fix(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * aspect, y: p.y) }
    return segmentDistance(fix(bone.a), fix(bone.b), to: outline.map(fix)) <= reach * aspect
}

private func segmentDistance(_ a: CGPoint, _ b: CGPoint, to polygon: [CGPoint]) -> CGFloat {
    if polygonContains(polygon, a) || polygonContains(polygon, b) { return 0 }
    var best = CGFloat.infinity
    for i in polygon.indices {
        let e1 = polygon[i], e2 = polygon[(i + 1) % polygon.count]
        if segmentsIntersect(a, b, e1, e2) { return 0 }
        best = min(best, pointDistance(a, toSegment: e1, e2), pointDistance(b, toSegment: e1, e2),
                   pointDistance(e1, toSegment: a, b), pointDistance(e2, toSegment: a, b))
    }
    return best
}

private func polygonContains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
    var inside = false
    var j = polygon.count - 1
    for i in polygon.indices {
        let a = polygon[i], b = polygon[j]
        if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        j = i
    }
    return inside
}

private func pointDistance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

private func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ q1: CGPoint, _ q2: CGPoint) -> Bool {
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    let d1 = cross(q1, q2, p1), d2 = cross(q1, q2, p2), d3 = cross(p1, p2, q1), d4 = cross(p1, p2, q2)
    return (d1 > 0) != (d2 > 0) && (d3 > 0) != (d4 > 0)
}

func handTouchesFace(bones: [HandBone], face: VNFaceObservation, aspect: CGFloat) -> Bool {
    let outline = faceOutline(for: face)
    let reach = touchReach(for: face)
    return bones.contains { bone($0, touches: outline, reach: reach, aspect: aspect) }
}

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
    let threshold = UserDefaults.standard.double(forKey: "mouthCoverThreshold")
    if threshold <= 0 { return (false, delta) }  // off
    return (delta > threshold, delta)
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
    private var clearFramesInARow = 0
    private let onResult: (CheckResult) -> Void
    private let onCheckStarted: () -> Void
    private let queue = DispatchQueue(label: "facetouch.capture", qos: .utility)
    private let history = CheckHistory.shared
    var interval: TimeInterval = 10.0
    private var manuallyPaused = false
    private var screenAsleep = false
    private(set) var onBattery = false
    var paused: Bool { manuallyPaused || screenAsleep || onBattery }

    func setBatteryPower(_ value: Bool) {
        guard onBattery != value else { return }
        onBattery = value
        if paused { suspendCapture() } else { restartTimer(); captureFrames() }
    }

    private func suspendCapture() {
        timer?.invalidate()
        timer = nil
        queue.sync {
            continuousMode = false
            framesToAnalyze = 0
            captureSession?.stopRunning()
        }
    }
    private var resumeTimer: Timer?

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
            self?.screenAsleep = true
            self?.suspendCapture()
        })
        screenObservers.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screenAsleep = false
            self?.restartTimer()
            self?.captureFrames()
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
        manuallyPaused = true
        resumeTimer?.invalidate()
        resumeTimer = nil
        suspendCapture()
    }

    func pauseFor(_ duration: TimeInterval) {
        pause()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.resume()
        }
    }

    func resume() {
        manuallyPaused = false
        resumeTimer?.invalidate()
        resumeTimer = nil
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
        // The first frames after a cold start are dark while exposure settles, so hands often
        // aren't found yet; look at up to ~1s of frames and alert on the first touching one.
        framesToAnalyze = 30

        queue.async { [weak self] in
            guard let self, !self.paused else { return }
            self.captureSession?.startRunning()
        }
    }

    private func stopCamera() {
        queue.async { [weak self] in
            self?.captureSession?.stopRunning()
        }
    }

    private func enterContinuousMode() {
        clearFramesInARow = 0
        guard !continuousMode else { return }
        framesToAnalyze = 0
        continuousMode = true
    }

    private func shouldEndOnFaceMissing() -> Bool {
        if continuousMode {
            // A hand on the face often hides it from Vision, so a missing face during an alert
            // usually means the touch is still happening; only end after ~2s of misses in a row.
            // A visible face with no hand on it ends the alert immediately instead.
            clearFramesInARow += 1
            return clearFramesInARow >= 60
        }
        return framesToAnalyze == 0
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
            guard shouldEndOnFaceMissing() else { return }
            if continuousMode { exitContinuousMode() }
            stopCamera()
            history.add(.noFaceDetected)
            onResult(.clear)
            return
        }

        // Check mouth covered
        let (mouthCovered, _) = detectMouthCovered(pixelBuffer: pixelBuffer, face: face)
        if mouthCovered {
            history.add(.mouthCovered)
            onResult(.mouthCovered)
            enterContinuousMode()
            return
        }

        guard !hands.isEmpty else {
            if !continuousMode && framesToAnalyze > 0 { return }
            if continuousMode { exitContinuousMode() }
            stopCamera()
            history.add(.clear)
            onResult(.clear)
            return
        }

        let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let bones = hands.flatMap(handBones)
        let touching = faces.contains { handTouchesFace(bones: bones, face: $0, aspect: aspect) }

        if touching {
            history.add(.faceTouch)
            onResult(.faceTouch)
            enterContinuousMode()
        } else {
            if !continuousMode && framesToAnalyze > 0 { return }
            if continuousMode { exitContinuousMode() }
            stopCamera()
            history.add(.clear)
            onResult(.clear)
        }
    }

}

extension FaceTouchDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !paused else { return }
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
