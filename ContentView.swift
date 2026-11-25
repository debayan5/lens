import SwiftUI
import AVFoundation

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var pv: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct Preview: UIViewRepresentable {
    let model: CameraModel
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.pv.session = model.session
        v.pv.videoGravity = .resizeAspectFill
        model.previewLayer = v.pv
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var m = CameraModel()
    @State private var baseZoom: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Preview(model: m)
                .ignoresSafeArea()
                .onTapGesture(count: 2) { m.flip() }
                .onTapGesture { m.focus(at: $0) }
                .gesture(MagnificationGesture()
                    .onChanged { m.setZoom(baseZoom * $0) }
                    .onEnded { _ in baseZoom = m.zoom })

            if let p = m.focusPoint {
                Rectangle().stroke(Color.yellow, lineWidth: 1.5)
                    .frame(width: 72, height: 72).position(p).allowsHitTesting(false)
            }

            VStack {
                topBar
                Spacer()
                if m.manual { manualPanel }
                lensChips
                bottomBar
            }
            .padding(.horizontal, 20).padding(.bottom, 12)

            if !m.status.isEmpty {
                Text(m.status).padding(10).background(.ultraThinMaterial).cornerRadius(10)
            }
        }
        .onAppear { m.start() }
    }

    var topBar: some View {
        HStack(spacing: 14) {
            pill(m.rawMode ? "RAW" : "PNG", on: m.rawMode) { m.rawMode.toggle() }
            pill("M", on: m.manual) { m.manual.toggle() }
            if m.isFront { pill("Mirror", on: m.mirrorSelfie) { m.mirrorSelfie.toggle() } }
            Spacer()
        }.padding(.top, 8)
    }

    var manualPanel: some View {
        VStack(spacing: 6) {
            Text("ISO \(Int(m.iso))   1/\(Int(m.shutterDen))s").font(.caption.monospacedDigit())
            Slider(value: Binding(get: { Double(m.iso) }, set: { m.iso = Float($0) }), in: 25...3200)
            Slider(value: $m.shutterDen, in: 2...2000)
        }
        .padding(12).background(.ultraThinMaterial).cornerRadius(14)
    }

    var lensChips: some View {
        HStack(spacing: 10) {
            if !m.isFront {
                ForEach(m.backLenses, id: \.uniqueID) { d in
                    let on = d.uniqueID == m.current?.uniqueID
                    Button(String(format: "%g×", m.factor(d))) { m.select(d) }
                        .font(.footnote.bold())
                        .foregroundColor(on ? .yellow : .white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }
            }
        }.padding(.bottom, 10)
    }

    var bottomBar: some View {
        HStack {
            Color.clear.frame(width: 56, height: 56)
            Spacer()
            Button { m.capture() } label: {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                    .overlay(Circle().fill(.white).padding(7))
            }
            Spacer()
            Button { m.flip() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.title2).frame(width: 56, height: 56)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
        }
    }

    func pill(_ t: String, on: Bool, _ a: @escaping () -> Void) -> some View {
        Button(t, action: a).font(.footnote.bold())
            .foregroundColor(on ? .black : .white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(on ? Color.yellow : Color.black.opacity(0.5)))
    }
}
