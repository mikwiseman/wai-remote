import AppKit

/// Portable representations, never remote file URLs or archived Objective-C objects.
struct ClipboardContent: Codable {
    struct Representation: Codable { var type: String; var data: Data }
    struct File: Codable { var path: [String]; var data: Data? }
    struct Item: Codable { var representations: [Representation]; var files: [File]? }
    var items: [Item]
    static let byteLimit = 100 * 1024 * 1024
    static let entryLimit = 2048
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let received = NSPasteboard.PasteboardType("is.wai.remote.clipboard-origin")
    static let handoff = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
    static func isReceived(_ board: NSPasteboard) -> Bool {
        (board.types ?? []).contains { $0 == received || $0 == handoff }
    }
    /// Dictation apps temporarily conceal text to keep it out of clipboard
    /// history. An explicit Paste inserts that text through the input channel,
    /// without exporting it to the remote clipboard or a clipboard cache.
    static func textForExplicitInsertion(from board: NSPasteboard) -> String? {
        guard (board.types ?? []).contains(concealed) else { return nil }
        return board.string(forType: .string)
    }
    struct Snapshot {
        struct Item { var representations: [Representation]; var file: URL? }
        var items: [Item]
    }
    enum Failure: LocalizedError {
        case tooLarge, unsupportedFile, invalid, changed
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Буфер больше 100 МБ или содержит слишком много файлов."
            case .unsupportedFile: "Ссылки на файлы и специальные файлы не передаются. Скопируйте сам файл."
            case .invalid: "Не удалось прочитать буфер обмена."
            case .changed: "Содержимое буфера изменилось. Повторите вставку."
            }
        }
    }

    static func pasteFailureDescription(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.localizedDescription }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFileReadNoPermissionError {
            return "Нет доступа к скопированному файлу. Разрешите WAI Remote доступ к его папке в настройках macOS и повторите вставку."
        }
        return "Не удалось прочитать содержимое буфера обмена. Скопируйте его и повторите вставку."
    }

    static func read(from board: NSPasteboard) throws -> Self? {
        try snapshot(from: board).flatMap(read)
    }

    /// Lazy representations can wait on another process. Read them off the UI
    /// thread and reject a replaced owner rather than combining different copies.
    static func snapshot(from board: NSPasteboard, expectedChange: Int? = nil) throws -> Snapshot? {
        let change = expectedChange ?? board.changeCount
        guard board.changeCount == change else { throw Failure.changed }
        guard !(board.types ?? []).contains(concealed),
              let source = board.pasteboardItems, !source.isEmpty else { return nil }
        guard source.count <= 256 else { throw Failure.tooLarge }
        // Let AppKit carry the copied file's access grant with its native URL.
        // Rebuilding a URL from the text representation loses that context.
        let fileURLs = source.contains(where: { $0.types.contains(.fileURL) })
            ? (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []) : []
        var items: [Snapshot.Item] = [], bytes = 0
        for item in source {
            if let value = item.string(forType: .fileURL), let reference = URL(string: value), reference.isFileURL {
                guard let url = fileURLs.first(where: { $0 == reference }) else { throw Failure.invalid }
                items.append(.init(representations: [], file: url)); continue
            }
            let types = item.types.filter { !$0.rawValue.hasPrefix("org.nspasteboard.") &&
                !$0.rawValue.hasPrefix("com.apple.pasteboard.") && $0.rawValue != "NSFilenamesPboardType" && $0 != received && $0 != handoff }
            guard types.count <= 64 else { throw Failure.tooLarge }
            var representations: [Representation] = []
            for type in types {
                if let data = item.data(forType: type) {
                    guard data.count <= byteLimit - bytes else { throw Failure.tooLarge }; bytes += data.count
                    representations.append(.init(type: type.rawValue, data: data))
                }
            }
            if !representations.isEmpty { items.append(.init(representations: representations, file: nil)) }
        }
        guard board.changeCount == change else { throw Failure.changed }
        return items.isEmpty ? nil : Snapshot(items: items)
    }

    static func read(_ snapshot: Snapshot) throws -> Self {
        var items: [Item] = [], bytes = 0, entries = 0
        func account(_ count: Int) throws {
            guard count <= byteLimit - bytes else { throw Failure.tooLarge }; bytes += count
        }
        func file(_ url: URL, path: [String]) throws -> File {
            entries += 1
            guard entries <= entryLimit else { throw Failure.tooLarge }
            let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard resource.isSymbolicLink != true else { throw Failure.unsupportedFile }
            if resource.isDirectory == true { return File(path: path, data: nil) }
            guard resource.isRegularFile == true else { throw Failure.unsupportedFile }
            try account(resource.fileSize ?? byteLimit + 1)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count == resource.fileSize else { throw Failure.invalid }
            return File(path: path, data: data)
        }
        for item in snapshot.items {
            if let url = item.file {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let top = try file(url, path: [url.lastPathComponent])
                var files = [top]
                if top.data == nil {
                    let root = url.resolvingSymlinksInPath()
                    var enumerationError: Error?
                    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                        errorHandler: { _, error in enumerationError = error; return false }) else { throw Failure.invalid }
                    for case let child as URL in enumerator {
                        let relative = Array(child.pathComponents.suffix(enumerator.level))
                        files.append(try file(child, path: [url.lastPathComponent] + relative))
                    }
                    if let enumerationError { throw enumerationError }
                }
                items.append(Item(representations: [], files: files))
            } else {
                for representation in item.representations { try account(representation.data.count) }
                items.append(Item(representations: item.representations, files: nil))
            }
        }
        let content = Self(items: items)
        try content.validate()
        return content
    }

    func validate() throws {
        guard items.count <= 256 else { throw Failure.tooLarge }
        var bytes = 0, entries = 0
        for item in items {
            guard item.representations.count <= 64 else { throw Failure.tooLarge }
            for representation in item.representations {
                guard !representation.type.isEmpty, representation.type.utf8.count <= 256,
                      !representation.type.contains("\0"), representation.type != NSPasteboard.PasteboardType.fileURL.rawValue,
                      representation.type != "NSFilenamesPboardType",
                      representation.type != Self.received.rawValue,
                      !representation.type.hasPrefix("com.apple.pasteboard."),
                      !representation.type.hasPrefix("org.nspasteboard.") else { throw Failure.invalid }
                guard representation.data.count <= Self.byteLimit - bytes else { throw Failure.tooLarge }; bytes += representation.data.count
            }
            if let files = item.files {
                guard item.representations.isEmpty, let first = files.first, first.path.count == 1 else { throw Failure.invalid }
                var seen = Set<[String]>()
                for file in files {
                    entries += 1
                    guard entries <= Self.entryLimit else { throw Failure.tooLarge }
                    guard !file.path.isEmpty, file.path.count <= 64, file.path.first == first.path.first,
                          file.path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                              !$0.contains("/") && !$0.contains(":") && !$0.contains("\0") && $0.utf8.count <= 255 }),
                          seen.insert(file.path).inserted else { throw Failure.invalid }
                    let count = file.data?.count ?? 0
                    guard count <= Self.byteLimit - bytes else { throw Failure.tooLarge }; bytes += count
                }
            }
        }
    }

    func write(to board: NSPasteboard, directory: URL) throws {
        let objects = try objects(directory: directory)
        guard !objects.isEmpty else { return }
        board.clearContents()
        guard board.writeObjects(objects) else { throw Failure.invalid }
    }

    func objects(directory: URL, markReceived: Bool = false) throws -> [NSPasteboardWriting] {
        try validate()
        var objects: [NSPasteboardWriting] = []
        for (index, item) in items.enumerated() {
            if let files = item.files, let first = files.first {
                let root = directory.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for file in files {
                    let url = file.path.reduce(root) { $0.appendingPathComponent($1) }
                    if let data = file.data {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: url, options: .withoutOverwriting)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                }
                let output = NSPasteboardItem()
                output.setString(root.appendingPathComponent(first.path[0]).absoluteString, forType: .fileURL)
                if markReceived { output.setData(Data(), forType: Self.received) }
                objects.append(output)
            } else {
                let output = NSPasteboardItem()
                for representation in item.representations { output.setData(representation.data, forType: .init(representation.type)) }
                if markReceived { output.setData(Data(), forType: Self.received) }
                if !output.types.isEmpty { objects.append(output) }
            }
        }
        return objects
    }
}
