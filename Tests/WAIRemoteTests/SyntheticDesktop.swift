import Accelerate
import AppKit
import CoreVideo
import WebRTC

/// A deterministic 3840x2160 desktop assembled from pre-rendered video-range
/// NV12 planes, like ScreenCaptureKit delivers, so any frame can be regenerated
/// exactly from its index. Each frame carries that index in large black and
/// white blocks that survive any H264 quantizer, identifying decoded frames
/// without RTP metadata.
final class SyntheticDesktop {
    static let width = 3840, height = 2160
    static let typingX = 760, typingY = 1928, typingRows = 56, advance = 22
    static let stampY = 2064, block = 48
    struct Planes { let y: [UInt8], uv: [UInt8], width: Int, height: Int }
    /// A window: fixed chrome around a viewport that scrolls a taller page.
    struct Window { let screen: Planes, content: Planes, x: Int, top: Int, rows: Int }
    struct State: Equatable { var window = 0, offsets = [0, 0], typed = 0 }
    static let typedText = Array("Проверка: напечатанный текст остаётся чётким — the quick brown fox jumps over the lazy dog 0123456789 (WAI Remote)")
    let windows: [Window]
    private let typedLine: Planes

    init() {
        let w = Self.width, h = Self.height
        let chat = Self.render(width: w, height: h) {
            Self.menuBar()
            Self.fill(0xF6F6F6, 0, 80, w, 120)
            for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() { Self.oval(color, 40 + i * 44, 126, 28) }
            Self.text("WAI Remote — обсуждение качества изображения", 1300, 116, 32, .semibold)
            Self.fill(0xEFEFF2, 0, 200, 600, 1864)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 0, y: 200, width: 590, height: 1640)).setClip()
            for i in 0..<13 {
                Self.oval(Self.hue(i), 40, 236 + i * 128, 64)
                Self.text(Self.names[i % Self.names.count], 124, 232 + i * 128, 30, .semibold)
                Self.text(Self.prose[(i * 5) % Self.prose.count], 124, 274 + i * 128, 24, color: 0x6E6E73)
            }
            NSGraphicsContext.restoreGraphicsState()
            Self.fill(0xDADADA, 600, 1840, w - 600, 2)
            NSColor(rgb: 0xC8C8C8).setStroke()
            let field = NSBezierPath(roundedRect: NSRect(x: 700, y: 1900, width: 3000, height: 112), xRadius: 24, yRadius: 24)
            field.lineWidth = 3; field.stroke()
            Self.statusBar("Ln 128, Col 42    UTF-8    Swift")
        }
        let chatPage = Self.render(width: w - 600, height: 1640 + 2880 + 64) {
            var y = 32, n = 0
            while y < 1640 + 2880 {
                Self.oval(Self.hue(n), 40, y, 64)
                Self.text(Self.names[n % Self.names.count], 130, y, 30, .semibold, color: Self.hue(n, brightness: 0.5))
                Self.text(String(format: "%d:%02d", 10 + n / 6, n * 7 % 60), 520, y + 4, 26, color: 0x8E8E93)
                y += 52
                let lines = 1 + n % 4
                if n % 3 == 1 {
                    Self.fill(0xF4F5F7, 120, y - 8, 2960, lines * 40 + 16)
                    for i in 0..<lines { Self.code(Self.code[(n + i) % Self.code.count], 150, y); y += 40 }
                } else {
                    for i in 0..<lines {
                        Self.text(Self.prose[(n * 3 + i) % Self.prose.count] + " " + Self.prose[(n * 5 + i + 3) % Self.prose.count], 130, y, 30); y += 42
                    }
                }
                y += 34; n += 1
            }
        }
        let browser = Self.render(width: w, height: h) {
            Self.menuBar()
            Self.fill(0xDFE1E5, 0, 80, w, 160)
            NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 60, y: 92, width: 900, height: 64), xRadius: 14, yRadius: 14).fill()
            Self.text("Отчёт о качестве — WAI", 100, 104, 28)
            NSColor(rgb: 0xF1F3F4).setFill(); NSBezierPath(roundedRect: NSRect(x: 300, y: 170, width: 3240, height: 56), xRadius: 28, yRadius: 28).fill()
            Self.text("waiwai.is/remote/quality-report", 340, 178, 30, color: 0x3C4043)
            Self.statusBar("waiwai.is    100%    Готово")
        }
        let document = Self.render(width: w, height: 1824 + 1440 + 64) {
            var y = 60, section = 0
            while y < 1824 + 1440 {
                Self.text("\(section + 1). " + Self.headings[section % Self.headings.count], 520, y, 64, .bold); y += 100
                let paragraph = (0..<5).map { Self.prose[(section * 4 + $0) % Self.prose.count] }.joined(separator: " ")
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor(rgb: 0x202124)]
                let height = Int((paragraph as NSString).boundingRect(with: NSSize(width: 2800, height: 2000), options: .usesLineFragmentOrigin, attributes: attributes).height)
                (paragraph as NSString).draw(with: NSRect(x: 520, y: y, width: 2800, height: height), options: .usesLineFragmentOrigin, attributes: attributes)
                y += height + 40
                if section.isMultiple(of: 2) {
                    Self.fill(0x9AA0A6, 520, y + 420, 2800, 3)
                    for bar in 0..<14 {
                        let value = 80 + (bar * 97 + section * 31) % 320
                        Self.fill(Self.hue(bar + section), 560 + bar * 196, y + 420 - value, 140, value)
                        Self.text("\(value)", 580 + bar * 196, y + 380 - value, 26, color: 0x5F6368)
                    }
                    y += 480
                } else {
                    for row in 0..<6 {
                        if row.isMultiple(of: 2) { Self.fill(0xF1F3F4, 520, y, 2800, 60) }
                        for column in 0..<4 {
                            Self.text(row == 0 ? Self.columns[column] : "\(row * 37 + column * 11 + section) мс", 560 + column * 700, y + 12, 30, row == 0 ? .semibold : .regular)
                        }
                        y += 60
                    }
                    y += 40
                }
                section += 1
            }
        }
        windows = [Window(screen: chat, content: chatPage, x: 600, top: 200, rows: 1640),
                   Window(screen: browser, content: document, x: 0, top: 240, rows: 1824)]
        typedLine = Self.render(width: w, height: Self.typingRows) {
            for (i, character) in Self.typedText.enumerated() {
                (String(character) as NSString).draw(at: NSPoint(x: Self.typingX + i * Self.advance, y: 8), withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 32, weight: .regular), .foregroundColor: NSColor(rgb: 0x1D1D1F)])
            }
        }
    }

    /// Writes one frame. `uv` is optional because a luma reference needs no chroma.
    func draw(_ state: State, index: Int, y: UnsafeMutablePointer<UInt8>, yStride: Int, uv: UnsafeMutablePointer<UInt8>?, uvStride: Int) {
        let window = windows[state.window], offset = state.offsets[state.window]
        Self.copy(window.screen.y, window.content.y, window.x, to: y, stride: yStride, rows: Self.height,
                  viewport: window.top..<(window.top + window.rows), offset: offset)
        if let uv {
            Self.copy(window.screen.uv, window.content.uv, window.x, to: uv, stride: uvStride, rows: Self.height / 2,
                      viewport: window.top / 2..<(window.top + window.rows) / 2, offset: offset / 2)
        }
        if state.window == 0 {
            let typed = min(state.typed, Self.typedText.count) * Self.advance
            typedLine.y.withUnsafeBufferPointer { line in
                for row in 0..<Self.typingRows {
                    memcpy(y + (Self.typingY + row) * yStride + Self.typingX, line.baseAddress! + row * Self.width + Self.typingX, typed)
                }
            }
            if let uv {
                typedLine.uv.withUnsafeBufferPointer { line in
                    for row in 0..<Self.typingRows / 2 {
                        memcpy(uv + (Self.typingY / 2 + row) * uvStride + Self.typingX, line.baseAddress! + row * Self.width + Self.typingX, typed)
                    }
                }
            }
            for row in (Self.typingY + 8)..<(Self.typingY + Self.typingRows - 8) { memset(y + row * yStride + Self.typingX + typed, 30, 4) }
        }
        Self.stamp(index, y: y, yStride: yStride, uv: uv, uvStride: uvStride)
    }
    func luma(_ state: State, index: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: Self.width * Self.height)
        pixels.withUnsafeMutableBufferPointer { draw(state, index: index, y: $0.baseAddress!, yStride: Self.width, uv: nil, uvStride: 0) }
        return pixels
    }
    func frame(_ state: State, index: Int, pool: CVPixelBufferPool? = nil) -> CVPixelBuffer? {
        guard let buffer = Self.buffer(pool: pool) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        draw(state, index: index, y: CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self),
             yStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
             uv: CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self),
             uvStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func pool() -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 8] as CFDictionary, attributes as CFDictionary, &pool)
        return pool
    }
    private static let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    static func buffer(pool: CVPixelBufferPool? = nil) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = pool.map { CVPixelBufferPoolCreatePixelBuffer(nil, $0, &buffer) }
            ?? CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }
        // ScreenCaptureKit tags its NV12 with the matrix the planes were converted with.
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    // MARK: Frame index

    private static func check(_ index: Int) -> Int { (index ^ index >> 8 ^ 0x5A) & 0xFF }
    /// 16 index bits and 8 check bits as 48 px blocks in the status bar's left corner.
    static func stamp(_ index: Int, y: UnsafeMutablePointer<UInt8>, yStride: Int, uv: UnsafeMutablePointer<UInt8>?, uvStride: Int) {
        let bits = index & 0xFFFF | check(index) << 16
        for bit in 0..<24 {
            let x = bit % 12 * block, top = stampY + bit / 12 * block
            for row in top..<(top + block) { memset(y + row * yStride + x, bits >> bit & 1 == 1 ? 235 : 16, block) }
            if let uv { for row in (top / 2)..<((top + block) / 2) { memset(uv + row * uvStride + x, 128, block) } }
        }
    }
    static func index(in buffer: RTCVideoFrameBuffer) -> Int? {
        if let native = buffer as? RTCCVPixelBuffer {
            let pixel = native.pixelBuffer
            guard CVPixelBufferGetHeightOfPlane(pixel, 0) == height else { return nil }
            CVPixelBufferLockBaseAddress(pixel, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            return index(CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self),
                         stride: CVPixelBufferGetBytesPerRowOfPlane(pixel, 0), fullRange: isFullRange(pixel))
        }
        let planar = buffer.toI420()
        return planar.height == Int32(height) ? index(planar.dataY, stride: Int(planar.strideY), fullRange: false) : nil
    }
    private static func index(_ y: UnsafePointer<UInt8>, stride: Int, fullRange: Bool) -> Int? {
        var bits = 0
        for bit in 0..<24 {
            let x = bit % 12 * block + block / 3, top = stampY + bit / 12 * block + block / 3
            var sum = 0
            for row in top..<(top + block / 3) { for column in x..<(x + block / 3) { sum += Int(y[row * stride + column]) } }
            if sum / (block / 3 * block / 3) > (fullRange ? 128 : 126) { bits |= 1 << bit }
        }
        return bits >> 16 == check(bits & 0xFFFF) ? bits & 0xFFFF : nil
    }

    // MARK: Range-correct luma PSNR

    private static func isFullRange(_ pixel: CVPixelBuffer) -> Bool {
        CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }
    /// Full-resolution luma of a decoded frame, and whether it is full range.
    static func luma(of buffer: RTCVideoFrameBuffer) -> (pixels: [UInt8], fullRange: Bool) {
        if let native = buffer as? RTCCVPixelBuffer {
            let pixel = native.pixelBuffer
            CVPixelBufferLockBaseAddress(pixel, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            let width = CVPixelBufferGetWidthOfPlane(pixel, 0), height = CVPixelBufferGetHeightOfPlane(pixel, 0)
            return (rows(CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self),
                         stride: CVPixelBufferGetBytesPerRowOfPlane(pixel, 0), width: width, height: height), isFullRange(pixel))
        }
        let planar = buffer.toI420()
        return (rows(planar.dataY, stride: Int(planar.strideY), width: Int(planar.width), height: Int(planar.height)), false)
    }
    private static func rows(_ base: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBufferPointer { out in for row in 0..<height { memcpy(out.baseAddress! + row * width, base + row * stride, width) } }
        return pixels
    }
    /// The reference is video range like ScreenCaptureKit. RTCVideoDecoderH264
    /// outputs full range, so expand the reference before comparing.
    static func psnr(reference: [UInt8], decoded: [UInt8], decodedFullRange: Bool) -> Double? {
        guard reference.count == decoded.count, !reference.isEmpty else { return nil }
        let chunk = 1 << 16
        let a = UnsafeMutablePointer<Float>.allocate(capacity: chunk), b = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        defer { a.deallocate(); b.deallocate() }
        var scale: Float = decodedFullRange ? 255.0 / 219 : 1, shift: Float = decodedFullRange ? -16 * 255.0 / 219 : 0
        var sum = 0.0
        reference.withUnsafeBufferPointer { r in
            decoded.withUnsafeBufferPointer { d in
                var start = 0
                while start < r.count {
                    let count = vDSP_Length(min(chunk, r.count - start))
                    vDSP_vfltu8(r.baseAddress! + start, 1, a, 1, count)
                    vDSP_vsmsa(a, 1, &scale, &shift, a, 1, count)
                    vDSP_vfltu8(d.baseAddress! + start, 1, b, 1, count)
                    var distance: Float = 0
                    vDSP_distancesq(a, 1, b, 1, &distance, count)
                    sum += Double(distance); start += Int(count)
                }
            }
        }
        let mse = sum / Double(reference.count)
        return mse < 1e-6 ? 99 : 10 * log10(255 * 255 / mse)
    }

    // MARK: Rendering

    private static func copy(_ screen: [UInt8], _ content: [UInt8], _ x: Int, to destination: UnsafeMutablePointer<UInt8>,
                             stride: Int, rows: Int, viewport: Range<Int>, offset: Int) {
        let span = width - x
        screen.withUnsafeBufferPointer { s in
            content.withUnsafeBufferPointer { c in
                for row in 0..<rows {
                    let out = destination + row * stride
                    guard viewport.contains(row) else { memcpy(out, s.baseAddress! + row * width, width); continue }
                    if x > 0 { memcpy(out, s.baseAddress! + row * width, x) }
                    memcpy(out + x, c.baseAddress! + (row - viewport.lowerBound + offset) * span, span)
                }
            }
        }
    }
    private static func render(width: Int, height: Int, _ draw: () -> Void) -> Planes {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        fill(0xFFFFFF, 0, 0, width, height)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        var info = vImage_ARGBToYpCbCr()
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &range, &info,
                                                       kvImageARGB8888, kvImage420Yp8_CbCr8, vImage_Flags(kvImageNoFlags))
        var y = [UInt8](repeating: 0, count: width * height), uv = [UInt8](repeating: 128, count: width * height / 2)
        var source = vImage_Buffer(data: context.data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        y.withUnsafeMutableBytes { luma in
            uv.withUnsafeMutableBytes { chroma in
                var lumaBuffer = vImage_Buffer(data: luma.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var chromaBuffer = vImage_Buffer(data: chroma.baseAddress, height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2), rowBytes: width)
                _ = vImageConvert_ARGB8888To420Yp8_CbCr8(&source, &lumaBuffer, &chromaBuffer, &info, [0, 1, 2, 3], vImage_Flags(kvImageNoFlags))
            }
        }
        return Planes(y: y, uv: uv, width: width, height: height)
    }
    private static func fill(_ color: Int, _ x: Int, _ y: Int, _ width: Int, _ height: Int) { fill(NSColor(rgb: color), x, y, width, height) }
    private static func fill(_ color: NSColor, _ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        color.setFill(); NSRect(x: x, y: y, width: width, height: height).fill()
    }
    private static func oval(_ color: Int, _ x: Int, _ y: Int, _ size: Int) { oval(NSColor(rgb: color), x, y, size) }
    private static func oval(_ color: NSColor, _ x: Int, _ y: Int, _ size: Int) {
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).fill()
    }
    private static func hue(_ n: Int, brightness: CGFloat = 0.85) -> NSColor {
        NSColor(hue: CGFloat(n * 37 % 360) / 360, saturation: 0.6, brightness: brightness, alpha: 1)
    }
    private static func text(_ string: String, _ x: Int, _ y: Int, _ size: CGFloat, _ weight: NSFont.Weight = .regular, color: Int = 0x1D1D1F) {
        text(string, x, y, size, weight, color: NSColor(rgb: color))
    }
    private static func text(_ string: String, _ x: Int, _ y: Int, _ size: CGFloat, _ weight: NSFont.Weight = .regular, color: NSColor) {
        (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
    private static func code(_ line: String, _ x: Int, _ y: Int) {
        let text = NSMutableAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 28, weight: .regular),
                                                                       .foregroundColor: NSColor(rgb: 0x1D1D1F)])
        for (pattern, color) in [("\\b(func|let|var|guard|return|try|else|if|for|in|self)\\b", 0xAD3DA4), ("\"[^\"]*\"", 0xC41A16),
                                 ("\\b[0-9_]+\\b", 0x1C00CF), ("//.*$", 0x267507)] {
            for match in try! NSRegularExpression(pattern: pattern).matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                text.addAttribute(.foregroundColor, value: NSColor(rgb: color), range: match.range)
            }
        }
        text.draw(at: NSPoint(x: x, y: y))
    }
    private static func menuBar() {
        fill(0xEDEDED, 0, 0, width, 80)
        for (i, item) in ["WAI Remote", "Файл", "Правка", "Вид", "Окно", "Справка"].enumerated() {
            text(item, 120 + i * 220, 20, 30, i == 0 ? .bold : .regular)
        }
        text("Пн 26 окт. 10:42", 3420, 20, 30)
    }
    private static func statusBar(_ status: String) {
        fill(0xE3E3E3, 0, stampY, width, height - stampY)
        text(status, 2600, stampY + 30, 28, color: 0x48484A)
        text("Подключено · 3840×2160 · H.264", 700, stampY + 30, 28, color: 0x48484A)
    }
    private static let names = ["Мик", "Анна", "Mark", "Сергей", "Ольга", "Dmitry", "Ирина"]
    private static let headings = ["Чёткость текста при прокрутке", "Задержка ввода и отклик", "Пропускная способность канала", "Ключевые кадры и восстановление"]
    private static let columns = ["Маршрут", "RTT p50", "RTT p90", "Кадры"]
    private static let prose = [
        "Текст на удалённом экране должен оставаться чётким при любой нагрузке на сеть.",
        "Давай сравним с AnyDesk на тех же машинах, в той же сети и на том же контенте.",
        "The final frame of every scroll must arrive, and static text should sharpen within a second.",
        "Клик должен попадать туда, где пользователь видел кнопку, а не туда, где она была раньше.",
        "Bitrate collapses when the estimate reads tunnel jitter as congestion; the floor keeps detail.",
        "Проверим ключевые кадры: раз в 240 секунд весь экран перерисовывается с крупными блоками.",
        "Typing produces tiny updates; each one should reach the viewer in well under a hundred milliseconds.",
        "Переключение окна меняет весь экран сразу — это самый тяжёлый кадр для кодировщика.",
    ]
    private static let code = [
        "func encode(_ frame: CVPixelBuffer, at time: CMTime) throws -> Data {",
        "    let target = controller.bitrate(for: link.estimate, floor: 3_000_000)",
        "    guard session.isReady else { return Data() } // ждём готовности",
        "    return try session.encode(frame, time: time, bitrate: target)",
        "for (index, frame) in frames.enumerated() { send(frame, sequence: index + 1) }",
        "let message = \"Изображение обновлено\" // 3840×2160 at 60 fps",
    ]
}

enum Bench {
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        return sorted.isEmpty ? nil : sorted[Int((p * Double(sorted.count - 1)).rounded())]
    }
    static func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
    /// JSONSerialization prints a Double with 17 digits; a decimal keeps the line compact.
    static func round(_ value: Double?, _ digits: Int = 2) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        return NSDecimalNumber(string: String(format: "%.\(digits)f", value))
    }
    static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

private extension NSColor {
    convenience init(rgb: Int) {
        self.init(srgbRed: CGFloat(rgb >> 16 & 255) / 255, green: CGFloat(rgb >> 8 & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
