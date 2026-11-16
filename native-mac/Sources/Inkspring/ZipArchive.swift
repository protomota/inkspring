import CArchive
import Darwin
import Foundation

struct ZipArchive {
    static let jsonLimit: Int64 = 100 * 1024 * 1024
    static let mediaLimit: Int64 = 4 * 1024 * 1024 * 1024
    static let totalLimit: Int64 = 64 * 1024 * 1024 * 1024 + jsonLimit

    static func write(to url: URL, files: [(path: String, file: URL, size: Int64)]) throws {
        guard let archive = archive_write_new() else { throw WorkspaceError("Could not create the backup ZIP.") }
        defer { _ = archive_write_free(archive) }
        try check(archive_write_set_format_zip(archive), archive)
        try check(archive_write_zip_set_compression_store(archive), archive)
        let output = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw WorkspaceError("Couldn’t create a private backup file at this destination.") }
        defer { close(output) }
        try check(archive_write_open_fd(archive, output), archive)
        for file in files { try writeEntry(file, archive: archive) }
        try check(archive_write_close(archive), archive)
    }

    static func extract(from url: URL, to directory: URL) throws -> [String: URL] {
        guard let archive = archive_read_new() else { throw WorkspaceError("Could not open the backup ZIP.") }
        defer { _ = archive_read_free(archive) }
        try check(archive_read_support_format_zip(archive), archive)
        try check(archive_read_open_filename(archive, url.path, 64 * 1024), archive)
        var files: [String: URL] = [:]
        var total: Int64 = 0
        while true {
            var header: OpaquePointer?
            let result = archive_read_next_header(archive, &header)
            if result == 1 { return files }
            try check(result, archive)
            guard let header, let pathname = archive_entry_pathname(header),
                  let path = String(validatingCString: pathname), safe(path), files[path] == nil,
                  files.count < 10_001, archive_entry_filetype(header) == 0o100000,
                  archive_entry_is_encrypted(header) == 0, archive_entry_hardlink(header) == nil else {
                throw WorkspaceError("The backup ZIP contains a duplicate or unsupported entry.")
            }
            let size = archive_entry_size(header)
            let limit = path == "data.json" ? jsonLimit : mediaLimit
            guard size >= 0, size <= limit, total <= totalLimit - size else {
                throw WorkspaceError("A file in this backup exceeds the allowed size.")
            }
            let target = directory.appending(path: String(files.count))
            try readEntry(archive, to: target, size: size)
            files[path] = target
            total += size
        }
    }

    static func safe(_ name: String) -> Bool {
        name.range(of: #"\A(?:data\.json|media/images/[a-f0-9-]{36}\.(?:png|jpe?g|webp)|media/videos/[a-f0-9-]{36}\.(?:mp4|mov|webm))\z"#,
                   options: .regularExpression) != nil
    }

    private static func writeEntry(_ item: (path: String, file: URL, size: Int64), archive: OpaquePointer) throws {
        guard let entry = archive_entry_new() else { throw WorkspaceError("Could not add a file to the backup.") }
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname(entry, item.path)
        archive_entry_set_size(entry, item.size)
        archive_entry_set_filetype(entry, 0o100000)
        archive_entry_set_perm(entry, 0o600)
        try check(archive_write_header(archive, entry), archive)
        let input = try FileHandle(forReadingFrom: item.file)
        defer { try? input.close() }
        var total: Int64 = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            total += Int64(chunk.count)
            guard total <= item.size else { throw WorkspaceError("A file changed during backup.") }
            let count = chunk.withUnsafeBytes { archive_write_data(archive, $0.baseAddress, $0.count) }
            guard count == chunk.count else { throw failure(archive) }
        }
        guard total == item.size else { throw WorkspaceError("A file changed during backup.") }
    }

    private static func readEntry(_ archive: OpaquePointer, to url: URL, size: Int64) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw WorkspaceError("Could not stage a file from the backup.")
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var buffer = Data(count: 1024 * 1024)
        var total: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { archive_read_data(archive, $0.baseAddress, $0.count) }
            if count == 0 { break }
            guard count > 0 else { throw failure(archive) }
            total += Int64(count)
            guard total <= size else { throw WorkspaceError("A ZIP entry exceeded its declared size.") }
            try output.write(contentsOf: buffer.prefix(count))
        }
        guard total == size else { throw WorkspaceError("A ZIP entry is incomplete.") }
        try output.close()
    }

    private static func check(_ status: Int32, _ archive: OpaquePointer) throws {
        guard status == 0 else { throw failure(archive) }
    }

    private static func failure(_ archive: OpaquePointer) -> WorkspaceError {
        WorkspaceError(archive_error_string(archive).map { String(cString: $0) } ?? "Could not process the backup ZIP.")
    }
}
