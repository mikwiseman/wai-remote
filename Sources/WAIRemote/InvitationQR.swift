import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision
import UniformTypeIdentifiers
import RemoteCore

enum InvitationQRCode {
    static func image(for text: String) -> CGImage? {
        guard let invitation = try? RemoteInvite(text) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(invitation.invitationURL.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        // Four white modules keep the code readable against any app background.
        let bounds = code.extent.insetBy(dx: -4, dy: -4)
        let background = CIImage(color: .white).cropped(to: bounds)
        let image = code.composited(over: background).transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        return CIContext().createCGImage(image, from: image.extent)
    }

    static func invitation(in image: CGImage) throws -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap { result in
            result.payloadStringValue.flatMap { try? RemoteInvite($0).invitationURL.absoluteString }
        }.first
    }
}

struct InvitationCodeView: View {
    let invitation: String
    var body: some View {
        if let image = InvitationQRCode.image(for: invitation) {
            Image(decorative: image, scale: 1).resizable().interpolation(.none)
                .aspectRatio(contentMode: .fit).frame(width: 224, height: 224)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("QR-код для подключения к этому Mac")
                .accessibilityIdentifier("invitationQRCode")
        }
    }
}

private final class InvitationCamera: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    @Published var message = "Наведите камеру на QR-код в WAI Remote."
    @Published var ready = false
    var onInvitation: ((String) -> Void)?
    private let queue = DispatchQueue(label: "is.wai.remote.qr-camera", qos: .userInitiated)
    private var configured = false // Accessed only on the camera queue.
    private var active = false
    private var delivered = false
    private var generation = UUID()

    func start() {
        guard !active, !delivered else { return }
        active = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    if allowed { self.configureAndStart() }
                    else { self.message = "Для сканирования разрешите камеру в настройках или откройте изображение QR-кода." }
                }
            }
        default: message = "Для сканирования разрешите камеру в настройках или откройте изображение QR-кода."
        }
    }

    private func configureAndStart() {
        queue.async { [self] in
            do {
                if !configured {
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                            ?? AVCaptureDevice.default(for: .video) else { throw ScanError.camera }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureMetadataOutput()
                    session.beginConfiguration()
                    defer { session.commitConfiguration() }
                    session.sessionPreset = .high
                    guard session.canAddInput(input), session.canAddOutput(output) else { throw ScanError.camera }
                    session.addInput(input); session.addOutput(output)
                    guard output.availableMetadataObjectTypes.contains(.qr) else {
                        session.removeInput(input); session.removeOutput(output)
                        throw ScanError.camera
                    }
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    output.metadataObjectTypes = [.qr]
                    configured = true
                }
                session.startRunning()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active else { return }
                    self.ready = true; self.message = "Наведите камеру на QR-код в WAI Remote."
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active else { return }
                    self.message = "Камера недоступна. Откройте изображение с QR-кодом."
                }
            }
        }
    }

    func stop() {
        active = false; ready = false; generation = UUID()
        queue.async { [session] in session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard active, !delivered else { return }
        for case let code as AVMetadataMachineReadableCodeObject in metadataObjects {
            if let value = code.stringValue { accept(value) }
        }
    }

    private func accept(_ text: String) {
        guard !delivered else { return }
        guard let invitation = try? RemoteInvite(text) else {
            message = "Это не приглашение WAI Remote. Наведите камеру на другой QR-код."; return
        }
        delivered = true; stop()
        onInvitation?(invitation.invitationURL.absoluteString)
    }

    func readImage(_ url: URL) {
        let token = generation
        message = "Читаем QR-код…"
        queue.async { [weak self] in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let result: String?
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 20_000_000,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2400
                      ] as CFDictionary) else { throw ScanError.image }
                result = try InvitationQRCode.invitation(in: image)
            } catch { result = nil }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if let result { self.accept(result) }
                else { self.message = "На изображении нет приглашения WAI Remote. Выберите другое изображение." }
            }
        }
    }
    private enum ScanError: Error { case camera, image }
}

struct InvitationScanner: View {
    let onInvitation: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = InvitationCamera()
    @State private var importing = false

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Подключиться по QR-коду").font(.title2.weight(.semibold))
                Spacer()
                Button("Закрыть") { dismiss() }.accessibilityIdentifier("closeQRScanner")
            }
            ZStack {
                CameraPreview(session: camera.session)
                if !camera.ready { Image(systemName: "qrcode.viewfinder").font(.system(size: 64, weight: .light)).foregroundStyle(.white) }
            }.frame(maxWidth: .infinity).frame(height: 280).background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityHidden(true)
            Text(camera.message).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("qrScannerStatus")
            Button { camera.stop(); importing = true } label: {
                Label("Открыть изображение QR-кода", systemImage: "photo")
            }.accessibilityIdentifier("openQRImage")
            Text("Новое устройство подключится после разрешения владельца Mac.")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: 520)
        #if os(macOS)
        .frame(width: 520)
        #endif
        .onAppear { camera.onInvitation = { value in dismiss(); onInvitation(value) }; camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !importing { camera.start() } else { camera.stop() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): camera.readImage(url)
            case .failure: camera.start()
            }
        }
    }
}

#if os(macOS)
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> Preview { Preview(session: session) }
    func updateNSView(_ view: Preview, context: Context) {}
    final class Preview: NSView {
        private let preview: AVCaptureVideoPreviewLayer
        init(session: AVCaptureSession) {
            preview = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero); wantsLayer = true
            preview.videoGravity = .resizeAspectFill; layer?.addSublayer(preview)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func layout() { super.layout(); preview.frame = bounds }
    }
}
#else
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> Preview {
        let view = Preview(); view.preview.session = session; view.preview.videoGravity = .resizeAspectFill; return view
    }
    func updateUIView(_ view: Preview, context: Context) {}
    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
#endif
