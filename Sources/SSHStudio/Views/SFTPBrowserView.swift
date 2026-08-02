import SwiftUI
import UniformTypeIdentifiers

private let filePayloadPasteboardType = NSPasteboard.PasteboardType("com.sshstudio.file-payloads")

// MARK: - Main SFTP Browser

struct SFTPBrowserView: View {
    let session: Session
    let allSessions: [Session]
    let isActive: Bool
    @ObservedObject var sftp: SFTPManager
    @StateObject private var leftRemoteSFTP = SFTPManager()
    @State private var localFiles: [LocalFile] = []
    @ObservedObject var localHistory: NavigationHistory<URL>
    private var localPath: URL { localHistory.current }
    @State private var dropTargetSide: DropSide? = nil
    @State private var leftEndpoint: TransferEndpoint
    @State private var rightEndpoint: TransferEndpoint

    enum DropSide { case left, right }
    enum PaneSide { case left, right }

    enum TransferEndpoint: Hashable {
        case local
        case remote(UUID)

        var id: String {
            switch self {
            case .local: return "local"
            case .remote(let id): return id.uuidString
            }
        }
    }

    init(session: Session, sftp: SFTPManager, localHistory: NavigationHistory<URL>, allSessions: [Session], isActive: Bool) {
        self.session = session
        self.allSessions = allSessions
        self.isActive = isActive
        self.sftp = sftp
        self.localHistory = localHistory
        _leftEndpoint = State(initialValue: .local)
        _rightEndpoint = State(initialValue: .remote(session.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let dividerWidth: CGFloat = 1
                let paneWidth = max(280, (geometry.size.width - dividerWidth) / 2)
                HStack(spacing: 0) {
                    pane(for: leftEndpoint, side: .left)
                        .frame(width: paneWidth, height: geometry.size.height)
                        .clipped()

                    Divider()
                        .frame(width: dividerWidth)

                    pane(for: rightEndpoint, side: .right)
                        .frame(width: paneWidth, height: geometry.size.height)
                        .clipped()
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            }
        }
        .onAppear {
            loadLocalFiles()
            if isActive {
                connectVisibleRemotePanes()
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                connectVisibleRemotePanes()
            }
        }
        .onChange(of: leftEndpoint) { _, _ in
            if isActive {
                connectVisibleRemotePanes()
            }
        }
        .onChange(of: rightEndpoint) { _, _ in
            if isActive {
                connectVisibleRemotePanes()
            }
        }
        .background {
            StudioBackdrop()
        }
    }

    private func endpointPicker(_ label: String, selection: Binding<TransferEndpoint>) -> some View {
        Menu {
            Button {
                selection.wrappedValue = .local
            } label: {
                Label("Local", systemImage: "desktopcomputer")
            }

            ForEach(availableSessions) { item in
                Button {
                    selection.wrappedValue = .remote(item.id)
                } label: {
                    Label(item.name, systemImage: "server.rack")
                }
            }
        } label: {
            Text(endpointTitle(for: selection.wrappedValue))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help(label)
    }

    private func endpointTitle(for endpoint: TransferEndpoint) -> String {
        switch endpoint {
        case .local:
            return "Local"
        case .remote(let id):
            return availableSessions.first(where: { $0.id == id })?.name ?? "Missing"
        }
    }

    private var availableSessions: [Session] {
        if allSessions.contains(where: { $0.id == session.id }) {
            return allSessions
        }
        return [session] + allSessions
    }

    @ViewBuilder
    private func pane(for endpoint: TransferEndpoint, side: PaneSide) -> some View {
        switch endpoint {
        case .local:
            localPane(side: side)
        case .remote(let id):
            if let remoteSession = availableSessions.first(where: { $0.id == id }) {
                remotePane(session: remoteSession, manager: manager(for: side), side: side)
            } else {
                ContentUnavailableView("Missing Session", systemImage: "server.rack")
            }
        }
    }

    private func manager(for side: PaneSide) -> SFTPManager {
        side == .left ? leftRemoteSFTP : sftp
    }

    @ViewBuilder
    private func localPane(side: PaneSide) -> some View {
        LocalPaneView(
            currentPath: localPath,
            endpointPicker: AnyView(endpointPicker(side == .left ? "Left Endpoint" : "Right Endpoint",
                                                   selection: side == .left ? $leftEndpoint : $rightEndpoint)),
            files: $localFiles,
            canGoBack: localHistory.canGoBack,
            canGoForward: localHistory.canGoForward,
            isDropTarget: dropTargetSide == dropSide(for: side),
            onNavigate: { url in
                localHistory.navigate(to: url)
                loadLocalFiles()
            },
            onBack: {
                localHistory.goBack()
                loadLocalFiles()
            },
            onForward: {
                localHistory.goForward()
                loadLocalFiles()
            },
            onUpload: { urls in
                sendLocalFiles(urls, from: side)
            },
            onDownload: { payloads in
                receiveRemotePayloads(payloads, to: side)
            },
            onDropEnter: { dropTargetSide = dropSide(for: side) },
            onDropExit: { dropTargetSide = nil },
            onRefresh: { loadLocalFiles() }
        )
    }

    @ViewBuilder
    private func remotePane(session remoteSession: Session, manager: SFTPManager, side: PaneSide) -> some View {
        RemotePaneView(
            sftp: manager,
            session: remoteSession,
            endpointPicker: AnyView(endpointPicker(side == .left ? "Left Endpoint" : "Right Endpoint",
                                                   selection: side == .left ? $leftEndpoint : $rightEndpoint)),
            isDropTarget: dropTargetSide == dropSide(for: side),
            onDownload: { file in
                sendRemoteFile(file, from: side)
            },
            onDownloadMany: { files in
                sendRemoteFiles(files, from: side)
            },
            onDrop: { payloads in
                receivePayloads(payloads, to: side)
            },
            onDropEnter: { dropTargetSide = dropSide(for: side) },
            onDropExit: { dropTargetSide = nil }
        )
    }

    private func connectVisibleRemotePanes() {
        if case .remote(let id) = leftEndpoint,
           let selected = availableSessions.first(where: { $0.id == id }) {
            leftRemoteSFTP.connect(to: selected)
        }
        if case .remote(let id) = rightEndpoint,
           let selected = availableSessions.first(where: { $0.id == id }) {
            sftp.connect(to: selected)
        }
    }

    private func dropSide(for side: PaneSide) -> DropSide {
        side == .left ? .left : .right
    }

    private func oppositeEndpoint(for side: PaneSide) -> TransferEndpoint {
        side == .left ? rightEndpoint : leftEndpoint
    }

    private func selectedSession(for endpoint: TransferEndpoint) -> Session? {
        guard case .remote(let id) = endpoint else { return nil }
        return availableSessions.first(where: { $0.id == id })
    }

    private func sendLocalFiles(_ urls: [URL], from side: PaneSide) {
        guard case .remote = oppositeEndpoint(for: side),
              let destinationSession = selectedSession(for: oppositeEndpoint(for: side))
        else { return }
        let destinationManager = manager(for: side == .left ? .right : .left)
        for url in urls {
            destinationManager.upload(localURL: url, session: destinationSession) {
                destinationManager.listFiles(at: destinationManager.currentPath, pushHistory: false)
            }
        }
    }

    private func sendRemoteFile(_ file: RemoteFile, from side: PaneSide) {
        sendRemoteFiles([file], from: side)
    }

    private func sendRemoteFiles(_ files: [RemoteFile], from side: PaneSide) {
        let sourceManager = manager(for: side)
        guard let sourceSession = selectedSession(for: side == .left ? leftEndpoint : rightEndpoint) else { return }
        let payloads = files.map {
            FileDragPayload.remote($0, currentPath: sourceManager.currentPath, sessionID: sourceSession.id)
        }
        receivePayloads(payloads, to: side == .left ? .right : .left)
    }

    private func receivePayloads(_ payloads: [FileDragPayload], to side: PaneSide) {
        let localURLs = payloads
            .filter { $0.origin == .local }
            .map { URL(fileURLWithPath: $0.path) }
        if !localURLs.isEmpty {
            sendLocalFiles(localURLs, from: side == .left ? .right : .left)
        }

        let remotePayloads = payloads.filter { $0.origin == .remote }
        if !remotePayloads.isEmpty {
            receiveRemotePayloads(remotePayloads, to: side)
        }
    }

    private func receiveRemotePayloads(_ payloads: [FileDragPayload], to side: PaneSide) {
        switch side == .left ? leftEndpoint : rightEndpoint {
        case .local:
            let grouped = Dictionary(grouping: payloads) { $0.sessionID }
            for (_, group) in grouped {
                guard let first = group.first,
                      let sourceSession = sessionForPayload(first)
                else { continue }
                let sourceManager = managerForPayload(first, fallbackSide: side == .left ? .right : .left)
                sourceManager.downloadBatch(
                    remoteItems: group.map {
                        (remotePath: $0.path, name: $0.name, isDirectory: $0.isDirectory)
                    },
                    to: localHistory.current,
                    session: sourceSession
                ) {
                    loadLocalFiles()
                }
            }
        case .remote:
            guard let destinationSession = selectedSession(for: side == .left ? leftEndpoint : rightEndpoint) else { return }
            let destinationManager = manager(for: side)
            for payload in payloads {
                guard let sourceSession = sessionForPayload(payload) else { continue }
                destinationManager.copyRemoteToRemote(
                    remotePath: payload.path,
                    name: payload.name,
                    isDirectory: payload.isDirectory,
                    sourceSession: sourceSession,
                    destinationSession: destinationSession,
                    destinationPath: destinationManager.currentPath
                ) { succeeded in
                    if succeeded {
                        destinationManager.listFiles(at: destinationManager.currentPath, pushHistory: false)
                    }
                }
            }
        }
    }

    private func sessionForPayload(_ payload: FileDragPayload) -> Session? {
        guard let sessionID = payload.sessionID else { return nil }
        return availableSessions.first(where: { $0.id == sessionID })
    }

    private func managerForPayload(_ payload: FileDragPayload, fallbackSide: PaneSide) -> SFTPManager {
        guard let sessionID = payload.sessionID else { return manager(for: fallbackSide) }
        if case .remote(let id) = leftEndpoint, id == sessionID { return leftRemoteSFTP }
        if case .remote(let id) = rightEndpoint, id == sessionID { return sftp }
        return manager(for: fallbackSide)
    }

    private func loadLocalFiles() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: localHistory.current,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        localFiles = contents.map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = values?.isDirectory ?? false
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate
            return LocalFile(url: url, isDirectory: isDir, size: size, modified: modified)
        }.sorted { $0.isDirectory && !$1.isDirectory }
    }
}

// MARK: - Local File Model

struct LocalFile: Identifiable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    let size: Int
    let modified: Date?
    var name: String { url.lastPathComponent }
    var sizeString: String {
        isDirectory ? "Folder" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
    var modifiedString: String {
        modified?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date"
    }
}

struct FileDragPayload: Codable {
    enum Origin: String, Codable {
        case local
        case remote
    }

    let origin: Origin
    let path: String
    let name: String
    let isDirectory: Bool
    let sessionID: UUID?

    static func local(_ file: LocalFile) -> FileDragPayload {
        FileDragPayload(origin: .local, path: file.url.path, name: file.name, isDirectory: file.isDirectory, sessionID: nil)
    }

    static func remote(_ file: RemoteFile, currentPath: String, sessionID: UUID) -> FileDragPayload {
        FileDragPayload(
            origin: .remote,
            path: SFTPManager.childPath(parent: currentPath, child: file.name),
            name: file.name,
            isDirectory: file.isDirectory,
            sessionID: sessionID
        )
    }

    var itemProvider: NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.json.identifier,
            visibility: .all
        ) { completion in
            completion(try? JSONEncoder().encode(self), nil)
            return nil
        }
        return provider
    }
}

private func copyFilePayloadsToPasteboard(_ payloads: [FileDragPayload]) {
    guard !payloads.isEmpty, let data = try? JSONEncoder().encode(payloads) else { return }
    let paths = payloads.map(\.path).joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setData(data, forType: filePayloadPasteboardType)
    NSPasteboard.general.setString(paths, forType: .string)
}

private func filePayloadsFromPasteboard() -> [FileDragPayload] {
    guard let data = NSPasteboard.general.data(forType: filePayloadPasteboardType),
          let payloads = try? JSONDecoder().decode([FileDragPayload].self, from: data)
    else { return [] }
    return payloads
}

private final class DropCollector<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.withLock { values.append(value) }
    }

    func collectedValues() -> [Value] {
        lock.withLock { values }
    }
}

@discardableResult
private func loadDragPayloads(
    from providers: [NSItemProvider],
    origin: FileDragPayload.Origin,
    completion: @escaping ([FileDragPayload]) -> Void
) -> Bool {
    let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.json.identifier) }
    guard !matching.isEmpty else { return false }

    let group = DispatchGroup()
    let collector = DropCollector<FileDragPayload>()

    for provider in matching {
        group.enter()
        provider.loadDataRepresentation(forTypeIdentifier: UTType.json.identifier) { data, _ in
            defer { group.leave() }
            guard let data,
                  let payload = try? JSONDecoder().decode(FileDragPayload.self, from: data),
                  payload.origin == origin
            else { return }
            collector.append(payload)
        }
    }

    group.notify(queue: .main) {
        let payloads = collector.collectedValues()
        if !payloads.isEmpty { completion(payloads) }
    }
    return true
}

@discardableResult
private func loadAnyDragPayloads(
    from providers: [NSItemProvider],
    completion: @escaping ([FileDragPayload]) -> Void
) -> Bool {
    let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.json.identifier) }
    guard !matching.isEmpty else { return false }

    let group = DispatchGroup()
    let collector = DropCollector<FileDragPayload>()

    for provider in matching {
        group.enter()
        provider.loadDataRepresentation(forTypeIdentifier: UTType.json.identifier) { data, _ in
            defer { group.leave() }
            guard let data,
                  let payload = try? JSONDecoder().decode(FileDragPayload.self, from: data)
            else { return }
            collector.append(payload)
        }
    }

    group.notify(queue: .main) {
        let payloads = collector.collectedValues()
        if !payloads.isEmpty { completion(payloads) }
    }
    return true
}

@discardableResult
private func loadFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
    let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    guard !matching.isEmpty else { return false }

    let group = DispatchGroup()
    let collector = DropCollector<URL>()

    for provider in matching {
        group.enter()
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            defer { group.leave() }
            guard let data,
                  let value = String(data: data, encoding: .utf8),
                  let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return }
            collector.append(url)
        }
    }

    group.notify(queue: .main) {
        let urls = collector.collectedValues()
        if !urls.isEmpty { completion(urls) }
    }
    return true
}

// MARK: - Local Pane

struct LocalPaneView: View {
    let currentPath: URL
    let endpointPicker: AnyView
    @Binding var files: [LocalFile]
    let canGoBack: Bool
    let canGoForward: Bool
    let isDropTarget: Bool
    let onNavigate: (URL) -> Void
    let onBack: () -> Void
    let onForward: () -> Void
    let onUpload: ([URL]) -> Void
    let onDownload: ([FileDragPayload]) -> Void
    let onDropEnter: () -> Void
    let onDropExit: () -> Void
    let onRefresh: () -> Void
    @State private var sortField: FileSortField = .name
    @State private var sortAscending = true
    @State private var selectedFiles: Set<UUID> = []
    @State private var showNewFolder = false
    @State private var showNewFile = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "Local",
                path: currentPath.path,
                icon: "desktopcomputer",
                endpointPicker: endpointPicker,
                canGoBack: canGoBack,
                canGoForward: canGoForward,
                onBack: onBack,
                onForward: onForward,
                onNavigatePath: { onNavigate(URL(fileURLWithPath: $0)) },
                onRefresh: onRefresh,
                onNewFolder: { showNewFolder = true },
                onNewFile: { showNewFile = true }
            )
            FileSortBar(field: $sortField, ascending: $sortAscending)
            Divider()
            List(selection: $selectedFiles) {
                ForEach(sortedFiles) { file in
                    Button {
                        if file.isDirectory { onNavigate(file.url) }
                        else { NSWorkspace.shared.open(file.url) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: localFileIcon(for: file))
                                .foregroundColor(file.isDirectory ? .blue : localFileColor(for: file.name))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(file.sizeString)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                    Text(file.modifiedString)
                                        .font(.footnote)
                                        .foregroundColor(Color.secondary.opacity(0.6))
                                }
                            }
                            Spacer()
                            HStack(spacing: 4) {
                                if !file.isDirectory {
                                    Button {
                                        NSWorkspace.shared.open(file.url)
                                    } label: {
                                        Image(systemName: "arrow.up.forward.app")
                                            .foregroundColor(Color.accentColor)
                                            .frame(width: 28, height: 28)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open with default app")
                                }
                                Button {
                                    onUpload([file.url])
                                } label: {
                                    Image(systemName: file.isDirectory ? "arrow.up.doc.fill" : "arrow.up.circle")
                                        .foregroundColor(Color.accentColor)
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(file.isDirectory ? "Upload folder to remote" : "Upload file to remote")
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 5)
                        .tahoeMagnifyGlass(
                            enabled: true,
                            isActive: false,
                            tint: file.isDirectory ? .blue : localFileColor(for: file.name),
                            cornerRadius: 8,
                            scale: 1.025,
                            lift: 0.5,
                            response: 0.46,
                            dampingFraction: 0.96
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onDrag { FileDragPayload.local(file).itemProvider }
                    .tag(file.id)
                    .contextMenu {
                        if !file.isDirectory {
                            Button { NSWorkspace.shared.open(file.url) } label: {
                                Label("Open", systemImage: "arrow.up.forward.app")
                            }
                            Button { onUpload([file.url]) } label: {
                                Label("Upload to Remote", systemImage: "arrow.up.circle")
                            }
                            Divider()
                        } else {
                            Button { onNavigate(file.url) } label: {
                                Label("Open Folder", systemImage: "folder")
                            }
                            Button { onUpload([file.url]) } label: {
                                Label("Upload Folder to Remote", systemImage: "arrow.up.doc.fill")
                            }
                            Divider()
                        }
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([file.url])
                        } label: {
                            Label("Show in Finder", systemImage: "finder")
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(file.url.path, forType: .string)
                        } label: {
                            Label("Copy Path", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) {
                            try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                            onRefresh()
                        } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                    }
                }
                Color.clear
                    .frame(minHeight: 160)
                    .contentShape(Rectangle())
                    .contextMenu { localEmptySpaceContextMenu }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .focusable()
            .contextMenu { localEmptySpaceContextMenu }
            .overlay { dropHighlight }
            .onDrop(
                of: [UTType.json.identifier],
                isTargeted: dropTargetBinding,
                perform: handleRemoteDrop
            )
            .onKeyPress(.init("a"), phases: .down) { press in
                guard press.modifiers == [.command] else { return .ignored }
                selectedFiles = Set(sortedFiles.map(\.id))
                return .handled
            }
            .onKeyPress(.init("c"), phases: .down) { press in
                guard press.modifiers == [.command] else { return .ignored }
                copySelectedLocalFiles()
                return .handled
            }
            .onKeyPress(.init("v"), phases: .down) { press in
                guard press.modifiers == [.command] else { return .ignored }
                pasteIntoLocalPane()
                return .handled
            }
            .onKeyPress(.deleteForward, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                deleteSelectedLocalFiles()
                return .handled
            }
            .onKeyPress(.delete, phases: .down) { _ in
                deleteSelectedLocalFiles()
                return .handled
            }
        }
        .sheet(isPresented: $showNewFolder) {
            RenameSheet(title: "New Folder", prompt: "Folder name", initialValue: "") { name in
                createLocalFolder(named: name)
            }
        }
        .sheet(isPresented: $showNewFile) {
            RenameSheet(title: "New File", prompt: "File name", initialValue: "") { name in
                createLocalFile(named: name)
            }
        }
    }

    @ViewBuilder
    private var localEmptySpaceContextMenu: some View {
        Button { showNewFolder = true } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        Button { showNewFile = true } label: {
            Label("New File", systemImage: "doc.badge.plus")
        }
        Divider()
        Button { onRefresh() } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([currentPath])
        } label: {
            Label("Show in Finder", systemImage: "finder")
        }
    }

    private func createLocalFolder(named name: String) {
        let url = currentPath.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        onRefresh()
    }

    private func createLocalFile(named name: String) {
        let url = currentPath.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        onRefresh()
    }

    private var sortedFiles: [LocalFile] {
        files.sorted {
            return compareFiles(
                lhsIsDirectory: $0.isDirectory,
                rhsIsDirectory: $1.isDirectory,
                ascending: sortAscending,
                comparison: localComparison($0, $1)
            )
        }
    }

    private var dropTargetBinding: Binding<Bool> {
        Binding(
            get: { isDropTarget },
            set: { $0 ? onDropEnter() : onDropExit() }
        )
    }

    private func handleRemoteDrop(_ providers: [NSItemProvider]) -> Bool {
        loadDragPayloads(from: providers, origin: .remote, completion: onDownload)
    }

    private func copySelectedLocalFiles() {
        let selected = sortedFiles.filter { selectedFiles.contains($0.id) }
        copyFilePayloadsToPasteboard(selected.map(FileDragPayload.local))
    }

    private func pasteIntoLocalPane() {
        let payloads = filePayloadsFromPasteboard()
        guard !payloads.isEmpty else { return }

        let localPayloads = payloads.filter { $0.origin == .local }
        for payload in localPayloads {
            copyLocalPayload(payload)
        }

        let remotePayloads = payloads.filter { $0.origin == .remote }
        if !remotePayloads.isEmpty {
            onDownload(remotePayloads)
        }
    }

    private func copyLocalPayload(_ payload: FileDragPayload) {
        let source = URL(fileURLWithPath: payload.path)
        let destination = uniqueLocalDestination(for: payload.name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            onRefresh()
        } catch {
            NSSound.beep()
        }
    }

    private func uniqueLocalDestination(for name: String) -> URL {
        let base = currentPath.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }

        let nsName = name as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        for index in 2...999 {
            let candidateName = ext.isEmpty ? "\(stem) copy \(index)" : "\(stem) copy \(index).\(ext)"
            let candidate = currentPath.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return currentPath.appendingPathComponent("\(stem) copy \(UUID().uuidString)")
    }

    private func deleteSelectedLocalFiles() {
        let selected = sortedFiles.filter { selectedFiles.contains($0.id) }
        guard !selected.isEmpty else { return }
        for file in selected {
            try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        }
        selectedFiles.removeAll()
        onRefresh()
    }

    private func localComparison(_ lhs: LocalFile, _ rhs: LocalFile) -> ComparisonResult {
        switch sortField {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            return compare(lhs.size, rhs.size)
        case .modified:
            return compare(lhs.modified ?? .distantPast, rhs.modified ?? .distantPast)
        case .type:
            let result = (lhs.name as NSString).pathExtension.localizedStandardCompare(
                (rhs.name as NSString).pathExtension
            )
            return result == .orderedSame ? lhs.name.localizedStandardCompare(rhs.name) : result
        }
    }

    var dropHighlight: some View {
        TransferDropHighlight(isTargeted: isDropTarget, title: "Drop to download")
    }

    private func localFileIcon(for file: LocalFile) -> String {
        if file.isDirectory { return "folder.fill" }
        switch (file.name as NSString).pathExtension.lowercased() {
        case "py":                        return "doc.text"
        case "sh", "bash":                return "terminal"
        case "pdb":                       return "atom"
        case "dat", "out", "log", "txt":  return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif": return "photo"
        case "pdf":                       return "doc.richtext"
        case "zip", "tar", "gz":          return "archivebox"
        default:                          return "doc"
        }
    }

    private func localFileColor(for name: String) -> Color {
        switch (name as NSString).pathExtension.lowercased() {
        case "py":           return .yellow
        case "sh", "bash":   return .green
        case "pdb":          return .purple
        case "dat", "out":   return .orange
        default:             return .secondary
        }
    }
}

// MARK: - Remote Pane

struct RemotePaneView: View {
    @ObservedObject var sftp: SFTPManager
    let session: Session
    let endpointPicker: AnyView
    let isDropTarget: Bool
    let onDownload: (RemoteFile) -> Void
    let onDownloadMany: ([RemoteFile]) -> Void
    let onDrop: ([FileDragPayload]) -> Void
    let onDropEnter: () -> Void
    let onDropExit: () -> Void

    @State private var filterDate: Date? = nil
    @State private var showDatePicker = false
    @State private var sortField: FileSortField = .type
    @State private var sortAscending = true
    @State private var searchText = ""
    @State private var showNewFolder = false
    @State private var showNewFile = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: session.name,
                path: sftp.currentPath,
                icon: "server.rack",
                endpointPicker: endpointPicker,
                canGoBack: sftp.canGoBack,
                canGoForward: sftp.canGoForward,
                onBack: { sftp.goBack() },
                onForward: { sftp.goForward() },
                onNavigatePath: { sftp.listFiles(at: $0) },
                onRefresh: { sftp.listFiles(at: sftp.currentPath, pushHistory: false, forceRefresh: true) },
                onHome: { sftp.goHome(for: session) },
                onNewFolder: { showNewFolder = true },
                onNewFile: { showNewFile = true }
            )

            // Date filter bar
            HStack(spacing: 5) {
                Button {
                    if filterDate != nil { filterDate = nil }
                    else { filterDate = Calendar.current.startOfDay(for: Date()) }
                } label: {
                    Label("Today", systemImage: "calendar.badge.clock")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(filterDate != nil && Calendar.current.isDateInToday(filterDate!)
                            ? Color.accentColor.opacity(0.15) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Show only files modified today")

                Button {
                    showDatePicker.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12))
                        if let d = filterDate, !Calendar.current.isDateInToday(d) {
                            Text(d, format: .dateTime.month(.abbreviated).day())
                                .font(.system(size: 12, weight: .medium))
                        } else {
                            Text("Pick Date")
                                .font(.system(size: 12))
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(filterDate != nil && !Calendar.current.isDateInToday(filterDate!)
                        ? Color.accentColor.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Filter by specific date")
                .popover(isPresented: $showDatePicker) {
                    DatePickerPopover(selected: filterDate ?? Date()) { picked in
                        filterDate = Calendar.current.startOfDay(for: picked)
                        showDatePicker = false
                    } onClear: {
                        filterDate = nil
                        showDatePicker = false
                    }
                }

                if filterDate != nil {
                    Button {
                        filterDate = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .help("Clear date filter")
                    .transition(.scale.combined(with: .opacity))
                }

                Spacer()

                FileSortControl(field: $sortField, ascending: $sortAscending)

                if filterDate != nil {
                    let count = sftp.files.filter { fileMatchesDate($0) }.count
                    Text("\(count) file\(count == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial)
            .animation(.easeOut(duration: 0.15), value: filterDate != nil)

            // Search + hidden-files toolbar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Filter files…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
                Divider().frame(height: 14)
                Button {
                    sftp.toggleHiddenFiles()
                } label: {
                    Label(sftp.showHiddenFiles ? "Hide dotfiles" : "Show dotfiles",
                          systemImage: sftp.showHiddenFiles ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help(sftp.showHiddenFiles ? "Hide hidden files" : "Show hidden files")
                .foregroundStyle(sftp.showHiddenFiles ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)

            Divider()

            if sftp.isLoading && !sftp.files.isEmpty {
                ProgressView(value: nil as Double?)
                    .progressViewStyle(.linear)
                    .frame(height: 2)
                    .padding(.horizontal, 0)
            }
            if sftp.isShowingCachedListing || !sftp.listingStatus.isEmpty {
                HStack(spacing: 6) {
                    if sftp.listingStatus == "Refreshing" || sftp.listingStatus == "Loading" {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(sftp.isShowingCachedListing ? "Cached contents" : sftp.listingStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial)
            }

            remoteContent
        }
        .sheet(isPresented: $showNewFolder) {
            RenameSheet(title: "New Folder", prompt: "Folder name", initialValue: "") { name in
                sftp.newFolder(named: name, session: session)
            }
        }
        .sheet(isPresented: $showNewFile) {
            RenameSheet(title: "New File", prompt: "File name", initialValue: "") { name in
                sftp.newFile(named: name, session: session)
            }
        }
    }

    private func fileMatchesDate(_ file: RemoteFile) -> Bool {
        guard let filterDate else { return true }
        // ls -la modified format: "Jan  1" or "Jan  1 2023"
        let modified = file.modified
        let cal = Calendar.current
        let filterComponents = cal.dateComponents([.year, .month, .day], from: filterDate)

        // Try to parse the month and day from the ls output
        let months = ["Jan":1,"Feb":2,"Mar":3,"Apr":4,"May":5,"Jun":6,
                      "Jul":7,"Aug":8,"Sep":9,"Oct":10,"Nov":11,"Dec":12]
        let parts = modified.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2,
              let month = months[parts[0]],
              let day = Int(parts[1]) else { return true }

        let year = parts.count >= 3 ? (Int(parts[2]) ?? cal.component(.year, from: Date()))
                                    : cal.component(.year, from: Date())

        return filterComponents.month == month
            && filterComponents.day == day
            && filterComponents.year == year
    }

    var remoteContent: some View {
        Group {
            if sftp.isLoading && sftp.files.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("Loading...")
                    Spacer()
                }
            } else if sftp.error != nil {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(sftp.error ?? "Unknown error")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { sftp.listFiles(at: sftp.currentPath, forceRefresh: true) }
                    Spacer()
                }
                .padding()
            } else {
                let dateFiltered = filterDate == nil ? sftp.files : sftp.files.filter { fileMatchesDate($0) }
                let filtered = searchText.isEmpty ? dateFiltered : dateFiltered.filter {
                    $0.name.localizedCaseInsensitiveContains(searchText)
                }
                RemoteFileList(
                    files: sortedRemoteFiles(filtered),
                    isDropTarget: isDropTarget,
                    session: session,
                    sftp: sftp,
                    onNavigate: { name in
                        sftp.listFiles(at: SFTPManager.childPath(parent: sftp.currentPath, child: name))
                    },
                    onDownload: onDownload,
                    onDownloadMany: onDownloadMany,
                    onDrop: onDrop,
                    onDropEnter: onDropEnter,
                    onDropExit: onDropExit
                )
            }
        }
    }

    private func sortedRemoteFiles(_ files: [RemoteFile]) -> [RemoteFile] {
        files.sorted {
            let lhsPinned = isPinnedServerFolder($0)
            let rhsPinned = isPinnedServerFolder($1)
            if lhsPinned != rhsPinned { return lhsPinned }
            if $0.isDirectory && $1.isDirectory {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return compareFiles(
                lhsIsDirectory: $0.isDirectory,
                rhsIsDirectory: $1.isDirectory,
                ascending: sortAscending,
                comparison: remoteComparison($0, $1)
            )
        }
    }

    private func isPinnedServerFolder(_ file: RemoteFile) -> Bool {
        file.isDirectory && file.name.caseInsensitiveCompare("01_Simulations") == .orderedSame
    }

    private func remoteComparison(_ lhs: RemoteFile, _ rhs: RemoteFile) -> ComparisonResult {
        switch sortField {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            return compare(Int64(lhs.size) ?? 0, Int64(rhs.size) ?? 0)
        case .modified:
            return compare(lhs.modifiedDate ?? .distantPast, rhs.modifiedDate ?? .distantPast)
        case .type:
            let result = (lhs.name as NSString).pathExtension.localizedStandardCompare(
                (rhs.name as NSString).pathExtension
            )
            return result == .orderedSame ? lhs.name.localizedStandardCompare(rhs.name) : result
        }
    }

    var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.accentColor, lineWidth: isDropTarget ? 3 : 0)
            .padding(4)
    }
}

// MARK: - Remote File List

struct RemoteFileList: View {
    let files: [RemoteFile]
    let isDropTarget: Bool
    let session: Session
    let sftp: SFTPManager
    let onNavigate: (String) -> Void
    let onDownload: (RemoteFile) -> Void
    let onDownloadMany: ([RemoteFile]) -> Void
    let onDrop: ([FileDragPayload]) -> Void
    let onDropEnter: () -> Void
    let onDropExit: () -> Void

    @State private var openingFile: String?
    @State private var selectedFiles: Set<String> = []
    @State private var renameTarget: RemoteFile?
    @State private var renameText = ""
    @State private var deleteTarget: RemoteFile?
    @State private var permTarget: RemoteFile?
    @State private var permText = ""
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var showNewFile = false

    var body: some View {
        List(selection: $selectedFiles) {
            ForEach(files) { file in
                Button {
                    if file.isDirectory { onNavigate(file.name) }
                    else { openInEditor(file) }
                } label: {
                    remoteFileRow(file)
                }
                .buttonStyle(.plain)
                .contextMenu { remoteContextMenu(for: file) }
                .tag(file.id)
                .onDrag { FileDragPayload.remote(file, currentPath: sftp.currentPath, sessionID: session.id).itemProvider }
            }
            Color.clear
                .frame(minHeight: 160)
                .contentShape(Rectangle())
                .contextMenu { emptySpaceContextMenu }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .focusable()
        .contextMenu { emptySpaceContextMenu }
        .overlay {
            TransferDropHighlight(isTargeted: isDropTarget, title: "Drop to upload")
        }
        .overlay {
            if sftp.isDeleting {
                ZStack {
                    Color.black.opacity(0.35)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(1.2)
                        Text(sftp.deleteProgress)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        // ⌘A — select all
        .onKeyPress(.init("a"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selectedFiles = Set(files.map(\.id))
            return .handled
        }
        // ⌘C — copy selected files/folders as transferable clipboard items
        .onKeyPress(.init("c"), phases: .down) { press in
            guard press.modifiers == [.command] else { return .ignored }
            copySelectedRemoteFiles()
            return .handled
        }
        // ⌘V — paste copied local or remote files/folders into this remote directory
        .onKeyPress(.init("v"), phases: .down) { press in
            guard press.modifiers == [.command] else { return .ignored }
            pasteIntoRemotePane()
            return .handled
        }
        // ⌘Delete or Backspace — delete selected
        .onKeyPress(.deleteForward, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            deleteSelected()
            return .handled
        }
        .onKeyPress(.delete, phases: .down) { _ in
            deleteSelected()
            return .handled
        }
        .toolbar {
            ToolbarItem {
                Button { showNewFolder = true } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .help("New Folder")
            }
            ToolbarItem {
                if !selectedFiles.isEmpty {
                    Button {
                        let toDownload = files.filter { selectedFiles.contains($0.id) }
                        onDownloadMany(toDownload)
                        selectedFiles.removeAll()
                    } label: {
                        Label("Download Selected", systemImage: "arrow.down.circle")
                    }
                    .help("Download \(selectedFiles.count) selected item\(selectedFiles.count == 1 ? "" : "s")")
                }
            }
        }
        .onDrop(
            of: [UTType.json.identifier, UTType.fileURL.identifier],
            isTargeted: dropTargetBinding,
            perform: handleLocalDrop
        )
        // Rename sheet
        .sheet(item: $renameTarget) { file in
            RenameSheet(title: "Rename", prompt: "New name", initialValue: file.name) { newName in
                sftp.rename(file: file, to: newName, session: session)
            }
        }
        // Delete confirmation
        .alert(
            "Delete \"\(deleteTarget?.name ?? "")\"?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let f = deleteTarget { sftp.deleteMany(files: [f]) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            let isDir = deleteTarget?.isDirectory == true
            Text(isDir
                 ? "This will permanently delete the folder and all its contents."
                 : "This file will be permanently deleted.")
        }
        // Permissions sheet
        .sheet(item: $permTarget) { file in
            PermissionsSheet(fileName: file.name, initialMode: file.permissions) { mode in
                sftp.changePermissions(file: file, mode: mode, session: session)
            }
        }
        // New folder sheet
        .sheet(isPresented: $showNewFolder) {
            RenameSheet(title: "New Folder", prompt: "Folder name", initialValue: "") { name in
                sftp.newFolder(named: name, session: session)
            }
        }
        .sheet(isPresented: $showNewFile) {
            RenameSheet(title: "New File", prompt: "File name", initialValue: "") { name in
                sftp.newFile(named: name, session: session)
            }
        }
    }

    @ViewBuilder
    private var emptySpaceContextMenu: some View {
        Button { showNewFolder = true } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        Button { showNewFile = true } label: {
            Label("New File", systemImage: "doc.badge.plus")
        }
        if !selectedFiles.isEmpty {
            Divider()
            Button(role: .destructive) { deleteSelected() } label: {
                Label("Delete Selected", systemImage: "trash")
            }
        }
        Divider()
        Button { sftp.listFiles(at: sftp.currentPath, pushHistory: false, forceRefresh: true) } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }

    private func deleteSelected() {
        let toDelete = files.filter { selectedFiles.contains($0.id) }
        guard !toDelete.isEmpty else { return }
        selectedFiles.removeAll()
        sftp.deleteMany(files: toDelete)
    }

    private func copySelectedRemoteFiles() {
        let selected = files.filter { selectedFiles.contains($0.id) }
        let payloads = selected.map {
            FileDragPayload.remote($0, currentPath: sftp.currentPath, sessionID: session.id)
        }
        copyFilePayloadsToPasteboard(payloads)
    }

    private func pasteIntoRemotePane() {
        let payloads = filePayloadsFromPasteboard()
        guard !payloads.isEmpty else { return }
        onDrop(payloads)
    }

    private var dropTargetBinding: Binding<Bool> {
        Binding(
            get: { isDropTarget },
            set: { $0 ? onDropEnter() : onDropExit() }
        )
    }

    private func handleLocalDrop(_ providers: [NSItemProvider]) -> Bool {
        let internalProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.json.identifier) }
        if !internalProviders.isEmpty {
            return loadAnyDragPayloads(from: internalProviders, completion: onDrop)
        }
        return loadFileURLs(from: providers) { urls in
            onDrop(urls.map {
                FileDragPayload(
                    origin: .local,
                    path: $0.path,
                    name: $0.lastPathComponent,
                    isDirectory: ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false),
                    sessionID: nil
                )
            })
        }
    }

    @ViewBuilder
    private func remoteFileRow(_ file: RemoteFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon(for: file))
                .foregroundColor(file.isDirectory ? .blue : fileColor(for: file.name))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text(file.isDirectory ? "Folder" : file.size)
                        .font(.footnote).foregroundColor(.secondary)
                    Text(file.permissions)
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(Color.secondary.opacity(0.6))
                    Text(file.modified)
                        .font(.footnote).foregroundColor(Color.secondary.opacity(0.6))
                }
            }
            Spacer()
            if openingFile == file.name {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 4) {
                    if !file.isDirectory {
                        Button { openInEditor(file) } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .foregroundColor(Color.accentColor)
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Open with default app")
                    }
                    Button { onDownload(file) } label: {
                        Image(systemName: file.isDirectory ? "arrow.down.doc.fill" : "arrow.down.circle")
                            .foregroundColor(Color.accentColor)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(file.isDirectory ? "Download folder" : "Download file")
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .tahoeMagnifyGlass(
            enabled: true,
            isActive: false,
            tint: file.isDirectory ? .blue : fileColor(for: file.name),
            cornerRadius: 8,
            scale: 1.025,
            lift: 0.5,
            response: 0.46,
            dampingFraction: 0.96
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func remoteContextMenu(for file: RemoteFile) -> some View {
        if file.isDirectory {
            Button { onNavigate(file.name) } label: { Label("Open Folder", systemImage: "folder") }
            Button { onDownload(file) } label: { Label("Download Folder", systemImage: "arrow.down.doc.fill") }
        } else {
            Button { openInEditor(file) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            if let vsCode = quickEditorURL(bundleID: "com.microsoft.VSCode") {
                Button { openInApp(file, appURL: vsCode) } label: {
                    Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            if let notepadpp = quickEditorURL(bundleID: "com.rizaldovinaldy.notepadplusplus") {
                Button { openInApp(file, appURL: notepadpp) } label: {
                    Label("Open in Notepad++", systemImage: "doc.plaintext")
                }
            }
            let apps = openWithApps(for: file.name)
            Menu {
                ForEach(apps, id: \.self) { appURL in
                    Button {
                        openInApp(file, appURL: appURL)
                    } label: {
                        Label(
                            appURL.deletingPathExtension().lastPathComponent,
                            systemImage: "app"
                        )
                    }
                }
                if !apps.isEmpty { Divider() }
                Button {
                    pickAppAndOpen(file)
                } label: {
                    Label("Other…", systemImage: "ellipsis.circle")
                }
            } label: {
                Label("Open With", systemImage: "arrow.up.forward.app")
            }
            Button { onDownload(file) } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
        Divider()
        Button {
            renameText = file.name
            renameTarget = file
        } label: { Label("Rename…", systemImage: "pencil") }
        Button {
            let ext = (file.name as NSString).pathExtension
            let base = (file.name as NSString).deletingPathExtension
            let copyName = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
            sftp.copyFile(file, to: copyName)
        } label: { Label("Duplicate", systemImage: "doc.on.doc") }
        Button {
            permText = file.permissions
            permTarget = file
        } label: { Label("Change Permissions…", systemImage: "lock.rotation") }
        Divider()
        Button {
            let path = SFTPManager.childPath(parent: sftp.currentPath, child: file.name)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        Divider()
        Button(role: .destructive) { deleteTarget = file } label: { Label("Delete", systemImage: "trash") }
    }

    private func openInEditor(_ file: RemoteFile) {
        guard !file.isDirectory else { return }
        openingFile = file.name
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
        sftp.download(file: file, to: tmpURL, session: session) {
            openingFile = nil
            guard FileManager.default.fileExists(atPath: tmpURL.path) else { return }
            NSWorkspace.shared.open(tmpURL)
            startWatching(file: file, tmpURL: tmpURL)
        }
    }

    private func openInApp(_ file: RemoteFile, appURL: URL) {
        guard !file.isDirectory else { return }
        openingFile = file.name
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
        sftp.download(file: file, to: tmpURL, session: session) {
            openingFile = nil
            guard FileManager.default.fileExists(atPath: tmpURL.path) else { return }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([tmpURL], withApplicationAt: appURL, configuration: cfg)
            startWatching(file: file, tmpURL: tmpURL)
        }
    }

    private func startWatching(file: RemoteFile, tmpURL: URL) {
        let remotePath = SFTPManager.childPath(parent: sftp.currentPath, child: file.name)
        sftp.fileSync.watch(
            tempURL: tmpURL,
            remotePath: remotePath,
            sessionName: session.name
        ) { [sftp] url, done in
            sftp.uploadBack(localURL: url, remotePath: remotePath, completion: done)
        }
    }

    private func quickEditorURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private func openWithApps(for fileName: String) -> [URL] {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let dummyURL = URL(fileURLWithPath: "/tmp/dummy\(ext.isEmpty ? "" : ".\(ext)")")

        var apps = Set(NSWorkspace.shared.urlsForApplications(toOpen: dummyURL))

        // For script/code/text extensions that macOS doesn't associate with editors,
        // also search using plain-text so editors like TextEdit, VS Code etc. appear.
        let textLikeExtensions: Set<String> = [
            "sh", "bash", "zsh", "py", "rb", "pl", "js", "ts", "json",
            "yaml", "yml", "toml", "ini", "cfg", "conf", "log", "txt",
            "md", "csv", "xml", "html", "css", "c", "cpp", "h", "swift",
            "rs", "go", "java", "kt", "r", "m", "f90", "f95", "f03"
        ]
        if apps.isEmpty || textLikeExtensions.contains(ext) {
            let plainTextURL = URL(fileURLWithPath: "/tmp/dummy.txt")
            apps.formUnion(NSWorkspace.shared.urlsForApplications(toOpen: plainTextURL))
        }

        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: dummyURL)
        return apps.sorted {
            if $0 == defaultApp { return true }
            if $1 == defaultApp { return false }
            return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func pickAppAndOpen(_ file: RemoteFile) {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.message = "Select an app to open \"\(file.name)\""
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let appURL = panel.url else { return }
            openInApp(file, appURL: appURL)
        }
    }

    private func fileIcon(for file: RemoteFile) -> String {
        if file.isDirectory { return "folder.fill" }
        switch (file.name as NSString).pathExtension.lowercased() {
        case "py":           return "doc.text"
        case "sh", "bash":   return "terminal"
        case "pdb":          return "atom"
        case "dat", "out", "log", "txt": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif": return "photo"
        case "pdf":          return "doc.richtext"
        case "zip", "tar", "gz": return "archivebox"
        default:             return "doc"
        }
    }

    private func fileColor(for name: String) -> Color {
        switch (name as NSString).pathExtension.lowercased() {
        case "py":           return .yellow
        case "sh", "bash":   return .green
        case "pdb":          return .purple
        case "dat", "out":   return .orange
        case "log", "txt":   return .secondary
        default:             return .secondary
        }
    }
}

private struct TransferDropHighlight: View {
    let isTargeted: Bool
    let title: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: isTargeted ? 3 : 0)
                .padding(4)

            if isTargeted {
                Label(title, systemImage: "tray.and.arrow.down.fill")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Rename Sheet

struct RenameSheet: View {
    let title: String
    let prompt: String
    let initialValue: String
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(title).font(.headline)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onAppear { text = initialValue }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button(title.hasPrefix("New ") ? "Create" : "Rename") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onConfirm(trimmed) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

// MARK: - Permissions Sheet

struct PermissionsSheet: View {
    let fileName: String
    let initialMode: String
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    // Octal bits: owner rwx, group rwx, other rwx
    @State private var ownerR = false; @State private var ownerW = false; @State private var ownerX = false
    @State private var groupR = false; @State private var groupW = false; @State private var groupX = false
    @State private var otherR = false; @State private var otherW = false; @State private var otherX = false

    var octal: String {
        let o = (ownerR ? 4:0) + (ownerW ? 2:0) + (ownerX ? 1:0)
        let g = (groupR ? 4:0) + (groupW ? 2:0) + (groupX ? 1:0)
        let x = (otherR ? 4:0) + (otherW ? 2:0) + (otherX ? 1:0)
        return "\(o)\(g)\(x)"
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Permissions — \(fileName)").font(.headline)

            Grid(alignment: .center, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("").frame(width: 50)
                    Text("Read").font(.footnote).foregroundStyle(.secondary)
                    Text("Write").font(.footnote).foregroundStyle(.secondary)
                    Text("Execute").font(.footnote).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Owner").font(.subheadline)
                    Toggle("", isOn: $ownerR).labelsHidden()
                    Toggle("", isOn: $ownerW).labelsHidden()
                    Toggle("", isOn: $ownerX).labelsHidden()
                }
                GridRow {
                    Text("Group").font(.subheadline)
                    Toggle("", isOn: $groupR).labelsHidden()
                    Toggle("", isOn: $groupW).labelsHidden()
                    Toggle("", isOn: $groupX).labelsHidden()
                }
                GridRow {
                    Text("Other").font(.subheadline)
                    Toggle("", isOn: $otherR).labelsHidden()
                    Toggle("", isOn: $otherW).labelsHidden()
                    Toggle("", isOn: $otherX).labelsHidden()
                }
            }

            Text("chmod \(octal)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Apply") { onConfirm(octal); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear { parsePermissions() }
    }

    private func parsePermissions() {
        // Parse either "rwxr-xr-x" style or octal string
        let s = initialMode
        if s.count >= 10 {
            // ls -la format: e.g. -rwxr-xr-x
            let chars = Array(s)
            ownerR = chars[1] == "r"; ownerW = chars[2] == "w"; ownerX = chars[3] == "x"
            groupR = chars[4] == "r"; groupW = chars[5] == "w"; groupX = chars[6] == "x"
            otherR = chars[7] == "r"; otherW = chars[8] == "w"; otherX = chars[9] == "x"
        } else if let val = Int(s), s.count == 3 {
            let digits = s.compactMap { $0.wholeNumberValue }
            ownerR = digits[0] & 4 != 0; ownerW = digits[0] & 2 != 0; ownerX = digits[0] & 1 != 0
            groupR = digits[1] & 4 != 0; groupW = digits[1] & 2 != 0; groupX = digits[1] & 1 != 0
            otherR = digits[2] & 4 != 0; otherW = digits[2] & 2 != 0; otherX = digits[2] & 1 != 0
            _ = val
        }
    }
}

// MARK: - Pane Header

private struct PaneHeaderButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 18, height: 18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(configuration.isPressed ? 0.12 : 0.20), lineWidth: 0.6)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.36)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct PaneHeader: View {
    let title: String
    let path: String
    let icon: String
    let endpointPicker: AnyView
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    let onBack: () -> Void
    var onForward: (() -> Void)? = nil
    var onNavigatePath: ((String) -> Void)? = nil
    var onRefresh: (() -> Void)? = nil
    var onHome: (() -> Void)? = nil
    var onNewFolder: (() -> Void)? = nil
    var onNewFile: (() -> Void)? = nil
    @State private var isEditingPath = false
    @State private var draftPath = ""
    @FocusState private var pathFieldFocused: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            endpointPicker
                .help("Change this pane endpoint")
                .frame(maxWidth: 72, alignment: .leading)
            Divider().frame(height: 12)
            Button { onBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
            }
                .buttonStyle(PaneHeaderButtonStyle())
                .disabled(!canGoBack)
                .help("Go back")
            Button { onForward?() } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
                .buttonStyle(PaneHeaderButtonStyle())
                .disabled(!canGoForward)
                .help("Go forward")
            Group {
                if isEditingPath {
                    TextField("Directory", text: $draftPath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($pathFieldFocused)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .onSubmit(commitEditedPath)
                        .onExitCommand { cancelPathEditing() }
                        .onAppear {
                            draftPath = path
                            DispatchQueue.main.async {
                                pathFieldFocused = true
                            }
                        }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 2) {
                                ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                                    if index > 0 {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Button {
                                        onNavigatePath?(crumb.path)
                                    } label: {
                                        Text(crumb.label)
                                            .font(.system(size: 12, design: .monospaced))
                                            .lineLimit(1)
                                            .foregroundStyle(index == breadcrumbs.count - 1 ? .primary : .secondary)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .tahoeMagnifyGlass(
                                                isActive: index == breadcrumbs.count - 1,
                                                tint: Color.accentColor,
                                                cornerRadius: 5,
                                                scale: 1.14,
                                                response: 0.48,
                                                dampingFraction: 0.95
                                            )
                                            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    }
                                    .id(index)
                                    .buttonStyle(.plain)
                                    .disabled(onNavigatePath == nil)
                                    .help("Go to \(crumb.path)")
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                        }
                        .onAppear { scrollToCurrentBreadcrumb(proxy) }
                        .onChange(of: path) { scrollToCurrentBreadcrumb(proxy) }
                    }
                }
            }
            .background(.quaternary.opacity(0.50), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .frame(minWidth: 0, maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture(count: 2) {
                beginPathEditing()
            }
            .onChange(of: path) { _, newPath in
                if !isEditingPath {
                    draftPath = newPath
                }
            }
            Spacer()
            Button {
                beginPathEditing()
            } label: {
                Image(systemName: "pencil").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(PaneHeaderButtonStyle())
            .disabled(onNavigatePath == nil)
            .help("Edit directory path")
            Menu {
                Button {
                    copyToPasteboard(path)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                Button {
                    copyToPasteboard("cd \(shellPathForCommand(path))")
                } label: {
                    Label("Copy cd Command", systemImage: "terminal")
                }
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 9, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(PaneHeaderButtonStyle())
            .help("Copy current directory")
            if onNewFolder != nil || onNewFile != nil {
                Menu {
                    if let onNewFolder {
                        Button { onNewFolder() } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                    }
                    if let onNewFile {
                        Button { onNewFile() } label: {
                            Label("New File", systemImage: "doc.badge.plus")
                        }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(PaneHeaderButtonStyle())
                .help("Create file or folder")
            }
            Button {
                if let parentPath {
                    onNavigatePath?(parentPath)
                }
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(PaneHeaderButtonStyle())
            .disabled(parentPath == nil || onNavigatePath == nil)
            .help("Go to parent folder")
            if let onHome {
                Button { onHome() } label: {
                    Image(systemName: "house").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(PaneHeaderButtonStyle())
                .help("Go to home directory")
            }
            if let onRefresh {
                Button { onRefresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
                }
                    .buttonStyle(PaneHeaderButtonStyle())
                    .help("Refresh")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider().opacity(0.42) }
    }

    private var parentPath: String? {
        guard path != "~", path != "/", path != ".", !path.isEmpty else { return nil }

        if path.hasPrefix("~/") {
            let parts = String(path.dropFirst(2)).split(separator: "/").map(String.init)
            let parentParts = parts.dropLast()
            return parentParts.isEmpty ? "~" : "~/" + parentParts.joined(separator: "/")
        }

        let parent = (path as NSString).deletingLastPathComponent
        if path.hasPrefix("/") {
            return parent.isEmpty ? "/" : parent
        }
        return parent.isEmpty ? "." : parent
    }

    private var breadcrumbs: [(label: String, path: String)] {
        if path == "~" || path.hasPrefix("~/") {
            let parts = path == "~" ? [] : String(path.dropFirst(2)).split(separator: "/").map(String.init)
            return breadcrumbItems(rootLabel: "~", rootPath: "~", parts: parts)
        }

        let isAbsolute = path.hasPrefix("/")
        let parts = path.split(separator: "/").map(String.init)
        return breadcrumbItems(rootLabel: isAbsolute ? "/" : ".", rootPath: isAbsolute ? "/" : ".", parts: parts)
    }

    private func breadcrumbItems(rootLabel: String, rootPath: String, parts: [String]) -> [(label: String, path: String)] {
        var result = [(label: rootLabel, path: rootPath)]
        var current = rootPath
        for part in parts {
            if current == "/" {
                current += part
            } else if current == "." {
                current = part
            } else {
                current += "/\(part)"
            }
            result.append((label: part, path: current))
        }
        return result
    }

    private func scrollToCurrentBreadcrumb(_ proxy: ScrollViewProxy) {
        let currentIndex = max(breadcrumbs.count - 1, 0)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(currentIndex, anchor: .trailing)
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func beginPathEditing() {
        guard onNavigatePath != nil else { return }
        draftPath = path
        isEditingPath = true
        DispatchQueue.main.async {
            pathFieldFocused = true
        }
    }

    private func commitEditedPath() {
        guard let committedPath = EditableRemotePathInput.committedPath(from: draftPath) else {
            cancelPathEditing()
            return
        }
        isEditingPath = false
        pathFieldFocused = false
        onNavigatePath?(committedPath)
    }

    private func cancelPathEditing() {
        draftPath = path
        isEditingPath = false
        pathFieldFocused = false
    }

    private func shellPathForCommand(_ value: String) -> String {
        SSHSecurity.remoteShellPath(value)
    }
}

enum EditableRemotePathInput {
    static func committedPath(from draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - File Sorting

enum FileSortField: String, CaseIterable {
    case name = "Name"
    case size = "Size"
    case modified = "Modified"
    case type = "Type"

    var icon: String {
        switch self {
        case .name: return "textformat"
        case .size: return "internaldrive"
        case .modified: return "calendar"
        case .type: return "doc"
        }
    }
}

struct FileSortBar: View {
    @Binding var field: FileSortField
    @Binding var ascending: Bool

    var body: some View {
        HStack {
            Text("Organize by")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            FileSortControl(field: $field, ascending: $ascending)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial)
    }
}

struct FileSortControl: View {
    @Binding var field: FileSortField
    @Binding var ascending: Bool

    var body: some View {
        HStack(spacing: 3) {
            Menu {
                ForEach(FileSortField.allCases, id: \.self) { option in
                    Button {
                        field = option
                    } label: {
                        Label(option.rawValue, systemImage: option == field ? "checkmark" : option.icon)
                    }
                }
            } label: {
                Label(field.rawValue, systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Organize files by \(field.rawValue.lowercased())")

            Button {
                ascending.toggle()
            } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(StudioGlassButtonStyle())
            .help(ascending ? "Ascending order" : "Descending order")
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

private func compareFiles(
    lhsIsDirectory: Bool,
    rhsIsDirectory: Bool,
    ascending: Bool,
    comparison: ComparisonResult
) -> Bool {
    if lhsIsDirectory != rhsIsDirectory { return lhsIsDirectory }
    return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
}

private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
    if lhs < rhs { return .orderedAscending }
    if lhs > rhs { return .orderedDescending }
    return .orderedSame
}

// MARK: - URL Helper

extension URL {
    var parent: URL? {
        let p = deletingLastPathComponent()
        return p == self ? nil : p
    }
}

// MARK: - Date Picker Popover

struct DatePickerPopover: View {
    @State private var date: Date
    let onSelect: (Date) -> Void
    let onClear: () -> Void

    init(selected: Date, onSelect: @escaping (Date) -> Void, onClear: @escaping () -> Void) {
        _date = State(initialValue: selected)
        self.onSelect = onSelect
        self.onClear = onClear
    }

    var body: some View {
        VStack(spacing: 12) {
            DatePicker("", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()

            HStack {
                Button("Clear Filter", action: onClear)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Today") { date = Date() }
                Button("Apply") { onSelect(date) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
