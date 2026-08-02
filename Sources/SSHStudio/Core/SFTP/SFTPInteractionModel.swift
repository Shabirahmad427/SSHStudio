import Foundation

enum SFTPClipboardOperation: String, Codable, Equatable, Sendable {
    case copy
    case move
}

struct SFTPClipboardItem: Codable, Equatable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
}

struct SFTPClipboardPayload: Codable, Equatable, Sendable {
    let sourceProfileID: UUID
    let items: [SFTPClipboardItem]
    let operation: SFTPClipboardOperation
    let timestamp: Date

    var isEmpty: Bool { items.isEmpty }
}

enum SFTPSelectionEvent: Equatable, Sendable {
    case single(String)
    case command(String)
    case shift(String)
    case empty
    case preserve(availableIDs: [String])
}

struct SFTPSelectionReducer: Equatable, Sendable {
    private(set) var selectedIDs: Set<String> = []
    private(set) var anchorID: String?

    mutating func apply(_ event: SFTPSelectionEvent, orderedIDs: [String]) {
        switch event {
        case .single(let id):
            selectedIDs = [id]
            anchorID = id
        case .command(let id):
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
            anchorID = id
        case .shift(let id):
            let anchor = anchorID ?? id
            selectedIDs.formUnion(Self.range(from: anchor, to: id, orderedIDs: orderedIDs))
        case .empty:
            selectedIDs.removeAll()
            anchorID = nil
        case .preserve(let availableIDs):
            selectedIDs.formIntersection(Set(availableIDs))
            if let anchorID, !availableIDs.contains(anchorID) {
                self.anchorID = selectedIDs.first
            }
        }
    }

    static func range(from anchor: String, to id: String, orderedIDs: [String]) -> Set<String> {
        guard let start = orderedIDs.firstIndex(of: anchor),
              let end = orderedIDs.firstIndex(of: id)
        else { return [id] }
        let bounds = start <= end ? start...end : end...start
        return Set(orderedIDs[bounds])
    }
}

enum SFTPKeyboardCommand: Equatable, Sendable {
    case selectAll
    case copy
    case cut
    case paste
    case delete
    case rename
    case open
    case back
    case forward
    case parent
    case refresh
}

enum SFTPKeyboardRouter {
    static func command(
        key: String,
        modifiers: Set<String>,
        sftpHasFocus: Bool,
        terminalHasFocus: Bool
    ) -> SFTPKeyboardCommand? {
        guard sftpHasFocus, !terminalHasFocus else { return nil }
        let lower = key.lowercased()
        if modifiers == ["command"], lower == "a" { return .selectAll }
        if modifiers == ["command"], lower == "c" { return .copy }
        if modifiers == ["command"], lower == "x" { return .cut }
        if modifiers == ["command"], lower == "v" { return .paste }
        if modifiers == ["command"], lower == "o" { return .open }
        if modifiers == ["command"], lower == "[" { return .back }
        if modifiers == ["command"], lower == "]" { return .forward }
        if modifiers == ["command"], lower == "r" { return .refresh }
        if modifiers == ["command"], lower == "up" { return .parent }
        if modifiers.isEmpty, lower == "delete" { return .delete }
        if modifiers.isEmpty, lower == "return" { return .rename }
        return nil
    }
}

enum SFTPConflictPolicy {
    static func conflictingNames(sourceNames: [String], destinationNames: [String]) -> [String] {
        let destination = Set(destinationNames)
        return sourceNames.filter { destination.contains($0) }
    }
}

enum SFTPMutationBatchBuilder {
    static func renameCommands(
        items: [SFTPClipboardItem],
        destinationPath: String,
        overwrite: Bool
    ) throws -> [String] {
        try items.flatMap { item -> [String] in
            let targetPath = SFTPManager.childPath(parent: destinationPath, child: item.name)
            var commands: [String] = []
            if overwrite {
                commands.append("\(item.isDirectory ? "rm -r" : "rm") \(try sftpPath(targetPath))")
            }
            commands.append("rename \(try sftpPath(item.path)) \(try sftpPath(targetPath))")
            return commands
        }
    }

    static func sftpPath(_ value: String) throws -> String {
        _ = try SFTPPath(value)
        if value == "~" { return "." }
        if value.hasPrefix("~/") {
            return quote(String(value.dropFirst(2)))
        }
        return quote(value)
    }

    private static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
