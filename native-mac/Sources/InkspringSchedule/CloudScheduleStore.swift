import CloudKit
import CryptoKit
import Foundation
#if os(macOS)
import Security
#endif

@MainActor
public struct CloudScheduleStore {
    public static let containerID = "iCloud.com.protomota.inkspring"
    private static let recordID = CKRecord.ID(recordName: "inkspring-schedule-v1")
    private static let recordType = "InkspringSchedule"
    private let container: CKContainer

    public init() {
        container = CKContainer(identifier: Self.containerID)
    }

#if os(macOS)
    public static var hasEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let identifiers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String] else {
            return false
        }
        return identifiers.contains(containerID)
    }
#endif

    private var database: CKDatabase { container.privateCloudDatabase }

    private func libraryID(_ workspaceID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "inkspring-library-\(workspaceID.uuidString.lowercased())")
    }

    public func loadLibrary(workspaceID: UUID, account: String) async throws -> CompanionLibrary? {
        try await verifyLibraryWorkspace(workspaceID, account: account)
        let library = try await fetch(libraryID(workspaceID)).map(decodeLibrary)
        try await requireAccount(account)
        return library
    }

    public func updateLibrary(workspaceID: UUID, account: String, create: Bool = false,
                              _ change: (inout CompanionLibrary) throws -> Void) async throws -> CompanionLibrary {
        try await verifyLibraryWorkspace(workspaceID, account: account)
        return try await writeLibrary(workspaceID: workspaceID, account: account, create: create, change)
    }

    /// Clear the previous owner's mirrored content before disconnecting or transferring the schedule.
    public func clearLibrary(workspaceID: UUID, account: String) async throws {
        do {
            _ = try await writeLibrary(workspaceID: workspaceID, account: account, create: false) { library in
                if library.enabled { library.clear() }
            }
        } catch CompanionLibraryError.disabled {
            // Older Mac releases never created a library.
        }
    }

    private func verifyLibraryWorkspace(_ workspaceID: UUID, account: String) async throws {
        guard let schedule = try await load(confirmedAccount: account), schedule.sharing,
              schedule.workspaceID == workspaceID else { throw CompanionLibraryError.disabled }
    }

    private func writeLibrary(workspaceID: UUID, account: String, create: Bool,
                              _ change: (inout CompanionLibrary) throws -> Void) async throws -> CompanionLibrary {
        let id = libraryID(workspaceID)
        for _ in 0..<4 {
            try await requireAccount(account)
            let current = try await fetch(id)
            guard current != nil || create else { throw CompanionLibraryError.disabled }
            let record = current ?? CKRecord(recordType: Self.recordType, recordID: id)
            let previous = try current.map(decodeLibrary) ?? CompanionLibrary(workspaceID: workspaceID)
            guard previous.workspaceID == workspaceID else { throw CompanionScheduleError.changed }
            var library = previous
            try change(&library)
            if current != nil && library == previous { return library }
            let bytes = try JSONEncoder().encode(library)
            guard bytes.count < 512_000 else { throw CompanionScheduleError.oversized }
            record["schedule"] = bytes as CKRecordValue
            try await requireAccount(account)
            do {
                let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
                guard let saved = result.saveResults[id] else { throw CompanionScheduleError.changed }
                _ = try saved.get()
                try await requireAccount(account)
                return library
            } catch let error as CKError where error.code == .serverRecordChanged ||
                (error.partialErrorsByItemID?[id] as? CKError)?.code == .serverRecordChanged {
                continue
            }
        }
        throw CompanionScheduleError.changed
    }

    private func decodeLibrary(_ record: CKRecord) throws -> CompanionLibrary {
        guard let data = record["schedule"] as? Data else { throw CompanionScheduleError.changed }
        return try JSONDecoder().decode(CompanionLibrary.self, from: data)
    }

    public func accountKey() async throws -> String {
        try await checkAccount()
        let accountID = try await container.userRecordID()
        return SHA256.hash(data: Data(accountID.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func load(confirmedAccount: String) async throws -> CompanionSchedule? {
        try await requireAccount(confirmedAccount)
        let schedule = try await fetch().map(decode)
        try await requireAccount(confirmedAccount)
        return schedule
    }

    @discardableResult
    public func update(workspaceID: UUID, createIfMissing: Bool = false, expectedAccount: String,
                       _ mutation: (inout CompanionSchedule) throws -> Void) async throws -> CompanionSchedule {
        try await requireAccount(expectedAccount)
        for _ in 0..<4 {
            let current = try await fetch()
            try await requireAccount(expectedAccount)
            let record: CKRecord
            var schedule: CompanionSchedule
            if let current {
                record = current
                schedule = try decode(current)
                guard schedule.workspaceID == workspaceID else { throw CompanionScheduleError.anotherMac }
            } else {
                guard createIfMissing else { throw CompanionScheduleError.missing }
                record = CKRecord(recordType: Self.recordType, recordID: Self.recordID)
                schedule = CompanionSchedule(workspaceID: workspaceID, posts: [])
            }
            let previous = schedule
            try mutation(&schedule)
            if record.recordChangeTag != nil && schedule == previous { return schedule }
            let bytes = try JSONEncoder().encode(schedule)
            guard bytes.count < 512_000 else { throw CompanionScheduleError.oversized }
            record["schedule"] = bytes as CKRecordValue
            do {
                let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
                guard let saved = result.saveResults[Self.recordID] else { throw CompanionScheduleError.changed }
                _ = try saved.get()
                try await requireAccount(expectedAccount)
                return schedule
            } catch let error as CKError where error.code == .serverRecordChanged ||
                (error.partialErrorsByItemID?[Self.recordID] as? CKError)?.code == .serverRecordChanged {
                continue
            }
        }
        throw CompanionScheduleError.changed
    }

    private func checkAccount() async throws {
        let status = try await container.accountStatus()
        if status == .temporarilyUnavailable { throw CompanionScheduleError.cloudTemporarilyUnavailable }
        guard status == .available else { throw CompanionScheduleError.cloudUnavailable }
    }

    private func requireAccount(_ expected: String) async throws {
        guard try await accountKey() == expected else { throw CompanionScheduleError.accountChanged }
    }

    private func fetch(_ id: CKRecord.ID = Self.recordID) async throws -> CKRecord? {
        do { return try await database.record(for: id) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    private func decode(_ record: CKRecord) throws -> CompanionSchedule {
        guard let data = record["schedule"] as? Data else { throw CompanionScheduleError.changed }
        return try JSONDecoder().decode(CompanionSchedule.self, from: data)
    }
}
