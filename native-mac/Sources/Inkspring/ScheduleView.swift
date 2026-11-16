import SwiftUI

struct ScheduleView: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let open: (WorkspaceRecord) -> Void
    @Binding var focusDraftID: String?
    @Environment(\.openURL) private var openURL
    @State private var tab = ScheduleListing.Section.scheduled
    @State private var projectFilter: String?
    @State private var channelFilter: String?
    @State private var selected: WorkspaceRecord?
    @State private var publishing: WorkspaceRecord?
    @State private var revising: WorkspaceRecord?
    @State private var manuallyPosted: WorkspaceRecord?
    @State private var postingTime = Date.now.addingTimeInterval(3600)
    @State private var chosenMinute = -1
    @State private var linkedInDestinations: [LinkedInDestination] = []
    @State private var chosenDestination = ""
    @State private var tiktokReviewSlot: Date?
    @State private var timeError: String?
    @State private var returningIdea: Workspace.IdeaReturnPlan?
    @State private var generatingImages: Set<String> = []
    @State private var changingNotifications = false

    var body: some View {
        let listing = ScheduleListing(records: workspace.records, projectID: projectFilter, channel: channelFilter)
        let rows = listing[tab]
        let totals = projectFilter == nil && channelFilter == nil ? listing : ScheduleListing(records: workspace.records)
        ScrollViewReader { proxy in
            StudioScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        PageHeading(title: "Choose when it goes out.",
                                    subtitle: "Review drafts and choose when to send them.")
                        Spacer()
                    }
                    HStack(spacing: 18) {
                        Toggle("Automatic posting", isOn: Binding(get: {
                            workspace.settings["autoPost"] as? Bool == true
                        }, set: { enabled in
                            workspace.perform { try workspace.set("autoPost", to: enabled) }
                        }))
                        Toggle("Schedule notifications", isOn: Binding(get: {
                            workspace.settings[ScheduleNotifications.settingKey] as? Bool == true
                        }, set: { enabled in
                            changingNotifications = true
                            Task {
                                await workspace.setScheduleNotifications(enabled)
                                changingNotifications = false
                            }
                        }))
                        .disabled(changingNotifications)
                        .help("Alert when a scheduled post needs review while automatic posting is on.")
                    }
                    Label("\(totals[.scheduled].count) scheduled · \(totals[.ready].count) ready across all projects",
                          systemImage: "calendar")
                        .font(InkspringTypography.interface(13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .studioSurface()
                    HStack(spacing: 10) {
                        let projectName = workspace.projects.first { $0.id == projectFilter }?.title
                        StudioFilterMenu(title: "Filter by project", value: projectName ?? "All projects") {
                            Picker("Projects", selection: $projectFilter) {
                                Text("All projects").tag(nil as String?)
                                ForEach(workspace.projects) { project in Text(project.title).tag(Optional(project.id)) }
                            }
                            .pickerStyle(.inline)
                        }
                        StudioChoicePicker(title: "Filter by channel", selection: $channelFilter,
                                           options: [nil] + SocialPlatform.allCases.map { Optional($0.rawValue) } + ["substack"],
                                           label: { $0.map(platformName) ?? "All channels" },
                                           icon: { $0.flatMap(PlatformMark.image) })
                    }
                    StudioTabs(selection: $tab, tabs: ScheduleListing.Section.allCases, label: { $0.rawValue },
                               count: { listing[$0].count })
                    if rows.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "calendar")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(palette.muted)
                                .accessibilityHidden(true)
                            Text(emptyMessage)
                                .font(InkspringTypography.editorial(21))
                            if tab == .scheduled && !listing[.ready].isEmpty {
                                Button("See drafts ready to schedule") { tab = .ready }
                                    .padding(.top, 4)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 144)
                        .studioSurface()
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, draft in
                        let day = scheduledDay(draft)
                        if tab == .scheduled, index == 0 || day != scheduledDay(rows[index - 1]) {
                            Text(day?.formatted(date: .complete, time: .omitted) ?? "Time unavailable").font(.headline)
                        }
                        if draft.kind == "newsletter" {
                            newsletterCard(draft).id(draft.id)
                        } else {
                            draftCard(draft).id(draft.id)
                        }
                    }
                    if tab == .scheduled, channelFilter == nil || channelFilter == "x" {
                        XPostingHours(records: workspace.records)
                    }
                }
                .studioPage()
            }
            .task(id: focusDraftID) {
                guard let id = focusDraftID,
                      let draft = workspace.records.first(where: { $0.kind == "draft" && $0.id == id }),
                      let section = ScheduleListing.section(for: draft) else { return }
                projectFilter = draft.projectID
                channelFilter = nil
                tab = section
                await Task.yield()
                proxy.scrollTo(id, anchor: .top)
                focusDraftID = nil
            }
        }
        .sheet(item: $publishing) { draft in
            PublicationReview(draft: draft, workspace: workspace) { _ in
                publishing = nil
                tab = .history
            }
        }
        .sheet(item: $revising) { draft in
            ScheduledDraftRevision(draft: draft, workspace: workspace) { updated in
                if ScheduleListing.section(for: updated) == .ready { tab = .ready }
            }
        }
        .confirmationDialog("Record this post as published?", isPresented: Binding(
            get: { manuallyPosted != nil }, set: { if !$0 { manuallyPosted = nil } }
        ), presenting: manuallyPosted) { draft in
            Button("Record as posted") {
                workspace.perform {
                    try update(draft, status: "posted")
                    tab = .history
                }
            }
        } message: { draft in
            Text("Use this for “\(draft.title)” after you’ve published it yourself.")
        }
        .confirmationDialog("Return this idea to the queue?", isPresented: Binding(
            get: { returningIdea != nil }, set: { if !$0 { returningIdea = nil } }
        ), presenting: returningIdea) { plan in
            Button("Reopen idea") {
                workspace.perform { try workspace.returnToIdeas(plan) }
            }
        } message: { plan in
            Text("“\(plan.ideaTitle)” will appear in Open. Its drafts and publishing history stay saved.")
        }
        .sheet(item: $selected, onDismiss: { tiktokReviewSlot = nil }) { draft in
            if let slot = tiktokReviewSlot {
                PublicationReview(draft: draft, workspace: workspace, scheduleAt: slot) { _ in
                    selected = nil
                    tab = .scheduled
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Schedule \(draft.title)").font(.title2)
                    if draft["platform"] == "linkedin" {
                        if linkedInDestinations.isEmpty {
                            Text("Connect LinkedIn in Connections before scheduling.").foregroundStyle(.secondary)
                        } else {
                            StudioLabeledChoice(title: "LinkedIn destination", selection: $chosenDestination,
                                                options: linkedInDestinations.map(\.urn),
                                                label: { urn in linkedInDestinations.first(where: { $0.urn == urn })?.name ?? "Choose a destination" })
                        }
                    }
                    let slots = openHours(for: draft)
                    if !slots.isEmpty {
                        StudioFilterMenu(title: "Open posting hours", value: "Open posting hours") {
                            ForEach(slots, id: \.self) { slot in
                                Button(slot.formatted(date: .abbreviated, time: .shortened)) { postingTime = slot }
                            }
                        }
                    }
                    StudioDateTimePicker(selection: $postingTime, includesMinute: false)
                    StudioLabeledChoice(title: "Posting minute", selection: $chosenMinute, options: Array(-1..<60),
                                        label: { $0 < 0 ? "Choose automatically" : String(format: "%02d", $0) })
                    if let timeError { Text(timeError).foregroundStyle(.red) }
                    HStack {
                        Button("Cancel") { selected = nil }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button(draft["platform"] == "tiktok" ? "Review TikTok post…" : "Schedule") {
                            do {
                                let slot = try workspace.preferredPostingDate(for: draft["platform"], hour: postingTime, minute: chosenMinute)
                                if draft["platform"] == "tiktok" {
                                    tiktokReviewSlot = slot
                                } else {
                                    try workspace.scheduleDraft(draft, at: slot, linkedin: selectedLinkedInDestination)
                                    selected = nil
                                    tab = .scheduled
                                }
                            } catch { timeError = error.localizedDescription }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft["platform"] == "linkedin" && selectedLinkedInDestination == nil)
                    }
                }
                .padding(25)
                .frame(width: 420)
                .studioAppearance(palette)
            }
        }
    }

    private func draftCard(_ draft: WorkspaceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RecordCard(record: draft)
            HStack {
                Text(projectName(for: draft)).foregroundStyle(.secondary)
                if let date = ScheduleListing.date(for: draft, in: tab), tab != .ready {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                if draft.scheduleStatus == "due" { Text("Ready for review").foregroundStyle(.secondary) }
                if draft.scheduleStatus == "posting" { Text("Sending").foregroundStyle(.secondary) }
                if draft.scheduleStatus == "manual" { Text("Posting by hand").foregroundStyle(.secondary) }
                if let destination = LinkedInDestination(fields: draft.fields["linkedinDestination"] as? [String: Any]) {
                    Text(destination.name).foregroundStyle(.secondary)
                }
                if let error = draft.schedule["error"] as? String, !error.isEmpty {
                    Text(error).foregroundStyle(.secondary)
                }
                if !draft["mediaError"].isEmpty {
                    Text(draft["mediaError"]).foregroundStyle(.secondary)
                }
                Spacer()
                if generatingImages.contains(draft.id) { ProgressView().controlSize(.small) }
                if let address = draft.schedule["url"] as? String, let url = URL(string: address),
                   url.scheme == "https", url.host != nil, url.user == nil, url.password == nil {
                    StudioExternalLink("Open post", destination: url)
                }
                if workspace.quoteComposerURL(for: draft) != nil {
                    Button {
                        workspace.perform { openURL(try workspace.prepareManualQuote(draft)) }
                    } label: {
                        StudioLinkOutLabel { Text("Open quote in X…") }
                    }
                }
                if !["posting", "posted"].contains(draft.scheduleStatus) {
                    Button("Edit draft") { open(draft) }
                    StudioFilterMenu(title: "Post actions", value: "Actions") {
                        if !draft.body.isEmpty {
                            if draft.fields["manualQuote"] as? Bool != true {
                                Button("Review & publish…") { publishing = draft }
                            }
                            Button("Record as posted…") { manuallyPosted = draft }
                            if draft.scheduleStatus != "skipped" {
                                Button("Rewrite with notes…") { revising = draft }
                            }
                        }
                        if ["ready", "removed", "failed", "manual", "queued", "due"].contains(draft.scheduleStatus) {
                            Button("Skip post") { workspace.perform { try update(draft, status: "skipped") } }
                        }
                        if ["x", "instagram"].contains(draft["platform"]),
                           !draft["mediaPlan"].isEmpty || !draft["mediaError"].isEmpty ||
                            draft["platform"] == "instagram" && draft.fields["image"] == nil {
                            Button(draft["mediaError"].isEmpty ? "Generate image" : "Retry image") {
                                Task { await generateImage(draft) }
                            }
                            .disabled(generatingImages.contains(draft.id))
                        }
                        if workspace.records.contains(where: { $0.id == draft["ideaId"] && $0["status"] == "picked" }) {
                            Button("Reopen source idea…") {
                                workspace.perform { returningIdea = try workspace.reviewIdeaReturn(for: draft) }
                            }
                        }
                    }
                }
                if draft.fields["manualQuote"] as? Bool != true,
                   ["queued", "due", "skipped", "manual"].contains(draft.scheduleStatus) {
                    Button("Move to ready") {
                        workspace.perform { try update(draft, status: "ready") }
                    }
                }
                if ["ready", "queued", "failed", "removed"].contains(draft.scheduleStatus),
                   draft.fields["manualQuote"] as? Bool != true {
                    Button("Choose a time…") {
                        chooseTime(for: draft)
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        switch tab {
        case .scheduled: "Nothing scheduled"
        case .ready: "Nothing ready to schedule"
        case .history: "No publishing history"
        }
    }

    private func projectName(for record: WorkspaceRecord) -> String {
        workspace.projects.first { $0.id == record.projectID }?.title ?? "Inkspring"
    }

    private func scheduledDay(_ record: WorkspaceRecord) -> Date? {
        ScheduleListing.date(for: record, in: .scheduled).map { Calendar.current.startOfDay(for: $0) }
    }

    private func newsletterCard(_ item: WorkspaceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RecordCard(record: item)
            HStack {
                Text(projectName(for: item)).foregroundStyle(.secondary)
                Text(newsletterStatus(item)).foregroundStyle(.secondary)
                if tab != .ready, let date = ScheduleListing.date(for: item, in: tab) {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer()
                Button("Open newsletter") { open(item) }
            }
        }
    }

    private func newsletterStatus(_ item: WorkspaceRecord) -> String {
        switch item["state"] {
        case "scheduled": "Scheduled on Substack"
        case "releasing": "Awaiting Substack confirmation"
        case "uncertain": "Check Substack"
        case "synced": "Saved to Substack"
        case "published": "Published on Substack"
        default: "Newsletter draft"
        }
    }

    private var selectedLinkedInDestination: LinkedInDestination? {
        linkedInDestinations.first { $0.urn == chosenDestination }
    }

    private func chooseTime(for draft: WorkspaceRecord) {
        linkedInDestinations = draft["platform"] == "linkedin" ? (try? workspace.socialAccounts.savedLinkedInDestinations()) ?? [] : []
        let saved = LinkedInDestination(fields: draft.fields["linkedinDestination"] as? [String: Any])
        chosenDestination = saved?.urn ?? linkedInDestinations.first?.urn ?? ""
        postingTime = (draft.schedule["slotAt"] as? String).flatMap(scheduleDate)
            .flatMap { $0 > .now ? $0 : nil } ?? openHours(for: draft).first ?? Date.now.addingTimeInterval(3600)
        chosenMinute = workspace.postingMinute(for: draft["platform"])
        timeError = nil
        selected = draft
    }

    private func openHours(for draft: WorkspaceRecord) -> [Date] {
        var proposed = draft
        if let destination = selectedLinkedInDestination { proposed.fields["linkedinDestination"] = destination.fields }
        return PostScheduling.proposedTimes(for: proposed, in: workspace.records, linkedInPersonalURN: linkedInDestinations.first?.urn,
                                            window: workspace.postingWindow(for: draft["platform"]))
    }

    private func generateImage(_ draft: WorkspaceRecord) async {
        guard generatingImages.insert(draft.id).inserted else { return }
        defer { generatingImages.remove(draft.id) }
        do {
            _ = try await ContentStudio(workspace: workspace).makeImage(for: draft, prompt: draft["imagePrompt"])
        } catch { workspace.error = error.localizedDescription }
    }

    private func update(_ draft: WorkspaceRecord, status: String) throws {
        var draft = draft
        var schedule = draft.schedule
        if status == "posted" {
            schedule["postedAt"] = WorkspaceRecord.timestamp
        } else {
            schedule["slotAt"] = ""
            schedule["skippedAt"] = status == "skipped" ? WorkspaceRecord.timestamp : ""
        }
        schedule["status"] = status
        schedule["error"] = ""
        draft.fields["schedule"] = schedule
        try workspace.save(draft)
    }
}

private struct ScheduledDraftRevision: View {
    @State var draft: WorkspaceRecord
    let workspace: Workspace
    let saved: (WorkspaceRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var request: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rewrite with notes").font(.title2)
            Text(draft.title).font(.headline)
            StudioScrollView {
                Text(draft.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            if ["queued", "due"].contains(draft.scheduleStatus) {
                Text("Changing the wording moves this post to Ready to schedule.").foregroundStyle(.secondary)
            }
            if !draft["notesReply"].isEmpty {
                Text(draft["notesReply"]).foregroundStyle(.secondary)
            }
            TextField("Revision notes", text: $notes, axis: .vertical)
                .lineLimit(3...6)
                .studioInput()
                .disabled(request != nil)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if !draft["previousContent"].isEmpty {
                    Button("Restore earlier wording") {
                        do {
                            draft = try ContentStudio(workspace: workspace).undoRewrite(draft)
                            error = nil
                            saved(draft)
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(request != nil)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if request != nil {
                    ProgressView("Rewriting…").controlSize(.small)
                } else {
                    Button("Rewrite draft") {
                        error = nil
                        request = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || notes.utf16.count > 4_000)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .task(id: request) {
            guard let request else { return }
            defer { self.request = nil }
            do {
                draft = try await ContentStudio(workspace: workspace).rewrite(draft, notes: request)
                notes = ""
                saved(draft)
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct XPostingHours: View {
    let records: [WorkspaceRecord]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let calendar = Calendar.current
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("X posting hours").font(InkspringTypography.editorial(21))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("All projects").font(.caption).foregroundStyle(.secondary)
                }
                StudioRule()
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        days(from: context.date, calendar: calendar, axis: .vertical)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        days(from: context.date, calendar: calendar, axis: .horizontal)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioSurface()
        }
    }

    @ViewBuilder private func days(from now: Date, calendar: Calendar, axis: Axis) -> some View {
        day("Today", date: now, now: now, calendar: calendar)
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
            StudioRule(axis: axis)
                .frame(height: axis == .vertical ? 177 : nil)
            day("Tomorrow", date: tomorrow, now: now, calendar: calendar)
        }
    }

    private func day(_ title: String, date: Date, now: Date, calendar: Calendar) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(date.formatted(.dateTime.month(.abbreviated).day())).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(PostScheduling.xPostingHours(on: date, in: records, calendar: calendar)) { hour in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(hour.start, format: .dateTime.hour())
                        .monospacedDigit().frame(minWidth: 52, alignment: .leading)
                    if let post = hour.post {
                        Label(post.body.isEmpty ? post.title : post.body,
                              systemImage: post.scheduleStatus == "posted" ? "checkmark.circle" : "clock")
                            .lineLimit(1)
                    } else {
                        Text(hour.end <= now ? "Nothing posted" : "Open").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
    }
}

func scheduleDate(_ value: String) -> Date? {
    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
        ?? (try? Date.ISO8601FormatStyle().parse(value))
}
