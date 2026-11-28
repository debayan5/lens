import SwiftUI
import AVFoundation
import AVKit

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var pv: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    let live = CALayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        live.contentsGravity = .resizeAspectFill
        live.masksToBounds = true
        live.isHidden = true
        layer.addSublayer(live)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); live.frame = bounds }
}

struct Preview: UIViewRepresentable {
    @ObservedObject var model: CameraModel
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.backgroundColor = .black
        v.pv.session = model.session
        v.pv.videoGravity = .resizeAspectFill
        model.previewLayer = v.pv
        model.liveLayer = v.live
        if #available(iOS 17.2, *) {          // volume buttons (and Camera Control) take the photo
            let m = model
            let i = AVCaptureEventInteraction { [weak m] event in
                if event.phase == .ended { m?.buttonCapture() }
            }
            v.addInteraction(i)
        }
        return v
    }
    func updateUIView(_ v: PreviewUIView, context: Context) {
        if v.pv.session == nil { v.pv.session = model.session }
        v.live.isHidden = !model.portraitLive
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct ContentView: View {
    @StateObject private var m = CameraModel()
    @State private var baseZoom: CGFloat = 1
    @State private var pinching = false
    @State private var flipAngle = 0.0
    @State private var flipCover = 0.0
    private let accent = Color(red: 1.0, green: 0.8, blue: 0.0)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar.frame(height: 56)
                viewfinder
                Spacer(minLength: 0)
                if m.mode == .portrait { blurSlider.padding(.horizontal, 28).padding(.bottom, 12) }
                modeSelector.padding(.bottom, 16)
                bottomBar.padding(.bottom, 20)
            }
            if m.screenFlash {
                Color(red: 1, green: 0.97, blue: 0.92).ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .buttonStyle(PressStyle())      // flat buttons: stops iOS adding its own big circle behind them
        .onAppear { m.start() }
        .statusBarHidden()
        .sheet(isPresented: Binding(get: { m.whatsNew != nil }, set: { if !$0 { m.dismissWhatsNew() } })) { whatsNewSheet }
    }

    // MARK: Viewfinder

    var viewfinder: some View {
        ZStack {
            Preview(model: m)
                .rotation3DEffect(.degrees(flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .onTapGesture(count: 2) { animatedFlip() }
                .onTapGesture { m.focus(at: $0) }
                .gesture(MagnificationGesture()
                    .onChanged { s in
                        if !pinching { pinching = true; baseZoom = m.zoom }
                        m.setZoom(baseZoom * s)
                    }
                    .onEnded { _ in pinching = false })

            Rectangle().fill(.regularMaterial).opacity(flipCover).allowsHitTesting(false)
            if let p = m.focusPoint {
                Rectangle().stroke(accent, lineWidth: 1.5)
                    .frame(width: 74, height: 74).position(p).allowsHitTesting(false)
            }
            if m.countdown > 0 {
                Text("\(m.countdown)")
                    .font(.system(size: 110, weight: .thin))
                    .foregroundColor(.white).shadow(radius: 8)
                    .allowsHitTesting(false)
            }
            VStack {
                if !m.toast.isEmpty { badge(m.toast).padding(.top, 10) }
                if m.showZoom { badge(String(format: "%.1f×", m.displayZoom)).padding(.top, 10) }
                Spacer()
                if m.busy && m.mode == .night { badge("Hold still…").padding(.bottom, 8) }
                if m.waiting { badge("Hold steady… tap to cancel").padding(.bottom, 8) }
                if m.mode == .portrait && !m.depthOK { badge("No depth on \(m.current?.localizedName ?? "this lens")").padding(.bottom, 8) }
                lensChips.padding(.bottom, 10)
            }
        }
        .background(Color.black)
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func badge(_ t: String) -> some View {
        Text(t).font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    var lensChips: some View {
        HStack(spacing: 8) {
            if !m.isFront && m.mode != .portrait {
                let z = m.displayZoom
                let near = m.nearestStop(z)
                ForEach(m.zoomStops, id: \.self) { stop in
                    let on = stop == near
                    Button { m.goZoom(stop) } label: {
                        Text(chipLabel(stop, z, on))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(on ? accent : .white)
                            .fixedSize()
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                }
            }
        }
    }

    func chipLabel(_ stop: Double, _ z: Double, _ on: Bool) -> String {
        guard on else { return fmt(stop) }
        return (abs(z - stop) < 0.05 ? fmt(stop) : String(format: "%.1f", z)) + "×"
    }

    func fmt(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v) }

    // MARK: Bars

    var topBar: some View {
        HStack(spacing: 8) {
            if m.mode != .night && (m.isFront || m.mode == .photo) {
                Button { m.cycleFlash() } label: {
                    Image(systemName: flashIcon).font(.system(size: 18, weight: .semibold))
                        .foregroundColor(m.flash == .off ? .white : accent)
                }
            }
            Button { m.cycleTimer() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "timer").font(.system(size: 18, weight: .semibold))
                    if m.timer > 0 { Text("\(m.timer)s").font(.system(size: 12, weight: .bold)) }
                }
                .foregroundColor(m.timer > 0 ? accent : .white)
                .padding(.leading, 6)
            }
            if m.mode == .night { Image(systemName: "moon.fill").foregroundColor(accent) }
            Spacer()
            if m.isFront {
                pill("Mirror", on: m.mirrorSelfie) { m.mirrorSelfie.toggle() }
            }
            if m.mode == .photo {
                pill(m.rawMode ? "RAW" : (m.appleProc ? "HEIC" : "PNG"), on: m.rawMode) { m.toggleRaw() }
                pill("APPLE", on: m.appleProc) { m.toggleApple() }
            }
            pill("STEADY", on: m.steady) { m.steady.toggle() }
        }
        .padding(.horizontal, 20)
    }

    var flashIcon: String {
        switch m.flash {
        case .off: return "bolt.slash.fill"
        case .auto: return "bolt.badge.automatic.fill"
        default: return "bolt.fill"
        }
    }

    func pill(_ t: String, on: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 11, weight: .bold))
                .foregroundColor(on ? .black : .white)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Capsule().fill(on ? accent : Color.white.opacity(0.18)))
        }
    }

    var whatsNewSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("What's new").font(.title2.bold())
                Spacer()
                Text("v" + (m.whatsNew?.version ?? "")).font(.subheadline.monospaced()).foregroundColor(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array((m.whatsNew?.changes ?? []).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•").foregroundColor(accent)
                            Text(line).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            Button {
                if let u = URL(string: "https://raw.githubusercontent.com/debayan5/lens/main/changelog.json") {
                    UIApplication.shared.open(u)
                }
            } label: {
                HStack { Text("Full changelog"); Spacer(); Image(systemName: "chevron.right") }
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1)))
            }
            Button { m.dismissWhatsNew() } label: {
                Text("Continue").font(.headline).foregroundColor(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(accent))
            }
        }
        .padding(20)
        .presentationDetents([.medium, .large])
    }

    func animatedFlip() {
        guard !m.busy, m.countdown == 0 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeIn(duration: 0.2)) { flipAngle = 90; flipCover = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            m.flip()
            flipAngle = -90
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeOut(duration: 0.3)) { flipAngle = 0; flipCover = 0 }
            }
        }
    }

    var blurSlider: some View {
        HStack(spacing: 10) {
            Text("LOW").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.7))
            Slider(value: $m.blurLevel, in: 0...1).tint(accent)
            Text("HIGH").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.7))
        }
    }

    var modeSelector: some View {
        HStack(spacing: 26) {
            ForEach(CamMode.allCases, id: \.self) { mode in
                Button { withAnimation(.easeInOut(duration: 0.2)) { m.setMode(mode) } } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 13, weight: .semibold)).kerning(0.8)
                        .foregroundColor(m.mode == mode ? accent : .white.opacity(0.7))
                }
            }
        }
    }

    var bottomBar: some View {
        HStack {
            Button {
                if let u = URL(string: "photos-redirect://") { UIApplication.shared.open(u) }
            } label: {
                Group {
                    if let t = m.thumb {
                        Image(uiImage: t).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle").foregroundColor(.white.opacity(0.6))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Spacer()
            Button { m.capture() } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                    Circle().fill(Color.white).frame(width: 64, height: 64).opacity(m.busy ? 0.35 : 1)
                    if m.busy {
                        Circle().trim(from: 0, to: m.progress)
                            .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: 78, height: 78)
                    }
                }
            }
            .buttonStyle(PressStyle())
            Spacer()
            Button { animatedFlip() } label: {
                Image(systemName: "camera.rotate.fill")
                    .font(.system(size: 28)).foregroundColor(.white)
                    .frame(width: 54, height: 54)
            }
        }
        .padding(.horizontal, 28)
    }
}
