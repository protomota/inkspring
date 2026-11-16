import Darwin
import Foundation

struct PublicationLeaseBusy: LocalizedError {
    var errorDescription: String? { "Wait for the current publishing attempt to finish." }
}

final class PublicationLease {
    private let descriptor: Int32

    init(directory: URL) throws {
        let file = directory.appending(path: ".publication.lock")
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw WorkspaceError("Couldn’t lock the publishing workspace.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw PublicationLeaseBusy()
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }
}
