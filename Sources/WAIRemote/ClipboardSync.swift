import AppKit

/// One authenticated connection. Bulk data never enters the input channel.
final class ClipboardSync {
    struct Packet: Codable {
        var type: String
        var id: String? = nil
        var revision: UInt64? = nil
        var size: Int? = nil
        var offset: Int? = nil
        var data: Data? = nil
        var windowBytes: Int? = nil
    }
    private struct Outgoing {
        var id: String; var data: Data; var offset = 0; var started = false
        var change: Int; var completion: (() -> Void)?
        var acknowledged = 0
    }
    private struct Incoming { var id: String; var size: Int; var data = Data(); var change: Int }
    static let label = "clipboard-v1"
    static let chunkSize = 10 * 1024
    static let messageLimit = 16 * 1024
    private static let receiveWindow = 2 * chunkSize
    private static let encodedLimit = ClipboardContent.byteLimit + 2 * 1024 * 1024
    var send: ((Data) -> Bool)?
    /// Only an explicit Paste can interrupt the user. Automatic copies stay quiet.
    var onPasteFailure: ((String) -> Void)?
    private(set) var available = false
    private let board: NSPasteboard
    private let directory: URL
    private let readSnapshot: (NSPasteboard, Int) throws -> ClipboardContent.Snapshot?
    private let worker = DispatchQueue(label: "is.wai.remote.clipboard", qos: .utility)
    private var enabled = false, open = false, helloSent = false
    private var timer: Timer?
    private var observedChange = 0
    private var deliveredChange: Int?
    private var revision: UInt64 = 0
    private var latestID = ""
    private var generation = UUID()
    private var outgoing: Outgoing?
    private var pumpScheduled = false
    private var preparingPaste = false
    private var incoming: Incoming?
    private var pendingAck: String?
    private var pendingProgress: Packet?
    private var peerWindow = 0
    private var lastPoll = 0.0, lastHello = 0.0, lastProgress = 0.0

    init(pasteboard: NSPasteboard = .general, directory: URL? = nil,
         readSnapshot: @escaping (NSPasteboard, Int) throws -> ClipboardContent.Snapshot? = {
             try ClipboardContent.snapshot(from: $0, expectedChange: $1)
         }) {
        board = pasteboard
        self.readSnapshot = readSnapshot
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("is.wai.remote/Clipboard", isDirectory: true)
    }
    deinit { timer?.invalidate() }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        if !value { _ = transmit(Packet(type: "pause")) }
        enabled = value; reset()
        if enabled && open { start() }
    }
    func setOpen(_ value: Bool) {
        guard open != value else { return }
        open = value; reset()
        if enabled && open { start() }
    }
    func close() { enabled = false; open = false; reset(); send = nil }
    private func reset() {
        PerformanceLog.record("clipboard-state", ["enabled": enabled, "open": open])
        generation = UUID(); timer?.invalidate(); timer = nil
        incoming = nil; outgoing = nil; pendingAck = nil; pendingProgress = nil; peerWindow = 0
        preparingPaste = false
        available = false; helloSent = false; deliveredChange = nil
        observedChange = board.changeCount
    }
    private func start() {
        // Do not export the clipboard that predates the connection.
        observedChange = board.changeCount
        timer = Timer.connectionTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }
    @discardableResult private func transmit(_ packet: Packet) -> Bool {
        let encoder = JSONEncoder()
        // Base64 may consist entirely of slashes. Escaping them can make a
        // 10 KiB chunk exceed our 16 KiB wire limit despite available credit.
        encoder.outputFormatting = .withoutEscapingSlashes
        guard open, let data = try? encoder.encode(packet), data.count <= Self.messageLimit else { return false }
        return send?(data) == true
    }
    func tick() {
        guard enabled && open else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !available, now - lastHello > 1 {
            helloSent = transmit(Packet(type: "hello", windowBytes: Self.receiveWindow)); lastHello = now
        }
        guard available else { return }
        if now - lastPoll >= 0.25 { lastPoll = now; poll() }
        if let id = pendingAck, transmit(Packet(type: "ack", id: id)) { pendingAck = nil }
        if let progress = pendingProgress, transmit(progress) { pendingProgress = nil }
        if outgoing != nil || incoming != nil, now - lastProgress > 30 {
            PerformanceLog.record("clipboard", ["operation": "timeout", "id": outgoing?.id ?? incoming?.id ?? "",
                "sentBytes": outgoing?.offset ?? 0, "receivedBytes": incoming?.data.count ?? 0])
            let explicitPaste = outgoing?.completion != nil
            generation = UUID(); outgoing = nil; incoming = nil
            preparingPaste = false
            if explicitPaste { onPasteFailure?("Не удалось передать содержимое. Скопируйте его и повторите вставку.") }
        }
        pump()
    }
    func poll() {
        guard available, enabled, open, board.changeCount != observedChange else { return }
        guard !preparingPaste, outgoing?.completion == nil else { return }
        // Another WAI session or Universal Clipboard may have delivered this copy.
        if ClipboardContent.isReceived(board) { observedChange = board.changeCount; return }
        pushCurrent()
    }
    func pushCurrent(completion: (() -> Void)? = nil) {
        guard available, enabled, open else { return }
        if deliveredChange == board.changeCount { completion?(); return }
        if outgoing?.change == board.changeCount {
            if completion != nil { outgoing?.completion = completion }; return
        }
        generation = UUID(); let token = generation
        let change = board.changeCount; observedChange = change
        incoming = nil; outgoing = nil; pendingAck = nil; pendingProgress = nil
        guard revision < UInt64.max else { return }
        revision += 1; latestID = UUID().uuidString
        let id = latestID
        preparingPaste = completion != nil
        worker.async { [weak self] in
            guard let self else { return }
            let result = Result { () throws -> Data? in
                let content = try self.readSnapshot(self.board, change).map(ClipboardContent.read)
                guard let content else { return nil }
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                let data = try encoder.encode(content)
                guard data.count <= Self.encodedLimit else { throw ClipboardContent.Failure.tooLarge }
                return data
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.enabled, self.available, self.generation == token else { return }
                self.preparingPaste = false
                guard completion != nil || self.board.changeCount == change else { self.poll(); return }
                switch result {
                case .success(let data):
                    guard let data else {
                        if completion != nil { self.onPasteFailure?("Это содержимое нельзя вставить на другой Mac.") }
                        return
                    }
                    self.outgoing = Outgoing(id: id, data: data, change: change, completion: completion)
                    self.lastProgress = ProcessInfo.processInfo.systemUptime; self.pump()
                case .failure(let error):
                    if completion != nil { self.onPasteFailure?(ClipboardContent.pasteFailureDescription(error)) }
                }
            }
        }
    }
    func pump() {
        guard enabled, open, available, var transfer = outgoing else { return }
        if !transfer.started {
            guard transmit(Packet(type: "begin", id: transfer.id, revision: revision, size: transfer.data.count)) else { return }
            transfer.started = true
            PerformanceLog.record("clipboard", ["operation": "send", "id": transfer.id, "bytes": transfer.data.count])
        }
        // bufferedAmount can drain into SCTP much faster than the network.
        // Receiver credit bounds unacknowledged bulk data across that queue too.
        let limit = peerWindow > 0 ? min(transfer.data.count, transfer.acknowledged + peerWindow) : transfer.data.count
        var sent = 0
        for _ in 0..<2 where transfer.offset < limit {
            let end = min(transfer.offset + Self.chunkSize, limit)
            guard transmit(Packet(type: "chunk", id: transfer.id, offset: transfer.offset,
                                  data: transfer.data.subdata(in: transfer.offset..<end))) else { break }
            transfer.offset = end; lastProgress = ProcessInfo.processInfo.systemUptime
            sent += 1
        }
        outgoing = transfer
        // An immediately writable channel may never report a buffer decrease.
        // Continue after yielding to input instead of waiting for the 250-ms poll.
        if sent == 2, transfer.offset < limit, !pumpScheduled {
            pumpScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pumpScheduled = false; self.pump()
            }
        }
    }
    func receive(_ data: Data) {
        guard enabled, open, data.count <= Self.messageLimit,
              let packet = try? JSONDecoder().decode(Packet.self, from: data) else { return }
        if packet.type == "hello" {
            let firstHello = !available
            peerWindow = (packet.windowBytes ?? 0) >= Self.chunkSize ? min(packet.windowBytes!, Self.receiveWindow) : 0
            available = true
            PerformanceLog.record("clipboard-state", ["ready": true, "peerWindow": peerWindow])
            // A successful channel send may have reached the peer before it
            // enabled clipboard access. Confirm its first hello once more.
            if firstHello || !helloSent { helloSent = transmit(Packet(type: "hello", windowBytes: Self.receiveWindow)) }
            return
        }
        if packet.type == "pause" { reset(); if enabled && open { start() }; return }
        guard available, let id = packet.id, UUID(uuidString: id) != nil else { return }
        switch packet.type {
        case "begin":
            guard !preparingPaste, outgoing?.completion == nil else { return }
            guard let next = packet.revision, let size = packet.size, (1...Self.encodedLimit).contains(size),
                  next > revision || next == revision && id > latestID else { return }
            // A local copy always gets a new logical revision, even if its poll is pending.
            if board.changeCount != observedChange {
                if ClipboardContent.isReceived(board) { observedChange = board.changeCount }
                else { revision = max(revision, next); pushCurrent(); return }
            }
            revision = next; latestID = id; generation = UUID(); outgoing = nil
            incoming = Incoming(id: id, size: size, change: board.changeCount)
            PerformanceLog.record("clipboard", ["operation": "receive-start", "id": id, "bytes": size])
            lastProgress = ProcessInfo.processInfo.systemUptime
        case "chunk":
            guard var transfer = incoming, transfer.id == id, packet.offset == transfer.data.count,
                  let chunk = packet.data, !chunk.isEmpty, chunk.count <= Self.chunkSize,
                  chunk.count <= transfer.size - transfer.data.count else { return }
            transfer.data.append(chunk); incoming = transfer
            lastProgress = ProcessInfo.processInfo.systemUptime
            if peerWindow > 0 {
                let progress = Packet(type: "progress", id: id, offset: transfer.data.count)
                pendingProgress = transmit(progress) ? nil : progress
            }
            if transfer.data.count == transfer.size { incoming = nil; finish(transfer) }
        case "progress":
            guard peerWindow > 0, var transfer = outgoing, transfer.id == id,
                  let offset = packet.offset, offset > transfer.acknowledged, offset <= transfer.offset else { return }
            transfer.acknowledged = offset; outgoing = transfer
            lastProgress = ProcessInfo.processInfo.systemUptime; pump()
        case "ack":
            guard let transfer = outgoing, transfer.id == id, transfer.offset == transfer.data.count else { return }
            PerformanceLog.record("clipboard", ["operation": "ack", "id": id, "bytes": transfer.data.count])
            outgoing = nil; deliveredChange = transfer.change
            transfer.completion?()
        default: break
        }
    }
    private func finish(_ transfer: Incoming) {
        let token = generation, root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        worker.async { [weak self] in
            guard let self else { return }
            let result = Result { try PropertyListDecoder().decode(ClipboardContent.self, from: transfer.data).objects(directory: root, markReceived: true) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.enabled, self.available, self.generation == token,
                      self.board.changeCount == transfer.change else {
                    PerformanceLog.record("clipboard", ["operation": "superseded", "id": transfer.id])
                    try? FileManager.default.removeItem(at: root); return
                }
                switch result {
                case .success(let objects):
                    guard !objects.isEmpty else { return }
                    // This copy has already crossed devices. Do not send it again
                    // through Universal Clipboard; the next ordinary Copy resets this.
                    self.board.prepareForNewContents(with: .currentHostOnly)
                    if self.board.writeObjects(objects) {
                        PerformanceLog.record("clipboard", ["operation": "receive", "id": transfer.id, "bytes": transfer.data.count])
                        self.observedChange = self.board.changeCount; self.deliveredChange = self.observedChange
                        self.pendingAck = transfer.id; self.tick()
                        self.worker.async { Self.trimCache(self.directory, keeping: root) }
                    } else {
                        PerformanceLog.record("clipboard", ["operation": "write-failed", "id": transfer.id])
                    }
                case .failure(let error):
                    PerformanceLog.record("clipboard", ["operation": "decode-failed", "id": transfer.id,
                        "domain": (error as NSError).domain, "code": (error as NSError).code])
                    try? FileManager.default.removeItem(at: root)
                }
            }
        }
    }

    /// Received files are temporary pasteboard backing, bounded to three transfers.
    static func trimCache(_ directory: URL, keeping current: URL) {
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]) else { return }
        let roots = children.compactMap { url -> (URL, Date)? in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return (url, values.creationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        var retained = 0
        for (url, _) in roots {
            if url.lastPathComponent == current.lastPathComponent { continue }
            if retained < 2 { retained += 1 } else { try? manager.removeItem(at: url) }
        }
    }
}
