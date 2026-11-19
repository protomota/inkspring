import SwiftUI

struct ScheduleView: View {
    @Environment(\.studioPalette) private var palette
    let workspace: Workspace
    let open: (WorkspaceRecord) -> Void
    @Binding var focusDraftID: String?
    @Binding var tab: ScheduleListing.Section
    let revise: (WorkspaceRecord, @escaping (WorkspaceRecord) -> Void) -> Void
    let reviewPublication: (WorkspaceRecord, Date?, @escaping (WorkspaceRecord) -> Void) -> Void
    let chooseTime: (WorkspaceRecord, @escaping () -> Void) -> Void
    let reviewNewsletter: (WorkspaceRecord, Bool, @escaping (WorkspaceRecord) -> Void) -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var projectFilter: String?
    @State private var channelFilter: String?
    @State private var manuallyPosted: WorkspaceRecord?
    @State private var cancellingNewsletter: WorkspaceRecord?
    @State private var checkingNewsletter: WorkspaceRecord?
    @State private var returningIdea: Workspace.IdeaReturnPlan?
    @State private var generatingImages: Set<String> = []
    @State private var changingNotifications = false
    @State private var notificationsDenied = false
    @State private var notificationError: String?

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
                    postingControls
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
        .task(id: scenePhase) {
            if scenePhase == .active { notificationsDenied = await ScheduleNotifications.isDenied() }
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
        .confirmationDialog("Cancel the newsletter schedule?", isPresented: Binding(
            get: { cancellingNewsletter != nil }, set: { if !$0 { cancellingNewsletter = nil } }
        ), presenting: cancellingNewsletter) { item in
            Button("Cancel schedule", role: .destructive) {
                runNewsletterAction { try await Substack(workspace: workspace).cancel(item.id) }
            }
        } message: { _ in
            Text("The newsletter stays saved as a draft on Substack.")
        }
        .confirmationDialog("Did you check the outcome in Substack?", isPresented: Binding(
            get: { checkingNewsletter != nil }, set: { if !$0 { checkingNewsletter = nil } }
        ), presenting: checkingNewsletter) { item in
            Button("I checked Substack") {
                runNewsletterAction { try await Substack(workspace: workspace).acknowledge(item.id) }
            }
        } message: { _ in
            Text("Check your drafts, scheduled posts, and published posts before continuing.")
        }
    }

    private var postingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: {
                workspace.settings["autoPost"] as? Bool == true
            }, set: { enabled in
                workspace.perform { try workspace.set("autoPost", to: enabled) }
            })) {
                postingLabel("Automatic posting",
                             description: "Send eligible scheduled posts from your Mac at their chosen time. Keep it off to review and publish posts yourself.")
            }
            .toggleStyle(.switch)
            .accessibilityLabel("Automatic posting")
            StudioRule()
            Toggle(isOn: Binding(get: {
                workspace.settings[ScheduleNotifications.settingKey] as? Bool == true && !notificationsDenied
            }, set: changeScheduleNotifications)) {
                postingLabel("Schedule notifications",
                             description: "Get an alert when a scheduled post needs attention while automatic posting is on.")
            }
            .toggleStyle(.switch)
            .accessibilityLabel("Schedule notifications")
            .disabled(changingNotifications)
            if notificationsDenied {
                Text("macOS has notifications turned off for Inkspring.")
                    .font(.callout).foregroundStyle(palette.muted)
                Button("Open Notification Settings", systemImage: "gearshape") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        openURL(url)
                    }
                }
            }
            if let notificationError { Text(notificationError).foregroundStyle(palette.danger) }
        }
        .padding(14)
        .studioSurface()
    }

    private func postingLabel(_ title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(description)
                .font(.callout)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changeScheduleNotifications(_ enabled: Bool) {
        changingNotifications = true
        notificationError = nil
        Task {
            defer { changingNotifications = false }
            do { try await workspace.setScheduleNotifications(enabled) }
            catch {
                notificationsDenied = await ScheduleNotifications.isDenied()
                if !notificationsDenied { notificationError = error.localizedDescription }
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
                                Button("Review & publish…") { reviewPublication(draft, nil) { _ in tab = .history } }
                            }
                            Button("Record as posted…") { manuallyPosted = draft }
                            if draft.scheduleStatus != "skipped" {
                                Button("Rewrite with notes…") {
                                    revise(draft) { updated in
                                        if ScheduleListing.section(for: updated) == .ready { tab = .ready }
                                    }
                                }
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
                        chooseTime(draft) { tab = .scheduled }
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
        let state = item["state"]
        let editable = ["draft", "synced"].contains(state)
        let reschedulable = state == "scheduled"
        return VStack(alignment: .leading, spacing: 8) {
            RecordCard(record: item)
            HStack {
                Text(projectName(for: item)).foregroundStyle(.secondary)
                Text(newsletterStatus(item)).foregroundStyle(.secondary)
                if tab != .ready, let date = ScheduleListing.date(for: item, in: tab) {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer()
                Button(editable ? "Edit draft" : "View newsletter") { open(item) }
                StudioFilterMenu(title: "Newsletter actions", value: "Actions") {
                    if editable {
                        Button("Save to Substack") {
                            runNewsletterAction { try await Substack(workspace: workspace).sync(item.id) }
                        }
                        .disabled(Substack(workspace: workspace).selected == nil || item.body.isEmpty)
                        Button("Review & publish…") { beginNewsletterSend(item, scheduling: false) }
                    }
                    if reschedulable {
                        Button("Cancel schedule…") { cancellingNewsletter = item }
                    }
                    if !item["remoteId"].isEmpty {
                        Button("Check status") {
                            runNewsletterAction { try await Substack(workspace: workspace).refresh(item.id) }
                        }
                    }
                    if state == "uncertain" {
                        Button("Confirm Substack check…") { checkingNewsletter = item }
                    }
                    if let url = Substack.editorURL(item) {
                        StudioExternalLink("Open in Substack", destination: url)
                    }
                    Button("Copy text", systemImage: "doc.on.doc") { copy(item.body) }
                }
                .disabled(workspace.substackBusy)
                if editable || reschedulable {
                    Button("Choose a time…") { beginNewsletterSend(item, scheduling: true) }
                        .disabled(workspace.substackBusy)
                }
            }
        }
    }

    private func beginNewsletterSend(_ item: WorkspaceRecord, scheduling: Bool) {
        reviewNewsletter(item, scheduling) { saved in
            if let section = ScheduleListing.section(for: saved) { tab = section }
        }
    }

    private func runNewsletterAction(_ action: @escaping @MainActor () async throws -> WorkspaceRecord) {
        Task {
            do {
                let updated = try await action()
                if let section = ScheduleListing.section(for: updated) { tab = section }
            } catch {
                workspace.error = error.localizedDescription
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

struct ScheduleTimePage: View {
    let draft: WorkspaceRecord
    let workspace: Workspace
    let close: () -> Void
    let scheduled: () -> Void
    let reviewPublication: (WorkspaceRecord, Date?, @escaping (WorkspaceRecord) -> Void) -> Void
    @State private var postingTime = Date.now.addingTimeInterval(3600)
    @State private var chosenMinute = -1
    @State private var linkedInDestinations: [LinkedInDestination] = []
    @State private var chosenDestination = ""
    @State private var timeError: String?

    private var selectedLinkedInDestination: LinkedInDestination? {
        linkedInDestinations.first { $0.urn == chosenDestination }
    }

    private var openHours: [Date] {
        var proposed = draft
        if let destination = selectedLinkedInDestination { proposed.fields["linkedinDestination"] = destination.fields }
        return PostScheduling.proposedTimes(for: proposed, in: workspace.records, linkedInPersonalURN: linkedInDestinations.first?.urn,
                                            window: workspace.postingWindow(for: draft["platform"]))
    }

    var body: some View {
        StudioEditorPage(title: "Choose a posting time") {
            Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
            Button(draft["platform"] == "tiktok" ? "Review TikTok post…" : "Schedule", action: schedule)
                .modifier(PrimaryActionStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(draft["platform"] == "linkedin" && selectedLinkedInDestination == nil)
        } content: {
            StudioScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(draft.title).font(InkspringTypography.editorial(24))
                    if draft["platform"] == "linkedin" {
                        if linkedInDestinations.isEmpty {
                            Text("Connect LinkedIn in Connections before scheduling.").foregroundStyle(.secondary)
                        } else {
                            StudioLabeledChoice(title: "LinkedIn destination", selection: $chosenDestination,
                                                options: linkedInDestinations.map(\.urn),
                                                label: { urn in linkedInDestinations.first { $0.urn == urn }?.name ?? "Choose a destination" })
                        }
                    }
                    let slots = openHours
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
                }
                .frame(maxWidth: 920, alignment: .leading)
                .studioPage()
            }
        }
        .onAppear {
            if draft["platform"] == "linkedin" {
                linkedInDestinations = (try? workspace.socialAccounts.savedLinkedInDestinations()) ?? []
            }
            let saved = LinkedInDestination(fields: draft.fields["linkedinDestination"] as? [String: Any])
            chosenDestination = saved?.urn ?? linkedInDestinations.first?.urn ?? ""
            postingTime = (draft.schedule["slotAt"] as? String).flatMap(scheduleDate)
                .flatMap { $0 > .now ? $0 : nil } ?? openHours.first ?? Date.now.addingTimeInterval(3600)
            chosenMinute = workspace.postingMinute(for: draft["platform"])
        }
    }

    private func schedule() {
        do {
            let slot = try workspace.preferredPostingDate(for: draft["platform"], hour: postingTime, minute: chosenMinute)
            if draft["platform"] == "tiktok" {
                reviewPublication(draft, slot) { _ in scheduled() }
            } else {
                try workspace.scheduleDraft(draft, at: slot, linkedin: selectedLinkedInDestination)
                scheduled()
                close()
            }
        } catch { timeError = error.localizedDescription }
    }
}

struct ScheduledDraftRevision: View {
    @State var draft: WorkspaceRecord
    let workspace: Workspace
    let saved: (WorkspaceRecord) -> Void
    let close: () -> Void
    @State private var notes = ""
    @State private var request: String?
    @State private var error: String?

    var body: some View {
        StudioEditorPage(title: "Rewrite with notes") {
            Button("Done", action: close).keyboardShortcut(.cancelAction)
                .disabled(request != nil)
            if request != nil {
                ProgressView("Rewriting…").controlSize(.small)
            } else {
                Button("Rewrite draft") {
                    error = nil
                    request = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .modifier(PrimaryActionStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || notes.utf16.count > 4_000)
            }
        } content: {
            StudioScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(draft.title).font(.headline)
                    Text(draft.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .studioSurface()
                    if ["queued", "due"].contains(draft.scheduleStatus) {
                        Text("Changing the wording moves this post to Ready to schedule.").foregroundStyle(.secondary)
                    }
                    if !draft["notesReply"].isEmpty {
                        Text(draft["notesReply"]).foregroundStyle(.secondary)
                    }
                    DraftBodyField(text: $notes, label: "Revision notes", minHeight: 140)
                        .disabled(request != nil)
                    if let error { Text(error).foregroundStyle(.red) }
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
                }
                .frame(maxWidth: 920, alignment: .leading)
                .studioPage()
            }
        }
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
