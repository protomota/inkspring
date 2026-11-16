import SwiftUI

struct PublicationReview: View {
    @Environment(\.studioPalette) private var palette
    let draft: WorkspaceRecord
    let workspace: Workspace
    var scheduleAt: Date? = nil
    let completed: (WorkspaceRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var plan: SocialPublishPlan?
    @State private var message: String?
    @State private var publishing = false
    @State private var reviewing = false
    @State private var options = SocialPublishOptions()
    @State private var tiktok = TikTokReviewOptions()
    @State private var creator: TikTokCreator?
    @State private var r2: R2Configuration?

    private var needsOptions: Bool { ["instagram", "reddit", "tiktok"].contains(draft["platform"]) }
    private var isTikTokVideo: Bool { draft["format"] == "video" }


    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(scheduleAt == nil ? "Review & publish" : "Review & schedule").font(.title2)
            if let scheduleAt {
                Label(scheduleAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
            }
            if let plan {
                StudioPlatformLabel(name: plan.platform.rawValue, title: "\(plan.platform.name) · \(plan.accountName)")
                if let tiktok = plan.tiktok {
                    Text(TikTokCreator.privacyLabels[tiktok.privacy] ?? tiktok.privacy)
                        .font(.headline)
                    if tiktok.branded { Text("Branded content") }
                }
                if let subreddit = plan.subreddit { Text("r/" + subreddit).font(.headline) }
                if let hosting = plan.r2 {
                    Label("R2 bucket: " + hosting.bucket, systemImage: "externaldrive")
                }
                if let image = plan.publicImage { Text(image.absoluteString).lineLimit(2).textSelection(.enabled) }
                StudioScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let tiktok = plan.tiktok, !isTikTokVideo, !tiktok.title.isEmpty {
                            Text(tiktok.title).font(.headline)
                        }
                        ForEach(Array((plan.tiktok.map { [$0.caption] } ?? plan.posts).enumerated()), id: \.offset) { _, post in
                            Text(post).textSelection(.enabled)
                            if plan.posts.count > 1 { Divider() }
                        }
                        AttachedMedia(url: plan.image)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 350)
            } else if reviewing {
                ProgressView("Checking the connected account…")
            } else if needsOptions {
                if draft["platform"] == "instagram" {
                    if r2 != nil, workspace.mediaURL(draft) != nil {
                        Toggle("Host the attached image in my R2 bucket", isOn: $options.useR2)
                    }
                    if !options.useR2 {
                        TextField("Public HTTPS JPEG URL", text: $options.imageURL)
                            .studioInput()
                    }
                } else if draft["platform"] == "tiktok" {
                    if let creator {
                        StudioScrollView { tikTokFields(creator) }
                            .frame(maxHeight: 440)
                    } else if message == nil {
                        ProgressView("Loading TikTok posting options…")
                    }
                } else {
                    TextField("Subreddit (r/example)", text: $options.subreddit)
                        .studioInput()
                    TextField("Flair ID (optional)", text: $options.flair)
                        .studioInput()
                }
            }
            if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Close", role: .cancel) { dismiss() }.disabled(publishing)
                Spacer()
                if publishing { ProgressView().controlSize(.small) }
                if let plan {
                    Button(scheduleAt == nil ? "Publish on \(plan.platform.name)" : "Schedule TikTok post") {
                        Task { await publish(plan) }
                    }
                        .modifier(PrimaryActionStyle())
                        .disabled(publishing || message != nil)
                } else if needsOptions {
                    Button("Review") { Task { await review() } }
                        .disabled(reviewing || draft["platform"] == "tiktok" && (creator == nil || !tiktok.consent))
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .studioAppearance(palette)
        .interactiveDismissDisabled(publishing)
        .task {
            if draft["platform"] == "instagram" {
                r2 = try? R2Profile.saved()?.configuration
            } else if draft["platform"] == "tiktok" {
                tiktok.title = String(draft.title.prefix(90))
                tiktok.caption = draft.body
                do { creator = try await SocialPublisher(workspace: workspace).tikTokCreator() }
                catch { message = error.localizedDescription }
            } else if !needsOptions {
                await review()
            }
        }
    }

    private func tikTokFields(_ creator: TikTokCreator) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(creator.name, systemImage: "person.crop.circle")
            AttachedMedia(url: workspace.mediaURL(draft))
            if !isTikTokVideo {
                TextField("Photo title", text: $tiktok.title).studioInput()
                if !creator.usesManagedMedia {
                    TextField("Image URL on your verified domain", text: $options.imageURL)
                        .studioInput()
                }
            }
            TextField("Caption", text: $tiktok.caption, axis: .vertical)
                .studioInput()
                .lineLimit(2...5)
            StudioLabeledChoice(title: "Who can see this post?", selection: $tiktok.privacy,
                                options: [""] + creator.privacy,
                                label: { $0.isEmpty ? "Choose privacy" : TikTokCreator.privacyLabels[$0] ?? $0 })
            Toggle("Allow comments", isOn: $tiktok.comment).disabled(creator.commentDisabled)
            if isTikTokVideo {
                Toggle("Allow Duet", isOn: $tiktok.duet).disabled(creator.duetDisabled)
                Toggle("Allow Stitch", isOn: $tiktok.stitch).disabled(creator.stitchDisabled)
                Toggle("AI-generated content", isOn: $tiktok.aiGenerated)
            }
            Toggle("Promotes my own brand", isOn: $tiktok.yourBrand)
            Toggle("Branded content", isOn: $tiktok.branded)
            Toggle("I agree to TikTok’s Music Usage Confirmation", isOn: $tiktok.consent)
            HStack {
                StudioExternalLink("Music Usage Confirmation", destination: URL(string: "https://www.tiktok.com/legal/page/global/music-usage-confirmation/en")!)
                if tiktok.branded {
                    StudioExternalLink("Branded Content Policy", destination: URL(string: "https://www.tiktok.com/legal/page/global/bc-policy/en")!)
                }
            }
        }
    }

    private func review() async {
        guard !reviewing else { return }
        reviewing = true
        message = nil
        defer { reviewing = false }
        if draft["platform"] == "tiktok" { options.tiktok = tiktok }
        do { plan = try await SocialPublisher(workspace: workspace).review(draft, options: options) }
        catch { message = error.localizedDescription }
    }

    private func publish(_ plan: SocialPublishPlan) async {
        guard !publishing else { return }
        publishing = true
        defer { publishing = false }
        do {
            if let scheduleAt {
                let scheduled = try workspace.scheduleDraft(draft, at: scheduleAt, tiktok: plan)
                workspace.notice = "TikTok post scheduled"
                completed(scheduled)
                dismiss()
                return
            }
            let receipt = try await SocialPublisher(workspace: workspace).publish(plan)
            workspace.notice = "Published on \(plan.platform.name)"
            completed(receipt)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
