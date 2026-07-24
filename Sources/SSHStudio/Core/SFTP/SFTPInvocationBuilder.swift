import Foundation

enum SFTPInvocationBuilder {
    static func invocation(for session: Session) throws -> SSHInvocation {
        try SSHCommandBuilder.sftpInvocation(for: session)
    }

    static func batchArguments(for operation: SFTPOperation) -> [String] {
        switch operation {
        case .listDirectory(let path):
            return ["ls", "-la", path.rawValue]
        case .upload(let local, let remote):
            return ["put", local.path, remote.rawValue]
        case .download(let remote, let local):
            return ["get", remote.rawValue, local.path]
        case .createDirectory(let path):
            return ["mkdir", path.rawValue]
        case .remove(let path):
            return ["rm", path.rawValue]
        }
    }
}
