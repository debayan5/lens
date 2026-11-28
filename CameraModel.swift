import AVFoundation
import Photos
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import UIKit
import CoreMotion

enum CamMode: String, CaseIterable { case photo = "PHOTO", portrait = "PORTRAIT", night = "LOW LIGHT" }

struct WhatsNew { let version: String; let changes: [String] }

final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "lens.session")
    private let proc = DispatchQueue(label: "lens.proc")
    private let ctx = CIContext()
    private let cs = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    private var device: AVCaptureDevice?
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    @Published var backLenses: [AVCaptureDevice] = []
    @Published var current: AVCaptureDevice?
    @Published var mode: CamMode = .photo
    @Published var rawMode = false
    @Published var mirrorSelfie = true
    @Published var flash: AVCaptureDevice.FlashMode = .off
    @Published var screenFlash = false
    @Published var depthOK = true
    @Published var appleProc = false
    @Published var steady = false
    @Published var waiting = false
    @Published var fps = 30
    @Published var zoom: CGFloat = 1
    @Published var focusPoint: CGPoint?
    @Published var thumb: UIImage?
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var toast = ""

    private var captureMode: CamMode = .photo
    private var nightAcc: CIImage?
    private var nightRef: CIImage?
    private var nightCount = 0
    private var nightO: Int32 = 6
    private let nightFrames = 8
    private let aperture: Double = 2.8   // portrait blur: lower = stronger
    private var origBrightness: CGFloat = 0.5
    private var captureApple = false
    private let motion = CMMotionManager()
    private let videoOut = AVCaptureVideoDataOutput()
    private let depthOut = AVCaptureDepthDataOutput()
    private var sync: AVCaptureDataOutputSynchronizer?
    private let previewQueue = DispatchQueue(label: "lens.preview")
    weak var liveLayer: CALayer?
    @Published var portraitLive = false
    @Published var showZoom = false
    private var zoomToken = 0
    @Published var whatsNew: WhatsNew?
    @Published var timer = 0
    @Published var countdown = 0
    private var cdToken = 0
    private var volObs: NSKeyValueObservation?
    private var lastButton = Date.distantPast
    private var blurFactor = 0.017
    @Published var blurLevel: Double = 0.5 { didSet { blurFactor = 0.004 + blurLevel * 0.026 } }
    private var lastFocusNorm = CGPoint(x: 0.5, y: 0.5)

    var isFront: Bool { current?.position == .front }

    // MARK: Setup

    func start() {
        watchVolume()
        checkWhatsNew()
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return }
            let found = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                mediaType: .video, position: .back).devices
            let sorted = found.sorted { self.factor($0) < self.factor($1) }
            DispatchQueue.main.async {
                self.backLenses = sorted
                self.selectBack()
            }
        }
    }

    func factor(_ d: AVCaptureDevice) -> Double {
        switch d.deviceType {
        case .builtInUltraWideCamera, .builtInDualWideCamera: return 0.5
        case .builtInTelephotoCamera: return 2
        default: return 1
        }
    }

    var displayZoom: Double { Double(zoom) * (current.map { factor($0) } ?? 1) }
    var zoomStops: [Double] {
        backLenses.contains { $0.deviceType == .builtInUltraWideCamera } ? [0.5, 1, 2] : [1, 2]
    }
    func nearestStop(_ z: Double) -> Double {
        zoomStops.min { abs(log(max(z, 0.01) / $0)) < abs(log(max(z, 0.01) / $1)) } ?? 1
    }

    func goZoom(_ stop: Double) {
        guard !isFront else { setZoom(CGFloat(stop)); return }
        let ultra = backLenses.first { $0.deviceType == .builtInUltraWideCamera }
        let wide = backLenses.first { $0.deviceType == .builtInWideAngleCamera }
        if stop < 1, let u = ultra {
            if current?.uniqueID == u.uniqueID { setZoom(1) } else { select(u) }
        } else if let w = wide {
            if current?.uniqueID == w.uniqueID { setZoom(CGFloat(stop)) } else { select(w, zoom: CGFloat(stop)) }
        }
    }

    private func flashZoom() {
        showZoom = true
        zoomToken += 1
        let t = zoomToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if t == self.zoomToken { self.showZoom = false } }
    }

    private func selectBack() {
        if mode == .portrait,
           let dw = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                 ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
            let z = dw.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) } ?? 1
            select(dw, zoom: z)
        } else if let w = backLenses.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? backLenses.first {
            select(w)
        }
    }

    func select(_ d: AVCaptureDevice, zoom z: CGFloat = 1) {
        current = d
        zoom = z
        let portrait = mode == .portrait
        let fast = !rawMode && !appleProc && mode != .portrait      // 60 fps viewfinder when possible
        let bias: Float = rawMode ? -1.0 : 0          // protect highlights in RAW
        queue.async {
            self.output.isDepthDataDeliveryEnabled = false
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            self.session.inputs.forEach { self.session.removeInput($0) }
            if let input = try? AVCaptureDeviceInput(device: d), self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            if !self.session.outputs.contains(self.output), self.session.canAddOutput(self.output) {
                self.session.addOutput(self.output)
            }
            self.session.commitConfiguration()
            self.device = d
            self.output.maxPhotoQualityPrioritization = .quality
            try? d.lockForConfiguration()
            let fpsNow = fast ? self.use60(d) : 30
            let depthNow = portrait ? self.useDepth(d) : false
            if let md = d.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width < $1.width }) {
                self.output.maxPhotoDimensions = md
            }
            if d.activeFormat.isVideoHDRSupported {
                d.automaticallyAdjustsVideoHDREnabled = false
                d.isVideoHDREnabled = false
            }
            d.videoZoomFactor = min(max(z, d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)
            d.setExposureTargetBias(min(max(bias, d.minExposureTargetBias), d.maxExposureTargetBias))
            d.unlockForConfiguration()
            self.configureLive(portrait && depthNow, front: d.position == .front)
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async {
                self.previewLayer?.session = self.session
                self.depthOK = portrait ? depthNow : true
                self.fps = fpsNow
            }
        }
    }

    private func use60(_ d: AVCaptureDevice) -> Int {
        let cands = d.formats.filter { f in
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(dim.width) * 3 == Int(dim.height) * 4 && dim.width >= 1024
                && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
                && f.supportedMaxPhotoDimensions.contains { $0.width >= 4000 }   // keep full-res stills
        }
        guard let best = cands.max(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <
            CMVideoFormatDescriptionGetDimensions($1.formatDescription).width }) else { return 30 }
        d.activeFormat = best
        d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
        d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
        if let md = best.supportedMaxPhotoDimensions.max(by: { $0.width < $1.width }) {
            output.maxPhotoDimensions = md
        }
        return 60
    }

    // Pick a 4:3 format that can deliver depth, set its depth format, and turn depth delivery on
    private func useDepth(_ d: AVCaptureDevice) -> Bool {
        func still(_ f: AVCaptureDevice.Format) -> Int32 { f.supportedMaxPhotoDimensions.map { $0.width }.max() ?? 0 }
        let cands = d.formats.filter { f in
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return !f.supportedDepthDataFormats.isEmpty && Int(dim.width) * 3 == Int(dim.height) * 4
        }
        let full = cands.filter { still($0) >= 4000 }
        guard let best = (full.isEmpty ? cands : full).min(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <
            CMVideoFormatDescriptionGetDimensions($1.formatDescription).width }) else { return false }
        d.activeFormat = best
        let all = best.supportedDepthDataFormats
        let disparity = all.filter {
            let t = CMFormatDescriptionGetMediaSubType($0.formatDescription)
            return t == kCVPixelFormatType_DisparityFloat32 || t == kCVPixelFormatType_DisparityFloat16
        }
        let pool = disparity.isEmpty ? all : disparity
        let small = pool.filter { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= 640 }
        if let df = (small.isEmpty ? pool : small).max(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <
            CMVideoFormatDescriptionGetDimensions($1.formatDescription).width }) {
            d.activeDepthDataFormat = df
        }
        if let md = best.supportedMaxPhotoDimensions.max(by: { $0.width < $1.width }) {
            output.maxPhotoDimensions = md
        }
        output.isDepthDataDeliveryEnabled = output.isDepthDataDeliverySupported
        return output.isDepthDataDeliveryEnabled
    }

    // Portrait live preview: video + depth frames, blurred in real time
    private func configureLive(_ on: Bool, front: Bool) {
        session.beginConfiguration()
        sync = nil
        if session.outputs.contains(videoOut) { session.removeOutput(videoOut) }
        if session.outputs.contains(depthOut) { session.removeOutput(depthOut) }
        var ok = false
        if on {
            videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOut.alwaysDiscardsLateVideoFrames = true
            depthOut.isFilteringEnabled = true
            depthOut.alwaysDiscardsLateDepthData = true
            if session.canAddOutput(videoOut) { session.addOutput(videoOut) }
            if session.canAddOutput(depthOut) { session.addOutput(depthOut) }
            for c in [videoOut.connection(with: .video), depthOut.connection(with: .depthData)] {
                guard let c = c else { continue }
                if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
                if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = front }
            }
            ok = session.outputs.contains(videoOut) && session.outputs.contains(depthOut)
        }
        session.commitConfiguration()
        if ok {
            let s = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOut, depthOut])
            s.setDelegate(self, queue: previewQueue)
            sync = s
        }
        DispatchQueue.main.async { self.portraitLive = ok }
    }

    private func reselect() { if let d = current { select(d, zoom: zoom) } }

    func toggleRaw() { rawMode.toggle(); if rawMode { appleProc = false }; reselect() }
    func toggleApple() { appleProc.toggle(); if appleProc { rawMode = false }; reselect() }

    func setMode(_ m: CamMode) {
        guard m != mode, !busy else { return }
        mode = m
        UISelectionFeedbackGenerator().selectionChanged()
        if !isFront { selectBack() } else { reselect() }
    }

    func flip() {
        guard !busy else { return }
        if isFront { selectBack() }
        else if let f = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) { select(f) }
    }

    func cycleFlash() {
        flash = flash == .off ? .auto : (flash == .auto ? .on : .off)
    }

    // MARK: What's new popup

    private func checkWhatsNew() {
        let cur = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard UserDefaults.standard.string(forKey: "lastSeenVersion") != cur else { return }
        var changes: [String] = []
        if let url = Bundle.main.url(forResource: "changelog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let versions = obj["versions"] as? [[String: Any]],
           let entry = versions.first(where: { ($0["version"] as? String) == cur }) ?? versions.first {
            changes = entry["changes"] as? [String] ?? []
        }
        whatsNew = WhatsNew(version: cur, changes: changes)
    }

    func dismissWhatsNew() {
        whatsNew = nil
        let cur = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        UserDefaults.standard.set(cur, forKey: "lastSeenVersion")
    }

    // MARK: Self-timer (off -> 3 s -> 5 s -> 10 s -> off)

    func cycleTimer() {
        timer = timer == 0 ? 3 : (timer == 3 ? 5 : (timer == 5 ? 10 : 0))
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func startCountdown(_ done: @escaping () -> Void) {
        countdown = timer
        cdToken += 1
        let tok = cdToken
        func step() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard tok == self.cdToken, self.countdown > 0 else { return }
                self.countdown -= 1
                if self.countdown == 0 { done() } else {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    step()
                }
            }
        }
        step()
    }

    private func cancelCountdown() { cdToken += 1; countdown = 0 }

    private func setConnMirror(_ on: Bool) {
        guard let c = output.connection(with: .video), c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = on
    }

    // MARK: Hardware buttons

    // Volume / Camera Control press (debounced so two mechanisms can't double-fire)
    func buttonCapture() {
        guard Date().timeIntervalSince(lastButton) > 0.8 else { return }
        lastButton = Date()
        DispatchQueue.main.async { self.capture() }
    }

    // Fallback if the system doesn't deliver button events to the app: watch the volume level
    private func watchVolume() {
        guard volObs == nil else { return }
        _ = Sounds.shared                          // activates the audio session
        volObs = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            self?.buttonCapture()
        }
    }

    func announce(_ t: String) { note(t) }

    // MARK: Controls

    func setZoom(_ z: CGFloat) {
        queue.async {
            guard let d = self.device else { return }
            let v = min(max(z, d.minAvailableVideoZoomFactor), min(d.maxAvailableVideoZoomFactor, 10))
            try? d.lockForConfiguration()
            d.videoZoomFactor = v
            d.unlockForConfiguration()
            DispatchQueue.main.async { self.zoom = v; self.flashZoom() }
        }
    }

    func focus(at p: CGPoint) {
        guard let layer = previewLayer else { return }
        let dp = layer.captureDevicePointConverted(fromLayerPoint: p)
        focusPoint = p
        lastFocusNorm = CGPoint(x: p.x / max(layer.bounds.width, 1), y: p.y / max(layer.bounds.height, 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.focusPoint = nil }
        queue.async {
            guard let d = self.device else { return }
            try? d.lockForConfiguration()
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = dp; d.focusMode = .autoFocus }
            if d.isExposurePointOfInterestSupported {
                d.exposurePointOfInterest = dp; d.exposureMode = .autoExpose
            }
            d.unlockForConfiguration()
        }
    }

    // MARK: Capture

    private var bgra: [String: Any] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }

    private func needsFlash() -> Bool {
        if flash == .on { return true }
        guard flash == .auto, let d = device else { return false }
        return d.iso > 500 || d.exposureDuration.seconds > 1.0 / 40
    }

    func capture() {
        if countdown > 0 { cancelCountdown(); return }                           // tap again to cancel the timer
        if waiting { motion.stopDeviceMotionUpdates(); waiting = false; return }   // tap again to cancel steady wait
        guard !busy else { return }
        if timer > 0 { startCountdown { self.captureNow() } } else { captureNow() }
    }

    private func captureNow() {
        if steady { waitSteady { self.performCapture() } } else { performCapture() }
    }

    private func performCapture() {
        captureMode = mode
        captureApple = appleProc && mode == .photo
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if mode == .night { startNight(); return }
        let raw = rawMode && mode == .photo, fl = flash, m = mode
        let screen = isFront && needsFlash()
        let apple = captureApple
        let mirrorSel = mirrorSelfie

        let shoot = {
            self.queue.async {
                // Apple-processed front photos: let the camera mirror them itself (keeps Apple's processing intact)
                self.setConnMirror(apple && mirrorSel && self.device?.position == .front)
                let s: AVCapturePhotoSettings
                if m == .portrait {
                    self.output.isDepthDataDeliveryEnabled = self.output.isDepthDataDeliverySupported
                    let codec: AVVideoCodecType = self.output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
                    s = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
                    s.photoQualityPrioritization = .speed
                    if self.output.isDepthDataDeliveryEnabled {
                        s.isDepthDataDeliveryEnabled = true
                        s.embedsDepthDataInPhoto = true
                    }
                } else if apple {
                    let codec: AVVideoCodecType = self.output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
                    s = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
                    s.photoQualityPrioritization = .quality
                    if !screen, self.output.supportedFlashModes.contains(fl) { s.flashMode = fl }
                } else if raw, let r = self.output.availableRawPhotoPixelFormatTypes
                    .first(where: { !AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                    s = AVCapturePhotoSettings(rawPixelFormatType: r)
                    // Embed a full-size preview so Photos reports the real resolution, not the tiny default thumbnail
                    let md = self.device?.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width < $1.width })
                    s.previewPhotoFormat = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: Int(md?.width ?? 4032),
                        kCVPixelBufferHeightKey as String: Int(md?.height ?? 3024)]
                } else {
                    s = AVCapturePhotoSettings(format: self.bgra)
                    s.photoQualityPrioritization = .speed
                    if m == .photo, !screen, self.output.supportedFlashModes.contains(fl) { s.flashMode = fl }
                }
                self.quiet(s)
                self.full(s)
                Sounds.shared.shutter()
                self.output.capturePhoto(with: s, delegate: self)
            }
        }

        if screen {
            // Front "Retina flash": full-white screen at max brightness, then shoot
            origBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1.0
            screenFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { shoot() }
        } else {
            shoot()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        proc.async {
            guard error == nil else { self.fail(); return }
            if photo.isRawPhoto {
                if let d = photo.fileDataRepresentation() { self.save(d, uti: "com.adobe.raw-image") }
                return
            }
            if self.captureMode == .portrait { self.portrait(photo); return }
            if self.captureApple { self.appleSave(photo); return }
            guard let pb = photo.pixelBuffer else { self.fail(); return }
            switch self.captureMode {
            case .night: self.nightStep(photo, pb)
            case .portrait: break
            case .photo: self.savePNG(self.mirror(CIImage(cvPixelBuffer: pb).oriented(forExifOrientation: self.orient(photo))))
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        DispatchQueue.main.async {
            if self.screenFlash {
                self.screenFlash = false
                UIScreen.main.brightness = self.origBrightness
            }
        }
    }

    // MARK: Apple processing, steady shutter, thumbnails

    private func setThumb(_ img: CIImage) {
        let t = img.transformed(by: CGAffineTransform(scaleX: 0.08, y: 0.08))
        if let cg = ctx.createCGImage(t, from: t.extent) {
            DispatchQueue.main.async { self.thumb = UIImage(cgImage: cg) }
        }
    }

    private func appleSave(_ photo: AVCapturePhoto) {
        guard let d = photo.fileDataRepresentation() else { fail(); return }
        if let img = CIImage(data: d, options: [.applyOrientationProperty: true]) { setThumb(img) }
        let heic = output.availablePhotoCodecTypes.contains(.hevc)
        save(d, uti: heic ? "public.heic" : "public.jpeg")
    }

    private func waitSteady(_ go: @escaping () -> Void) {
        guard motion.isDeviceMotionAvailable else { go(); return }
        waiting = true
        var still = 0, ticks = 0
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
            guard let self = self, let dm = dm, self.waiting else { return }
            ticks += 1
            let r = dm.rotationRate, a = dm.userAcceleration
            let spin = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
            let shake = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            still = (spin < 0.08 && shake < 0.04) ? still + 1 : 0
            if still >= 8 || ticks > 150 {          // ~0.13 s of stillness, or give up after 2.5 s
                self.motion.stopDeviceMotionUpdates()
                self.waiting = false
                go()
            }
        }
    }

    private func orient(_ p: AVCapturePhoto) -> Int32 {
        (p.metadata[kCGImagePropertyOrientation as String] as? Int32) ?? 6
    }

    private func mirror(_ i: CIImage) -> CIImage {
        guard device?.position == .front, mirrorSelfie else { return i }
        return i.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: i.extent.width, y: 0))
    }

    // MARK: Portrait (depth-mask background blur, same code as the live preview)

    private func portrait(_ photo: AVCapturePhoto) {
        guard let data = photo.fileDataRepresentation(),
              let base = CIImage(data: data, options: [.applyOrientationProperty: true]) else { fail(); return }
        savePNG(mirror(base), thumbnail: false)   // keep the original
        guard let dd = photo.depthData else {
            DispatchQueue.main.async { self.note("No depth data") }
            return
        }
        let o = CGImagePropertyOrientation(rawValue: UInt32(orient(photo))) ?? .right
        let map = dd.applyingExifOrientation(o)
            .converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32).depthDataMap
        savePNG(mirror(portraitBlur(base, map, focus: lastFocusNorm)))
    }

    // Ask for the largest still size the active format supports (otherwise 60 fps formats default to ~2 MP)
    private func full(_ s: AVCapturePhotoSettings) {
        let md = output.maxPhotoDimensions
        if md.width > 0 && md.height > 0 { s.maxPhotoDimensions = md }
    }

    // Silence the system shutter where iOS allows it (looked up at runtime so older SDKs still build)
    private func quiet(_ s: AVCapturePhotoSettings) {
        guard output.responds(to: NSSelectorFromString("isShutterSoundSuppressionSupported")),
              (output.value(forKey: "shutterSoundSuppressionSupported") as? Bool) == true,
              s.responds(to: NSSelectorFromString("setShutterSoundSuppressionEnabled:")) else { return }
        s.setValue(true, forKey: "shutterSoundSuppressionEnabled")
    }

    // MARK: Night (multi-frame align + average + tone map)

    private func startNight() {
        busy = true; progress = 0
        Sounds.shared.nightStart()
        proc.async {
            self.nightAcc = nil; self.nightRef = nil; self.nightCount = 0
            self.nightGrab()
        }
    }

    private func nightGrab() {
        queue.async {
            self.setConnMirror(false)
            let s = AVCapturePhotoSettings(format: self.bgra)
            s.photoQualityPrioritization = .speed
            self.quiet(s)
            self.full(s)
            self.output.capturePhoto(with: s, delegate: self)
        }
    }

    private func flatten(_ i: CIImage, _ rect: CGRect) -> CIImage? {
        guard let cg = ctx.createCGImage(i, from: rect, format: .RGBAh, colorSpace: cs) else { return nil }
        return CIImage(cgImage: cg)
    }

    private func nightStep(_ photo: AVCapturePhoto, _ pb: CVPixelBuffer) {
        var f = CIImage(cvPixelBuffer: pb)
        if let ref = nightRef, let acc = nightAcc {
            let req = VNTranslationalImageRegistrationRequest(targetedCIImage: f, options: [:])
            if (try? VNSequenceRequestHandler().perform([req], on: ref)) != nil,
               let t = (req.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform {
                f = f.transformed(by: t)
            }
            let mix = CIFilter.dissolveTransition()
            mix.inputImage = acc
            mix.targetImage = f
            mix.time = Float(1.0 / Double(nightCount + 1))
            if let out = mix.outputImage, let flat = flatten(out, ref.extent) { nightAcc = flat }
        } else if let flat = flatten(f, f.extent) {
            nightRef = flat; nightAcc = flat; nightO = orient(photo)
        }
        nightCount += 1
        let p = Double(nightCount) / Double(nightFrames)
        DispatchQueue.main.async { self.progress = p }
        if nightCount < nightFrames { nightGrab() } else { nightFinish() }
    }

    private func nightFinish() {
        Sounds.shared.nightEnd()
        defer { DispatchQueue.main.async { self.busy = false; self.progress = 0 } }
        guard let acc = nightAcc, let ref = nightRef else { return }
        let r = ref.extent.insetBy(dx: ref.extent.width * 0.015, dy: ref.extent.height * 0.015)
        var img = acc.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))

        let nr = CIFilter.noiseReduction()
        nr.inputImage = img; nr.noiseLevel = 0.015; nr.sharpness = 0.5
        img = nr.outputImage ?? img
        let ex = CIFilter.exposureAdjust()
        ex.inputImage = img; ex.ev = 0.6
        img = ex.outputImage ?? img
        let hs = CIFilter.highlightShadowAdjust()
        hs.inputImage = img; hs.shadowAmount = 0.9; hs.highlightAmount = 0.9
        img = hs.outputImage ?? img
        let vb = CIFilter.vibrance()
        vb.inputImage = img; vb.amount = 0.25
        img = vb.outputImage ?? img

        savePNG(mirror(img.oriented(forExifOrientation: nightO)))
    }

    // MARK: Saving

    private func fail() {
        DispatchQueue.main.async { self.busy = false; self.note("Capture failed") }
    }

    private func note(_ t: String) {
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if self.toast == t { self.toast = "" } }
    }

    private func savePNG(_ img: CIImage, thumbnail: Bool = true) {
        guard let d = ctx.pngRepresentation(of: img, format: .RGBA8, colorSpace: cs) else { fail(); return }
        if thumbnail {
            let t = img.transformed(by: CGAffineTransform(scaleX: 0.08, y: 0.08))
            if let cg = ctx.createCGImage(t, from: t.extent) {
                DispatchQueue.main.async { self.thumb = UIImage(cgImage: cg) }
            }
        }
        save(d, uti: "public.png")
    }

    private func save(_ data: Data, uti: String) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                let opts = PHAssetResourceCreationOptions()
                opts.uniformTypeIdentifier = uti
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: opts)
            }) { ok, _ in
                DispatchQueue.main.async { self.note(ok ? "Saved" : "Save failed") }
            }
        }
    }
}

// MARK: Portrait blur + live preview

extension CameraModel: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let v = collection.synchronizedData(for: videoOut) as? AVCaptureSynchronizedSampleBufferData,
              !v.sampleBufferWasDropped,
              let pb = CMSampleBufferGetImageBuffer(v.sampleBuffer) else { return }
        var img = CIImage(cvPixelBuffer: pb)
        let s = 960.0 / img.extent.width
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        if let d = collection.synchronizedData(for: depthOut) as? AVCaptureSynchronizedDepthData, !d.depthDataWasDropped {
            let map = d.depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32).depthDataMap
            img = portraitBlur(img, map, focus: lastFocusNorm)
        }
        guard let cg = ctx.createCGImage(img, from: img.extent) else { return }
        DispatchQueue.main.async { self.liveLayer?.contents = cg }
    }

    // Mask: 0 where depth matches the focus point (sharp), 1 where it differs (blurred)
    fileprivate func blurMask(_ map: CVPixelBuffer, focus: CGPoint) -> (CIImage, CGSize)? {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        guard w > 1, h > 1, let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(map)
        func px(_ x: Int, _ y: Int) -> Float { base.advanced(by: y * bpr).assumingMemoryBound(to: Float32.self)[x] }

        let cx = Int(focus.x * CGFloat(w)), cy = Int(focus.y * CGFloat(h))
        var win: [Float] = []
        for dy in -4...4 {
            for dx in -4...4 {
                let v = px(min(max(cx + dx, 0), w - 1), min(max(cy + dy, 0), h - 1))
                if v.isFinite && v > 0 { win.append(v) }
            }
        }
        guard !win.isEmpty else { return nil }
        win.sort()
        let fd = win[win.count / 2]

        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = px(x, y)
                var m: Float = 0
                if v.isFinite {                       // 0 disparity = infinitely far = fully blurred
                    let rel = abs(v - fd) / max(fd, 0.15)
                    m = min(max((rel - 0.10) / 0.45, 0), 1)
                }
                let b = UInt8(m * 255), i = (y * w + x) * 4
                rgba[i] = b; rgba[i + 1] = b; rgba[i + 2] = b
            }
        }
        let ci = CIImage(bitmapData: Data(rgba), bytesPerRow: w * 4, size: CGSize(width: w, height: h),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (ci, CGSize(width: w, height: h))
    }

    fileprivate func portraitBlur(_ img: CIImage, _ map: CVPixelBuffer, focus: CGPoint) -> CIImage {
        guard let (mask, ms) = blurMask(map, focus: focus) else { return img }
        let e = img.extent
        let up = mask.transformed(by: CGAffineTransform(scaleX: e.width / ms.width, y: e.height / ms.height))
        let feather = CIFilter.gaussianBlur()
        feather.inputImage = up.clampedToExtent()
        feather.radius = Float(e.width * 0.004)
        let soft = (feather.outputImage ?? up).cropped(to: e)
        let vb = CIFilter.maskedVariableBlur()
        vb.inputImage = img.clampedToExtent()
        vb.mask = soft
        vb.radius = Float(e.width * blurFactor)
        return (vb.outputImage ?? img).cropped(to: e)
    }
}

// MARK: Sounds (generated in code: soft modern shutter, calm pad + chime for Low Light)

final class Sounds {
    static let shared = Sounds()
    private var click: AVAudioPlayer?
    private var soft: AVAudioPlayer?
    private var done: AVAudioPlayer?
    private let sr = 44100.0

    private init() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.ambient, options: [.mixWithOthers])   // follows the silent switch like the stock camera
        try? s.setActive(true)
        click = make(0.16) { t in
            let a = sin(2 * .pi * 1900 * t) * exp(-t * 75) * 0.30
            let b = sin(2 * .pi * 260 * t) * exp(-t * 38) * 0.45
            let n = Double.random(in: -1...1) * exp(-t * 260) * 0.15
            return a + b + n
        }
        soft = make(0.14) { t in
            sin(2 * .pi * 1500 * t) * exp(-t * 80) * 0.22 + sin(2 * .pi * 200 * t) * exp(-t * 45) * 0.30
        }
        done = make(0.45) { t in
            func tick(_ x: Double, _ f: Double) -> Double {
                guard x >= 0 else { return 0 }
                return sin(2 * .pi * f * x) * exp(-x * 70) * 0.26 + sin(2 * .pi * 210 * x) * exp(-x * 42) * 0.24
            }
            return tick(t, 1700) + tick(t - 0.17, 2250)
        }
    }

    private func make(_ dur: Double, _ f: (Double) -> Double) -> AVAudioPlayer? {
        let n = Int(dur * sr)
        var d = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func le16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); le32(UInt32(36 + n * 2)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); le32(16); le16(1); le16(1)
        le32(UInt32(sr)); le32(UInt32(sr) * 2); le16(2); le16(16)
        d.append("data".data(using: .ascii)!); le32(UInt32(n * 2))
        for i in 0..<n {
            let v = max(-1, min(1, f(Double(i) / sr)))
            le16(UInt16(bitPattern: Int16(v * 32000)))
        }
        let p = try? AVAudioPlayer(data: d)
        p?.prepareToPlay()
        return p
    }

    func shutter() { click?.currentTime = 0; click?.play() }
    func nightStart() { soft?.currentTime = 0; soft?.play() }          // one soft tick when capture begins
    func nightEnd() { done?.currentTime = 0; done?.play() }            // quick double tick when it's done
}
