import AVFoundation
import Photos
import CoreImage
import UIKit

final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "lens.session")
    private let ctx = CIContext()
    private var device: AVCaptureDevice?
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    @Published var backLenses: [AVCaptureDevice] = []
    @Published var current: AVCaptureDevice?
    @Published var rawMode = false
    @Published var mirrorSelfie = true
    @Published var manual = false { didSet { applyExposure() } }
    @Published var iso: Float = 100 { didSet { applyExposure() } }
    @Published var shutterDen: Double = 120 { didSet { applyExposure() } }
    @Published var zoom: CGFloat = 1
    @Published var focusPoint: CGPoint?
    @Published var status = ""

    var isFront: Bool { current?.position == .front }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return }
            let found = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                mediaType: .video, position: .back).devices
            let sorted = found.sorted { self.factor($0) < self.factor($1) }
            DispatchQueue.main.async {
                self.backLenses = sorted
                if let wide = sorted.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? sorted.first {
                    self.select(wide)
                }
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

    func select(_ d: AVCaptureDevice) {
        current = d
        zoom = 1
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
            self.device = d
            try? d.lockForConfiguration()
            // No automatic video HDR on the preview/stream
            if d.activeFormat.isVideoHDRSupported {
                d.automaticallyAdjustsVideoHDREnabled = false
                d.isVideoHDREnabled = false
            }
            d.videoZoomFactor = 1
            d.unlockForConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.applyExposure() }
        }
    }

    func flip() {
        if isFront {
            if let wide = backLenses.first(where: { $0.deviceType == .builtInWideAngleCamera }) { select(wide) }
        } else if let f = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            select(f)
        }
    }

    func applyExposure() {
        let manual = self.manual, iso = self.iso, den = self.shutterDen
        queue.async {
            guard let d = self.device else { return }
            try? d.lockForConfiguration()
            defer { d.unlockForConfiguration() }
            if manual {
                let f = d.activeFormat
                let i = min(max(iso, f.minISO), f.maxISO)
                let secs = min(max(1.0 / den, f.minExposureDuration.seconds), f.maxExposureDuration.seconds)
                d.setExposureModeCustom(duration: CMTimeMakeWithSeconds(secs, preferredTimescale: 1_000_000), iso: i)
            } else if d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposureMode = .continuousAutoExposure
            }
        }
    }

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.focusPoint = nil }
        queue.async {
            guard let d = self.device else { return }
            try? d.lockForConfiguration()
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = dp; d.focusMode = .autoFocus }
            if !self.manual, d.isExposurePointOfInterestSupported {
                d.exposurePointOfInterest = dp; d.exposureMode = .autoExpose
            }
            d.unlockForConfiguration()
        }
    }

    // MARK: Capture

    func capture() {
        let wantRaw = rawMode
        queue.async {
            let s: AVCapturePhotoSettings
            if wantRaw, let raw = self.output.availableRawPhotoPixelFormatTypes
                .first(where: { !AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                s = AVCapturePhotoSettings(rawPixelFormatType: raw)
            } else {
                // Uncompressed pixels -> true lossless PNG, minimal Apple processing
                s = AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                s.photoQualityPrioritization = .speed
            }
            self.output.capturePhoto(with: s, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else { return }
        if photo.isRawPhoto {
            if let d = photo.fileDataRepresentation() { save(d, uti: "com.adobe.raw-image") }
            return
        }
        guard let pb = photo.pixelBuffer else { return }
        let o = (photo.metadata[kCGImagePropertyOrientation as String] as? Int32) ?? 6
        var img = CIImage(cvPixelBuffer: pb).oriented(forExifOrientation: o)
        if device?.position == .front && mirrorSelfie {
            let w = img.extent.width
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                     .transformed(by: CGAffineTransform(translationX: w, y: 0))
        }
        let cs = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        if let png = ctx.pngRepresentation(of: img, format: .RGBA8, colorSpace: cs) {
            save(png, uti: "public.png")
        }
    }

    private func save(_ data: Data, uti: String) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                let opts = PHAssetResourceCreationOptions()
                opts.uniformTypeIdentifier = uti
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: opts)
            }) { ok, _ in
                DispatchQueue.main.async {
                    self.status = ok ? "Saved" : "Save failed"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.status = "" }
                }
            }
        }
    }
}
