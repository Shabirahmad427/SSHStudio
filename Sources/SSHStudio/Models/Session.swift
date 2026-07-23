import Foundation

struct Session: Codable, Identifiable, Hashable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Self.currentSchemaVersion
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    var authMethod: AuthMethod = .password
    /// Sensitive operational metadata. This is a local file reference, not a
    /// credential value, and is preserved for compatibility with existing profiles.
    var privateKeyPath: String = ""
    /// Sensitive operational metadata. The referenced ~/.ssh/config entry may
    /// reveal routing information and is preserved for compatibility.
    var sshConfigAlias: String = ""
    var credentialReferenceID: String = ""
    var remoteDirectory: String = ""
    var screenSharingHost: String = ""
    var screenSharingPort: Int = 5900
    var remoteScreenMode: RemoteScreenMode = .sshTunnel
    var remoteAccessAddress: String = ""
    var tunnels: [TunnelConfig] = []

    enum RemoteScreenMode: String, Codable, CaseIterable {
        case sshTunnel = "SSH Tunnel"
        case directVNC = "Direct VNC"
        case anyDesk = "AnyDesk"
        case dwService = "DWService"
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, host, port, username, authMethod
        case privateKeyPath, sshConfigAlias, credentialReferenceID, remoteDirectory
        case screenSharingHost, screenSharingPort
        case remoteScreenMode, remoteAccessAddress, tunnels
    }

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .password,
        privateKeyPath: String = "",
        sshConfigAlias: String = "",
        credentialReferenceID: String = "",
        remoteDirectory: String = "",
        screenSharingHost: String = "",
        screenSharingPort: Int = 5900,
        remoteScreenMode: RemoteScreenMode = .sshTunnel,
        remoteAccessAddress: String = "",
        tunnels: [TunnelConfig] = []
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.sshConfigAlias = sshConfigAlias
        self.credentialReferenceID = credentialReferenceID
        self.remoteDirectory = remoteDirectory
        self.screenSharingHost = screenSharingHost
        self.screenSharingPort = screenSharingPort
        self.remoteScreenMode = remoteScreenMode
        self.remoteAccessAddress = remoteAccessAddress
        self.tunnels = tunnels
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try values.decode(String.self, forKey: .username)
        authMethod = try values.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .password
        privateKeyPath = try values.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
        sshConfigAlias = try values.decodeIfPresent(String.self, forKey: .sshConfigAlias) ?? ""
        credentialReferenceID = try values.decodeIfPresent(String.self, forKey: .credentialReferenceID) ?? ""
        remoteDirectory = try values.decodeIfPresent(String.self, forKey: .remoteDirectory) ?? ""
        screenSharingHost = try values.decodeIfPresent(String.self, forKey: .screenSharingHost) ?? ""
        screenSharingPort = try values.decodeIfPresent(Int.self, forKey: .screenSharingPort) ?? 5900
        remoteScreenMode = try values.decodeIfPresent(RemoteScreenMode.self, forKey: .remoteScreenMode) ?? .sshTunnel
        remoteAccessAddress = try values.decodeIfPresent(String.self, forKey: .remoteAccessAddress) ?? ""
        tunnels = try values.decodeIfPresent([TunnelConfig].self, forKey: .tunnels) ?? []
    }

    enum AuthMethod: String, Codable, CaseIterable {
        case password = "Password"
        case privateKey = "Private Key"
    }
}

struct TunnelConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var type: TunnelType = .local
    var listenHost: String = "127.0.0.1"
    var localPort: Int = 8080
    var remoteHost: String = "localhost"
    var remotePort: Int = 80
    var autoReconnect: Bool = true

    enum TunnelType: String, Codable, CaseIterable {
        case local = "Local (-L)"
        case remote = "Remote (-R)"
        case dynamic = "Dynamic (-D)"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, listenHost, localPort, remoteHost, remotePort, autoReconnect
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try values.decodeIfPresent(TunnelType.self, forKey: .type) ?? .local
        listenHost = try values.decodeIfPresent(String.self, forKey: .listenHost) ?? "127.0.0.1"
        localPort = try values.decodeIfPresent(Int.self, forKey: .localPort) ?? 8080
        remoteHost = try values.decodeIfPresent(String.self, forKey: .remoteHost) ?? "localhost"
        remotePort = try values.decodeIfPresent(Int.self, forKey: .remotePort) ?? 80
        autoReconnect = try values.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
    }
}
