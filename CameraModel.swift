import AVFoundation
import Photos
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import UIKit
import CoreMotion

enum CamMode: String, CaseIterable { case photo = "PHOTO", portrait = "PORTRAIT", night = "LOW LIGHT" }

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
    private var lastFocusNorm = CGPoint(x: 0.5, y: 0.5)

    var isFront: Bool { current?.position == .front }

    // MARK: Setup

    func start() {
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
        case .builtInUltraWideCamera: return 0.5
        case .builtInTelephotoCamera: return 2
        default: return 1
        }
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
        let fast = !rawMode && mode != .portrait      // 60 fps viewfinder when possible
        let bias: Float = rawMode ? -1.0 : 0          // protect highlights in RAW
        queue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            self.session.inputs.forEach { self.session.removeInput($0) }
            if let input = try? AVCaptureDeviceInput(device: d), self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            if self.session.outputs.isEmpty, self.session.canAddOutput(self.output) {
                self.session.addOutput(self.output)
            }
            self.session.commitConfiguration()
            self.output.isDepthDataDeliveryEnabled = self.output.isDepthDataDeliverySupported
            self.device = d
            self.output.maxPhotoQualityPrioritization = .quality
            try? d.lockForConfiguration()
            let fpsNow = fast ? self.use60(d) : 30
            if d.activeFormat.isVideoHDRSupported {
                d.automaticallyAdjustsVideoHDREnabled = false
                d.isVideoHDREnabled = false
            }
            d.videoZoomFactor = min(max(z, d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)
            d.setExposureTargetBias(min(max(bias, d.minExposureTargetBias), d.maxExposureTargetBias))
            d.unlockForConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async {
                self.previewLayer?.session = self.session
                self.depthOK = self.output.isDepthDataDeliverySupported
                self.fps = fpsNow
            }
        }
    }

    private func use60(_ d: AVCaptureDevice) -> Int {
        let cands = d.formats.filter { f in
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(dim.width) * 3 == Int(dim.height) * 4 && dim.width >= 1440
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

    // MARK: Controls

    func setZoom(_ z: CGFloat) {
        queue.async {
            guard let d = self.device else { return }
            let v = min(max(z, d.minAvailableVideoZoomFactor), min(d.maxAvailableVideoZoomFactor, 10))
            try? d.lockForConfiguration()
            d.videoZoomFactor = v
            d.unlockForConfiguration()
            DispatchQueue.main.async { self.zoom = v }
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
        if waiting { motion.stopDeviceMotionUpdates(); waiting = false; return }   // tap again to cancel
        guard !busy else { return }
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

        let shoot = {
            self.queue.async {
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
                } else {
                    s = AVCapturePhotoSettings(format: self.bgra)
                    s.photoQualityPrioritization = .speed
                    if m == .photo, !screen, self.output.supportedFlashModes.contains(fl) { s.flashMode = fl }
                }
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

    // MARK: Portrait (Apple's native depth blur)

    private func portrait(_ photo: AVCapturePhoto) {
        guard let data = photo.fileDataRepresentation(),
              let base = CIImage(data: data, options: [.applyOrientationProperty: true]) else { fail(); return }
        savePNG(mirror(base), thumbnail: false)   // keep the original
        guard let disp = CIImage(data: data, options: [.auxiliaryDisparity: true, .applyOrientationProperty: true]),
              let f = CIFilter(name: "CIDepthBlurEffect") else {
            DispatchQueue.main.async { self.note("No depth data") }
            return
        }
        let e = base.extent
        let s = e.width * 0.2
        let fx = lastFocusNorm.x * e.width, fy = (1 - lastFocusNorm.y) * e.height
        f.setValue(base, forKey: kCIInputImageKey)
        f.setValue(disp, forKey: "inputDisparityImage")
        f.setValue(aperture, forKey: "inputAperture")
        f.setValue(CIVector(x: fx - s / 2, y: fy - s / 2, z: s, w: s), forKey: "inputFocusRect")
        if let out = f.outputImage {
            savePNG(mirror(out.cropped(to: e)))
        } else {
            DispatchQueue.main.async { self.note("Blur failed") }
        }
    }

    // MARK: Night (multi-frame align + average + tone map)

    private func startNight() {
        busy = true; progress = 0
        proc.async {
            self.nightAcc = nil; self.nightRef = nil; self.nightCount = 0
            self.nightGrab()
        }
    }

    private func nightGrab() {
        queue.async {
            let s = AVCapturePhotoSettings(format: self.bgra)
            s.photoQualityPrioritization = .speed
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
