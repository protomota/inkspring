import Foundation
import InkspringSchedule

extension Workspace {
    var companionLibrarySharing: Bool { settings["companionLibrarySharing"] as? Bool == true }

    func setCompanionLibrarySharing(_ enabled: Bool) async {
        await withCompanionLibrarySync { cloud, id, account in
            if enabled {
                let previous = try await cloud.loadLibrary(workspaceID: id, account: account)
                try await publishCompanionLibrary(cloud, workspaceID: id, account: account,
                                                  previous: previous, enabling: true, completed: [])
            } else {
                try await cloud.clearLibrary(workspaceID: id, account: account)
            }
            try set("companionLibrarySharing", to: enabled)
        }
    }

    func syncCompanionLibrary() async {
        guard companionLibrarySharing else { return }
        var scheduleChanged = false
        await withCompanionLibrarySync { cloud, id, account in
            guard let previous = try await cloud.loadLibrary(workspaceID: id, account: account), previous.enabled else {
                throw CompanionLibraryError.disabled
            }
            let ready = previous.pending.filter { $0.ideaDraftPlatforms == nil && $0.mediaDraft == nil && (!$0.usesMacAgent || agentConnected) }
            var completed = try ready.map(applyCompanionLibraryChange)
            var completedMedia: CompanionLibrary.Change?
            if let request = previous.pending.first(where: { $0.mediaDraft != nil }) {
                do {
                    let data = try await cloud.loadLibraryMedia(request, workspaceID: id, account: account)
                    completed.append(await createMobileMediaDraft(request, data: data))
                    completedMedia = request
                } catch CompanionLibraryError.invalid {
                    completed.append(.init(id: request.id, error: "This attachment could not be read. Choose the file again on your device."))
                    completedMedia = request
                }
            }
            if let request = previous.pending.first(where: { $0.ideaDraftPlatforms != nil }) {
                completed.append(await draftMobileIdea(request))
            }
            if agentConnected { await generateMobileXDraft() }
            await publishPendingXArticles()
            scheduleChanged = zip(ready, completed).contains { $0.0.action == .scheduleDraft && $0.1.error == nil }
            try await publishCompanionLibrary(cloud, workspaceID: id, account: account,
                                              previous: previous, enabling: false, completed: completed)
            if let completedMedia {
                try await cloud.deleteLibraryMedia(completedMedia, workspaceID: id, account: account)
            }
        }
        if scheduleChanged { await syncCompanion() }
    }

    private func publishCompanionLibrary(_ cloud: CloudScheduleStore, workspaceID: UUID, account: String,
                                         previous: CompanionLibrary?, enabling: Bool,
                                         completed: [CompanionLibrary.Result]) async throws {
        var snapshot = makeCompanionLibrary(workspaceID: workspaceID)
        let data = try snapshot.separateFullText()
        let textChanged = snapshot.fullText != previous?.fullText
        if textChanged, let data, let version = snapshot.fullText {
            try await cloud.stageLibraryText(data, version: version, workspaceID: workspaceID, account: account)
        }
        _ = try await cloud.updateLibrary(workspaceID: workspaceID, account: account, create: enabling) { library in
            guard library.enabled || enabling else { throw CompanionLibraryError.disabled }
            library.enabled = true
            library.acknowledge(completed)
            updateLibrarySnapshot(&library, from: snapshot)
        }
        if textChanged || companionLibraryTextCleanupPending {
            companionLibraryTextCleanupPending = true
            try await cloud.pruneLibraryText(keeping: snapshot.fullText, workspaceID: workspaceID, account: account)
            companionLibraryTextCleanupPending = false
        }
    }

    private func withCompanionLibrarySync(
        _ operation: (CloudScheduleStore, UUID, String) async throws -> Void
    ) async {
        guard companionSharing, !companionBusy, !companionLibraryBusy else { return }
        companionLibraryBusy = true
        defer { companionLibraryBusy = false }
        do {
            try reload()
            try await operation(companionCloud(), companionWorkspaceID(), companionAccountKey())
            companionLibraryError = nil
        } catch {
            companionLibraryError = error.localizedDescription
        }
    }

    func makeCompanionLibrary(workspaceID: UUID) -> CompanionLibrary {
        var snapshot = CompanionLibrary(workspaceID: workspaceID)
        snapshot.supportsDraftEdits = true
        snapshot.supportsNewsletterEdits = true
        snapshot.supportsItemManagement = true
        snapshot.supportsXReplyArticles = true
        snapshot.supportsXThreads = true
        snapshot.supportsXParagraphs = true
        snapshot.supportsRevisionHistory = true
        snapshot.supportsXArticlePublishing = true
        snapshot.supportsLinkedInArticles = true
        if let account = try? socialAccounts.savedAccount(.x) {
            snapshot.xArticleAccountKey = account.connectionKey
            snapshot.xArticleAccountName = account.username.isEmpty ? account.name : "@" + account.username
        }
        snapshot.supportsWritingTools = true
        snapshot.supportsAgentFeatures = agentConnected
        snapshot.writingAgent = StudioWritingConnection(settings: settings) == .agent ? StudioChatAgent.selected.rawValue : WritingProviders(settings: settings).writingProvider.rawValue
        snapshot.supportsContentPlans = true
        snapshot.supportsClaudeIdeaDrafts = true
        snapshot.supportsMediaDrafts = true
        snapshot.postingWindows = Dictionary(uniqueKeysWithValues: SocialPlatform.allCases.filter { $0 != .tiktok }.map {
            ($0.rawValue, postingWindow(for: $0.rawValue))
        })
        snapshot.postingTimeZone = TimeZone.current.identifier
        snapshot.projects = Array(projects.sorted {
            ($0.id == projectID ? 0 : 1, $0.title, $0.id) < ($1.id == projectID ? 0 : 1, $1.title, $1.id)
        }.prefix(100)).map {
            .init(id: $0.id, name: String($0.title.prefix(100)))
        }
        let projectIDs = Set(snapshot.projects.map(\.id))
        let candidates = (records + trashedRecords).filter {
            projectIDs.contains($0.projectID) &&
                ($0.kind == "idea" || $0.kind == "draft" && !["posted", "posting"].contains($0.scheduleStatus))
        }.sorted { ($0["updatedAt"], $0.id) > ($1["updatedAt"], $1.id) }
        let trashIDs = Set(trashedRecords.map(\.id))
        let encoder = JSONEncoder()
        var bytes = 0
        for kind in [CompanionLibrary.Item.Kind.draft, .idea] {
          for inTrash in [false, true] {
            let rows = candidates.filter { $0.kind == kind.rawValue && trashIDs.contains($0.id) == inTrash }
            var selected: [String: CompanionLibrary.Item] = [:]
            var kindBytes = 0
            func add(_ record: WorkspaceRecord) {
                guard selected.count < 50, selected[record.id] == nil else { return }
                let applied = Set(record.appliedRevisionCommentIDs)
                let comments = record.comments.suffix(4).compactMap { comment -> (text: String, date: String, state: String?)? in
                    guard let text = comment["text"] as? String else { return nil }
                    let state = (comment["revisionRequestID"] as? String).map {
                        applied.contains($0) ? "applied" : record.acceptsRevisionComments ? "pending" : "waitingForDraft"
                    }
                    return (String(text.prefix(1000)), comment["at"] as? String ?? "", state)
                }
                let attachment: CompanionLibrary.Item.Attachment? =
                    record.fields["video"] is [String: Any] ? .video :
                    record.fields["image"] is [String: Any] ? .image : nil
                var item = CompanionLibrary.Item(
                    id: record.id, revision: record["updatedAt"], kind: kind, projectID: record.projectID,
                    title: record.title, body: record.body, shortened: false,
                    platform: record["platform"], status: record.scheduleStatus.isEmpty ? record["status"] : record.scheduleStatus,
                    notes: comments.map(\.text), noteDates: comments.map(\.date), attachment: attachment,
                    referenceID: record.referenceID
                )
                item.planMarkdown = record.fields["planMarkdown"] as? String
                item.previousPlanMarkdown = record.fields["previousPlanMarkdown"] as? String
                item.isTrashed = inTrash
                item.history = try? revisionHistory(for: record)
                if record.kind == "draft" {
                    item.format = record["format"]
                    if record.fields["mobileGenerationPending"] as? Bool == true {
                        item.generationStatus = record["generationError"].isEmpty ? "Waiting for your Mac to generate this draft." : record["generationError"]
                    }
                } else {
                    let writing = record.fields["mobileWritingVersions"] as? [String: String] ?? [:]
                    item.draftedIdeaPlatforms = Set(record.draftVersions.keys).union(writing.keys).sorted()
                }
                item.writingReply = record["notesReply"].isEmpty ? nil : record["notesReply"]
                item.writingError = record["writingRequestError"].isEmpty ? nil : record["writingRequestError"]
                if comments.contains(where: { $0.state != nil }) { item.noteStates = comments.map(\.state) }
                if record.fields["manualQuote"] as? Bool == true { item.requiresMacScheduling = true }
                guard let encoded = try? encoder.encode(item.indexEntry), kindBytes + encoded.count <= 52_000,
                      bytes + encoded.count <= 208_000 else { return }
                selected[record.id] = item
                kindBytes += encoded.count
                bytes += encoded.count
            }
            if kind == .draft, !inTrash {
                // Preserve a few video entries within the iCloud index budget.
                for record in rows where record.fields["video"] is [String: Any] {
                    add(record)
                    if selected.count == 3 { break }
                }
            }
            for record in rows {
                if selected.count == 50 { break }
                add(record)
            }
            snapshot.items.append(contentsOf: rows.compactMap { selected[$0.id] })
            snapshot.hasMore = snapshot.hasMore || selected.count < rows.count
          }
        }
        snapshot.hasMore = snapshot.hasMore || snapshot.projects.count < projects.count
        let longForm = records.filter { $0.isLongForm && projectIDs.contains($0.projectID) }
            .sorted { ($0["updatedAt"], $0.id) > ($1["updatedAt"], $1.id) }
        var longFormBytes = 0
        var indexed: [CompanionLibrary.Item] = []
        for record in longForm {
            var item = CompanionLibrary.Item(id: record.id, revision: record["updatedAt"],
                kind: CompanionLibrary.Item.Kind(rawValue: record.kind) ?? .newsletter,
                projectID: record.projectID, title: record.title, body: record.body,
                shortened: false, platform: ScheduleListing.channel(of: record),
                status: record["state"], notes: record.comments.suffix(4).compactMap { $0["text"] as? String },
                noteDates: record.comments.suffix(4).map { $0["at"] as? String ?? "" }, referenceID: record.referenceID)
            item.noteStates = record.comments.suffix(4).map { comment in
                guard let id = comment["revisionRequestID"] as? String else { return nil }
                return record.appliedRevisionCommentIDs.contains(id) ? "applied" : "pending"
            }
            item.writingError = record["writingRequestError"].isEmpty ? nil : record["writingRequestError"]
            item.writingReply = record["notesReply"].isEmpty ? nil : record["notesReply"]
            if record.kind == "article" {
                item.publicationStatus = record["articlePublicationStatus"]
                item.publicationURL = record["articleURL"]
                item.publicationError = record["articlePublicationError"]
            }
            item.planMarkdown = record.fields["planMarkdown"] as? String
            item.previousPlanMarkdown = record.fields["previousPlanMarkdown"] as? String
            item.history = try? revisionHistory(for: record)
            guard let data = try? encoder.encode(item.indexEntry), longFormBytes + data.count + 1 <= 260_000 else { continue }
            longFormBytes += data.count + 1
            indexed.append(item)
        }
        snapshot.newsletters = indexed.filter { $0.kind == .newsletter }
        snapshot.scripts = indexed.filter { $0.kind == .script }
        snapshot.articles = indexed.filter { $0.kind == .article }
        snapshot.supportsScripts = true
        snapshot.hasMoreNewsletters = indexed.count { $0.kind == .newsletter } < longForm.count { $0.kind == "newsletter" } ||
            records.contains { $0.kind == "newsletter" && !projectIDs.contains($0.projectID) }
        snapshot.hasMore = snapshot.hasMore || indexed.count < longForm.count
        return snapshot
    }

    private func updateLibrarySnapshot(_ library: inout CompanionLibrary, from snapshot: CompanionLibrary) {
        guard library.supportsContentPlans != snapshot.supportsContentPlans ||
              library.supportsDraftEdits != snapshot.supportsDraftEdits ||
              library.supportsNewsletterEdits != snapshot.supportsNewsletterEdits ||
              library.supportsItemManagement != snapshot.supportsItemManagement ||
              library.supportsXReplyArticles != snapshot.supportsXReplyArticles ||
              library.supportsXThreads != snapshot.supportsXThreads ||
              library.supportsXParagraphs != snapshot.supportsXParagraphs ||
              library.supportsClaudeIdeaDrafts != snapshot.supportsClaudeIdeaDrafts ||
              library.supportsMediaDrafts != snapshot.supportsMediaDrafts ||
              library.supportsRevisionHistory != snapshot.supportsRevisionHistory ||
              library.supportsXArticlePublishing != snapshot.supportsXArticlePublishing ||
              library.supportsLinkedInArticles != snapshot.supportsLinkedInArticles ||
              library.xArticleAccountKey != snapshot.xArticleAccountKey || library.xArticleAccountName != snapshot.xArticleAccountName ||
              library.supportsWritingTools != snapshot.supportsWritingTools || library.writingAgent != snapshot.writingAgent ||
              library.supportsAgentFeatures != snapshot.supportsAgentFeatures ||
              library.postingWindows != snapshot.postingWindows || library.postingTimeZone != snapshot.postingTimeZone ||
              library.projects != snapshot.projects || library.items != snapshot.items ||
              library.articles != snapshot.articles || library.scripts != snapshot.scripts || library.supportsScripts != snapshot.supportsScripts ||
              library.newsletters != snapshot.newsletters || library.hasMoreNewsletters != snapshot.hasMoreNewsletters ||
              library.hasMore != snapshot.hasMore || library.fullText != snapshot.fullText else { return }
        library.projects = snapshot.projects
        library.supportsDraftEdits = snapshot.supportsDraftEdits
        library.supportsNewsletterEdits = snapshot.supportsNewsletterEdits
        library.supportsItemManagement = snapshot.supportsItemManagement
        library.supportsXReplyArticles = snapshot.supportsXReplyArticles
        library.supportsXThreads = snapshot.supportsXThreads
        library.supportsXParagraphs = snapshot.supportsXParagraphs
        library.supportsClaudeIdeaDrafts = snapshot.supportsClaudeIdeaDrafts
        library.supportsMediaDrafts = snapshot.supportsMediaDrafts
        library.supportsRevisionHistory = snapshot.supportsRevisionHistory
        library.supportsXArticlePublishing = snapshot.supportsXArticlePublishing
        library.supportsLinkedInArticles = snapshot.supportsLinkedInArticles
        library.xArticleAccountKey = snapshot.xArticleAccountKey
        library.xArticleAccountName = snapshot.xArticleAccountName
        library.supportsWritingTools = snapshot.supportsWritingTools
        library.supportsAgentFeatures = snapshot.supportsAgentFeatures
        library.writingAgent = snapshot.writingAgent
        library.supportsContentPlans = snapshot.supportsContentPlans
        library.postingWindows = snapshot.postingWindows
        library.postingTimeZone = snapshot.postingTimeZone
        library.items = snapshot.items
        library.newsletters = snapshot.newsletters
        library.scripts = snapshot.scripts
        library.articles = snapshot.articles
        library.supportsScripts = snapshot.supportsScripts
        library.hasMoreNewsletters = snapshot.hasMoreNewsletters
        library.fullText = snapshot.fullText
        library.hasMore = snapshot.hasMore
        library.updatedAt = .now
    }

    func applyCompanionLibraryChange(_ change: CompanionLibrary.Change) throws -> CompanionLibrary.Result {
        try withChanges {
            let savedIDs = settings["companionLibraryApplied"] as? [String] ?? []
            let id = change.id.uuidString.lowercased()
            var newsletterRevisions = settings["companionNewsletterRevisions"] as? [String: String] ?? [:]
            if savedIDs.contains(id) { return .init(id: change.id, newsletterRevision: newsletterRevisions[id]) }
            guard change.valid, change.ideaDraftPlatforms == nil, change.mediaDraft == nil else {
                return .init(id: change.id, error: "Invalid mobile change.")
            }
            if let error = try applyLibraryAction(change, id: id) { return .init(id: change.id, error: error) }
            let retainedIDs = Array((savedIDs + [id]).suffix(160))
            if change.action == .editDraft || change.createsScript == true {
                let recordID = change.createsScript == true ? id : change.itemID
                newsletterRevisions[id] = records.first { $0.id == recordID }?["updatedAt"]
            }
            let retainedRevisions = newsletterRevisions.filter { retainedIDs.contains($0.key) }
            if change.action == .editDraft || change.createsScript == true || retainedRevisions != newsletterRevisions {
                try set("companionNewsletterRevisions", to: retainedRevisions)
            }
            try set("companionLibraryApplied", to: retainedIDs)
            return .init(id: change.id, newsletterRevision: retainedRevisions[id])
        }
    }

    private func applyLibraryAction(_ change: CompanionLibrary.Change, id: String) throws -> String? {
        if change.action == .saveRevision {
            guard let snapshot = change.historySnapshot,
                  let record = (records + trashedRecords).first(where: { $0.id == change.itemID }),
                  ["draft", "newsletter", "script", "article"].contains(record.kind) else { return nil }
            try retainRevision(snapshot, recordID: record.id)
            return nil
        }
        if change.publishesXArticle == true {
            try queueXArticlePublication(id: change.itemID, revision: change.revision,
                accountKey: change.xArticleAccountKey ?? "", requestID: id)
            return nil
        }
        if change.requestsWritingHelp == true {
            guard let record = records.first(where: { $0.id == change.itemID }), record.acceptsRevisionComments else {
                return "Choose an editable, unscheduled draft for this request."
            }
            try addComment(to: record, text: change.text, revisionRequestID: id)
            return nil
        }
        if change.contentOperation != nil { return try applyContentOperation(change, requestID: id) }
        if change.generatesXDraft == true {
            if (records + trashedRecords).contains(where: { $0.id == id }) ||
                (settings["libraryDeletedIDs"] as? [String] ?? []).contains(id) { return nil }
            let idea = records.first { $0.id == change.itemID && $0.kind == "idea" }
            let projectID = idea?.projectID ?? change.itemID
            guard projects.contains(where: { $0.id == projectID }),
                  let format = change.xFormat, XPostStyle(rawValue: format) != nil else {
                return "Choose an existing project and an X post type."
            }
            if let idea, idea["updatedAt"] != change.revision { return "This idea changed. Reopen it before generating." }
            var draft = WorkspaceRecord.new("draft", projectID: projectID)
            draft["id"] = id
            draft["title"] = change.title
            draft["brief"] = change.text
            draft["platform"] = "x"
            draft["format"] = format
            draft["ideaId"] = idea?.id ?? ""
            draft.fields["mobileGenerationPending"] = true
            try save(draft)
            return nil
        }
        if change.isLongFormEdit {
            guard var newsletter = records.first(where: { $0.kind == (change.editsScript == true ? change.writingKind ?? "script" : "newsletter") && $0.id == change.itemID }) else {
                return "This newsletter is no longer available."
            }
            guard ["draft", "synced"].contains(newsletter["state"]) else {
                return "This newsletter’s current publishing status prevents editing."
            }
            if change.restoresRevision == true {
                guard newsletter["updatedAt"] == change.revision else { return "This newsletter changed. Open its latest version before restoring." }
                newsletter["title"] = change.title
                if let subtitle = change.subtitle { newsletter["subtitle"] = subtitle }
            }
            var body = change.text
            if let base = change.baseNewsletterText {
                guard let merged = NewsletterMerge.merge(base: base, mac: newsletter.body, mobile: change.text) else {
                    return "Both devices edited the same part of this newsletter. Your mobile edit is still saved on this device."
                }
                body = merged
            } else if newsletter["updatedAt"] != change.revision && newsletter.body != change.text {
                return "This newsletter changed on your Mac before the edit could sync. Your mobile edit is still saved on this device."
            }
            if change.isLongFormEdit, let baseTitle = change.baseScriptTitle,
               baseTitle != change.title, newsletter.title != baseTitle, newsletter.title != change.title {
                return "Both devices changed the script title. Your mobile version is still saved on this device."
            }
            let changesTitle = change.isLongFormEdit && !change.title.isEmpty &&
                (change.baseScriptTitle == nil || change.baseScriptTitle != change.title)
            if newsletter.body != body || change.restoresRevision == true || changesTitle && change.title != newsletter.title {
                if changesTitle { newsletter["title"] = change.title }
                newsletter["body"] = body
                try save(newsletter)
            }
            return nil
        }
        if change.createsScript == true {
            guard projects.contains(where: { $0.id == change.itemID }) else { return "This project no longer exists on your Mac." }
            let linkedInArticle = change.writingKind == "linkedin-article"
            let recordKind = linkedInArticle ? "article" : change.writingKind ?? "script"
            if records.contains(where: { $0.id == id && $0.kind == recordKind }) { return nil }
            var script = WorkspaceRecord.new(recordKind, projectID: change.itemID)
            script["id"] = id
            script["title"] = change.title
            script["body"] = change.text
            if linkedInArticle {
                script["platform"] = "linkedin"
                script.fields["writingOnly"] = true
            }
            try save(script)
            return nil
        }
        if change.action == .addIdea {
            guard projects.contains(where: { $0.id == change.itemID }) else { return "This project no longer exists on your Mac." }
            if records.contains(where: { $0.id == id && $0.kind == "idea" }) { return nil }
            var idea = WorkspaceRecord.new("idea", projectID: change.itemID)
            idea["id"] = id
            idea["topic"] = change.title
            idea["text"] = change.text
            idea["origin"] = "Mobile"
            idea.fields["planMarkdown"] = change.initialPlan
            try save(idea)
            return nil
        }
        let active = records.first { $0.id == change.itemID && ["draft", "idea"].contains($0.kind) }
        let trashed = trashedRecords.first { $0.id == change.itemID && ["draft", "idea"].contains($0.kind) }
        let movesToTrash = change.action == .trashItem || change.action == .skipIdea
        if movesToTrash, trashed != nil { return nil }
        if change.action == .deleteItem, trashed == nil {
            if active != nil { return "Move this item to Trash again before deleting it." }
            if (settings["libraryDeletedIDs"] as? [String] ?? []).contains(change.itemID) { return nil }
        }
        let needsTrash = [.restoreItem, .restoreIdea, .deleteItem].contains(change.action)
        guard var record = needsTrash ? trashed : active else {
            return "This item is no longer available."
        }
        guard change.action == .note || record["updatedAt"] == change.revision else {
            return "This item changed since you opened it."
        }
        switch change.action {
        case .saveRevision: break
        case .scheduleDraft:
            guard record.kind == "draft", let hour = change.postingHour,
                  let platform = SocialPlatform(rawValue: record["platform"]),
                  platform != .tiktok, record.fields["manualQuote"] as? Bool != true else {
                return "Finish scheduling this post on your Mac."
            }
            guard !["queued", "due", "posting", "posted", "uncertain"].contains(record.scheduleStatus) else {
                return "Check the post’s current status in Schedule before scheduling it again."
            }
            do {
                let slot = try preferredPostingDate(for: platform.rawValue, hour: hour, minute: postingMinute(for: platform.rawValue))
                _ = try scheduleDraft(record, at: slot)
            } catch { return error.localizedDescription }
        case .trashItem:
            do { try trashLibraryItem(record) } catch { return error.localizedDescription }
        case .restoreItem:
            do { try restoreLibraryItem(record) } catch { return error.localizedDescription }
        case .deleteItem:
            do { try deleteLibraryItem(record) } catch { return error.localizedDescription }
        case .editIdea:
            guard record.kind == "idea", ["draft", "skipped"].contains(record["status"]) else {
                return "This idea already has drafts. Edit those posts instead."
            }
            record["topic"] = change.title
            record["text"] = change.text
            try save(record)
        case .note:
            if record.comments.contains(where: { $0["revisionRequestID"] as? String == id }) { return nil }
            guard record.comments.count < 100 else { return "This item already has 100 comments." }
            try addComment(to: record, text: change.text, revisionRequestID: record.kind == "draft" ? id : nil)
        case .skipIdea, .restoreIdea:
            let skipping = change.action == .skipIdea
            guard record.kind == "idea", record["status"] == (skipping ? "draft" : "skipped") else {
                return "This idea has already changed status."
            }
            if skipping {
                do { try trashLibraryItem(record) } catch { return error.localizedDescription }
                return nil
            }
            do { try restoreLibraryItem(record) } catch { return error.localizedDescription }
        case .editDraft:
            guard record.kind == "draft", !["posting", "posted", "uncertain"].contains(record.scheduleStatus) else {
                return "This draft can’t be edited while it’s publishing or published."
            }
            record["title"] = change.title
            record["content"] = change.text
            if let format = change.xFormat {
                guard record["platform"] == "x", record.fields["manualQuote"] as? Bool != true else {
                    return "Change this post’s format on your Mac."
                }
                record["format"] = format
            }
            try save(record)
        case .addIdea:
            break
        }
        return nil
    }

    func createMobileMediaDraft(_ change: CompanionLibrary.Change, data: Data) async -> CompanionLibrary.Result {
        do {
            try reload()
            let draftID = change.id.uuidString.lowercased()
            if (records + trashedRecords).contains(where: { $0.id == draftID }) ||
                (settings["libraryDeletedIDs"] as? [String] ?? []).contains(draftID) { return .init(id: change.id) }
            guard change.valid, let media = change.mediaDraft, data.count == media.byteCount,
                  CompanionLibrary.TextVersion(data: data) == media.version,
                  projects.contains(where: { $0.id == change.itemID }) else {
                throw WorkspaceError("Choose an existing project and a supported attachment.")
            }
            let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appending(path: media.fileName)
            try data.write(to: file, options: .atomic)
            var draft = WorkspaceRecord.new("draft", projectID: change.itemID)
            draft["id"] = draftID
            draft["title"] = "\(platformName(media.platform)) \(media.isVideo ? "video" : "post")"
            draft["platform"] = media.platform
            draft["format"] = media.isVideo ? "video" : "image"
            draft["content"] = change.text
            if media.isVideo { draft.setDraftMedia(try await attachVideo(file), as: .video) }
            else { draft.setDraftMedia(try attachImage(file), as: .image) }
            try save(draft)
            return .init(id: change.id)
        } catch {
            return .init(id: change.id, error: error.localizedDescription)
        }
    }

    func draftMobileIdea(_ change: CompanionLibrary.Change, model: ContentStudio.Model? = nil) async -> CompanionLibrary.Result {
        do {
            try reload()
            guard change.valid, let platforms = change.ideaDraftPlatforms else {
                throw WorkspaceError("Invalid post idea request.")
            }
            let requestID = change.id.uuidString.lowercased()
            if (records + trashedRecords).contains(where: {
                $0.id == change.itemID && ($0.fields["mobileIdeaDraftRequests"] as? [String])?.contains(requestID) == true
            }) { return .init(id: change.id) }
            guard let idea = records.first(where: { $0.id == change.itemID && $0.kind == "idea" && $0["status"] == "draft" }),
                  idea["updatedAt"] == change.revision else {
                throw WorkspaceError("This idea changed on your Mac. Reopen it before trying again.")
            }
            guard agentAccessEnabled else {
                throw WorkspaceError("Enable agent access in Inkspring → Settings → AI agents on your Mac, then try again.")
            }
            guard model != nil || StudioChatAgent.claude.executable != nil else {
                throw WorkspaceError("Install and sign in to Claude Code on your Mac, then try again.")
            }
            let claude = model ?? StudioChatAgent.claude.writingModel(workspace: self, providers: WritingProviders(settings: settings))
            _ = try await ContentStudio(workspace: self, model: claude)
                .pick(idea, platforms: platforms, xFormat: change.xFormat ?? "post", mobileRequestID: requestID)
            return .init(id: change.id)
        } catch {
            return .init(id: change.id, error: error.localizedDescription)
        }
    }

    func generateMobileXDraft(model: ContentStudio.Model? = nil) async {
        guard !runningMobileXGeneration else { return }
        runningMobileXGeneration = true
        defer { runningMobileXGeneration = false }
        do {
            try reload()
            guard let draft = records.first(where: {
                $0.kind == "draft" && $0.fields["mobileGenerationPending"] as? Bool == true && $0["generationError"].isEmpty
            }) else { return }
            do {
                _ = try await ContentStudio(workspace: self, model: model).compose(draft, withImage: false)
            } catch {
                try reload()
                if var current = records.first(where: { $0.id == draft.id && $0["updatedAt"] == draft["updatedAt"] }) {
                    current["generationError"] = "Your Mac couldn’t generate this draft. \(error.localizedDescription)"
                    try save(current)
                }
            }
        } catch { companionLibraryError = error.localizedDescription }
    }
}
