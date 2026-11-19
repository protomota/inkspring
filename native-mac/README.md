# Inkspring for macOS

Inkspring for Mac is built with SwiftUI. It uses system Liquid Glass on macOS 26 and later, supports standard native controls on macOS 14 and 15, and opens a local SQLite workspace at `~/Library/Application Support/Inkspring Native`.

## Build and open

Run the following from the repository root on a Mac with Xcode installed.

```sh
native-mac/build-app.sh
open "/Volumes/Expand/Codex Media/Inkspring Native/Inkspring.app"
```

The build script accepts an absolute output directory as its first argument. For a disposable workspace, create a separate directory and open the app with `open -n -a <app-path> --env "INKSPRING_NATIVE_WORKSPACE=<workspace-path>"`.

For a Developer ID build, set `INKSPRING_MAC_SIGNING_IDENTITY` to the installed identity. The build uses Hardened Runtime and a secure signing timestamp. Set `INKSPRING_MAC_NOTARIZE=1` with `APPLE_API_KEY` (a private key file), `APPLE_API_KEY_ID`, and `APPLE_API_ISSUER` to submit the app bundle to Apple. The script staples the accepted ticket and verifies Gatekeeper before installing the build. Retrieve the notarization credentials from Bitwarden Secrets Manager.

For direct downloads with **Inkspring → Check for Updates…**, set `INKSPRING_UPDATE_FEED=https://inkspring.ai/updates/appcast.xml` and `INKSPRING_UPDATE_PUBLIC_KEY` to the public key returned by Sparkle’s `generate_keys --account com.protomota.inkspring.native -p`. Keep the private signing key in the signing Mac’s Keychain. For each release, increment `CFBundleVersion` (or set `INKSPRING_MAC_BUILD_NUMBER`) and notarize the app. Use `build/package-installer.py` to package the stapled app in the branded, signed and notarized DMG. Run Sparkle’s `generate_appcast --account com.protomota.inkspring.native --download-url-prefix https://inkspring.ai/updates/` in a directory containing the release DMG. Publish the signed XML and use that same DMG on the download page. Unsigned development builds leave the updater disabled.

## Back up and restore

1. Open **Settings → Storage & backups** or use the **File** menu.
2. Select **Export Backup…** and save a ZIP. It contains workspace records, local images and attached videos. API keys, OAuth sessions and background-service settings stay on this Mac.
3. Select **Import / Restore…**, choose a workspace backup ZIP, and review the record and media counts. Confirm to merge the backup. The review shows how many records the restore adds, replaces, and keeps. Inkspring keeps existing publishing history, protected drafts, and newsletters linked to Substack. Restored scheduled posts go back to **Ready to schedule**. Check remotely scheduled newsletters in Substack before sending again.

The same dialog accepts version 1 Inkspring JSON exports. Reattach images and videos after restoring an older JSON export.

Under **Daily backups**, choose a destination folder and turn on **Back up once a day**. **Choose iCloud Drive…** opens the iCloud Drive picker. Settings shows when iCloud confirms the upload of the latest ZIP, and Restore waits for an iCloud-only ZIP to download before opening it. Use **Back Up Now** to save an additional ZIP to the same folder. Inkspring checks for a backup on launch and periodically while open. The background item checks at 3 a.m. local time, on sign-in, and later in the day if a backup is still needed. Approve it in **System Settings → General → Login Items & Extensions** to keep backups running after you quit the app. The Mac must be signed in and able to access the chosen folder.

## Migrate a workspace

In **Settings → Storage & backups**, select **Import Workspace Folder…** and choose the source workspace folder. Review the record and attachment counts before importing into the open Mac workspace. The source stays available for recovery. Reconnect social accounts in the native app after importing.

The migration command snapshots the source database with SQLite, copies and checks its images and videos, and creates a new native workspace directory. The source stays available for recovery. The destination must be a new folder. The copy retains all records and pauses automation and agent access until the native app is configured.

```sh
"/Volumes/Expand/Codex Media/Inkspring Native/Inkspring.app/Contents/MacOS/Inkspring" \
  --stage-workspace "<absolute source workspace path>" "<new absolute native workspace path>"
```

## Connect an agent

Open **Settings → AI agents** and turn on **Let AI agents use Inkspring**. Claude Code can save a project connection from this screen. For Codex, use the command and argument shown in the Codex tab. The Swift executable speaks STDIO MCP and reads and writes the same SQLite database as the app. Vault reading and immediate X or LinkedIn posting each require their own permission. Suggestions wait for review in Settings.

For already-written social copy, use MCP **save_draft** with `project_id`, `platform`, `title`, and `content`. It saves the exact text locally without a model, API key, scheduling, or publication. Optional `request_key` prevents duplicate creation on identical retries. Use **edit_draft** with the last-read `expected_updated_at` for revisions. **write_post** also accepts `content` for local saving; use its `idea` argument only when requesting model generation through the configured writing connection. Keep LinkedIn URLs in the supplied body when desired.

**Ask my agent** opens a chat in the Mac app. Select a locally installed, signed-in Codex or Claude Code. Chat can read drafts, ideas, and newsletters in the open project and suggest wording. It cannot change drafts, schedule, or publish. The selected agent handles the model request using its existing sign-in.

Copy the ID shown on a post or newsletter, such as `PRO-001`, and give it to your agent. The Inkspring MCP tool `get_content` reads either kind by that ID. Posts and newsletters share a sequence within each project. IDs stay the same when you rename a project or edit an item. The iPhone companion shows the IDs after it syncs with an updated Mac.

Choose **Proofread** while editing a post or newsletter. Inkspring shows each suggested spelling, grammar, or punctuation correction and its reason. **Apply corrections** puts them into the editor. The Mac uses the selected Claude or Codex agent. On iPhone and iPad, Apple Intelligence runs the check on the device.

For X drafts, choose **Single post**, **Post with reply**, or **Thread** before generating. The opening and each follow-up have separate editors and character counts. On iPhone and iPad, open a follow-up to edit it, then return to the draft to add replies or save. **Draft for X** on an idea and **New X draft** queue generation on your Mac using its writing connection. Keep Inkspring open on the Mac for generation and publishing. Scheduling sends the entire thread in order, with each reply attached to the preceding post.

Paragraph breaks inside an X post are preserved. Newly edited threads use an explicit reply boundary instead of treating blank lines as extra tweets. Older blank-line-separated drafts remain readable. Keep Mac and mobile updated together for this format. Through MCP, use `save_x_thread` or pass `posts` to `edit_draft`, with one string per tweet. Each string can contain its own paragraphs. A three-part post uses the `thread` format.

Mobile keeps edits using the new reply format saved on the device until the Mac advertises `supportsXParagraphs`. It never sends this format to an older Mac parser. Revision-history delivery has its own compatibility flag and also waits for a compatible Mac.

**Revision history** retains saved post and newsletter versions, including agent edits and intermediate mobile saves. Inspect a version and choose **Restore this version** to create a new save without deleting later versions or publishing. Mobile history is saved locally while offline and delivered to the Mac separately from coalesced edits; full history returns through the existing chunked iCloud text transport. Workspace backups include revision history. Existing content gets an initial snapshot when opened in the updated Mac app, and the previous agent revision is recovered where available. Earlier overwritten versions cannot be recreated if no copy remains.

Agents can use `list_revisions`, `get_revision`, and `restore_revision` with a post or newsletter ID. Read the current item first and pass its `updatedAt` as `expected_updated_at` when restoring. This rejects stale restores.

To reuse credentials already in a secret manager, turn on **Let agents set API keys and R2 credentials** in **Settings → AI agents**. Ask an agent with local command access to retrieve the selected credentials from the secret manager, launch a local Inkspring `--mcp` session with them in its environment, and call the setup tool in that session. Keep the raw values out of chat, tool arguments, and saved MCP configuration files.

Use `INKSPRING_ANTHROPIC_API_KEY`, `INKSPRING_OPENAI_API_KEY`, `INKSPRING_GEMINI_API_KEY`, `INKSPRING_APIFY_API_KEY`, or `INKSPRING_X_BEARER_TOKEN` with `set_provider_key` and the corresponding provider ID. For `set_r2_credentials`, supply `INKSPRING_R2_ACCESS_KEY_ID` and `INKSPRING_R2_SECRET_ACCESS_KEY` in the environment and pass the account ID, bucket, and optional jurisdiction as tool arguments. The tools return save status. Existing credentials require `replace_existing: true` to change.

**Settings → AI models → Writing connection** defaults to **Connected agent (MCP)**. Inkspring sends a one-time request over local MCP to the selected Codex or Claude Code session. It uses that session for posts and replies, rewrites, idea generation and refill, newsletters, voice suggestions, research planning and analysis, vault-based suggestions, and image prompts. The same setting applies when an external agent calls Inkspring's generation tools. In **Provider API key** mode, these features use the selected Anthropic, OpenAI, or Gemini text model. An agent error surfaces in the app and requires an explicit change to use API writing.

Generating image files uses the OpenAI or Gemini image API. X post lookup and X research can use an X sign-in with read access or a configured X bearer token. Apify supplies Instagram and LinkedIn research and can supply X research. News search reads public Google News RSS. Reply monitoring, account analytics, publishing, and Substack delivery use their service connections. Cloudflare R2 uploads use the configured storage credentials.

Select **Test connection** to check that the local executable starts, lists its tools, and reads the workspace. In Claude Code, check **Connectors** in a local session. In Codex, run `/mcp` after saving the server settings to verify the client.

## Publish and schedule

Use **Connections** for shared Inkspring sign-in or to configure your own developer app. The app keeps social sessions and client secrets in Keychain.

Use **Settings → AI models → Test writing connection** to check the selected agent or API writing connection. In the writing studio, you can fetch the original X post for a reply, copy or save the attached image, and restore the wording from before a rewrite.

For an image post or reply, turn on **Create an image** before generating the draft. Inkspring saves the text first. If image generation fails, the text and any existing attachment stay saved.

In **Settings → Voice & projects**, paste examples or choose from drafts previously published in your workspace. **Suggest my voice** sends those examples to your writing provider and fills editable voice, interests, and style guidance. **Save profile** applies the edits to future writing. You can also choose a voice for one draft in the writing studio.

Open a draft in **Writing studio → Review & publish** to review the destination and content before sending. Publishing history records confirmed post IDs and links. A partial X thread can resume from its last confirmed post. A publish request with an uncertain result requires checking the platform before allowing another attempt.

**Schedule** offers open posting hours and a choice of exact or automatic minute. Use a post's actions to open publishing review, skip the post, or record a post you published yourself. Enable **Automatic posting** to send eligible posts while Inkspring is running, including with its window closed. The Mac must be awake. Instagram and Reddit wait for review. A scheduled TikTok post requires account-specific privacy and consent review before it can enter the queue.

The **Scheduled** tab opens across all projects and shows social posts and Substack newsletters in delivery order. Filter by project or channel to review part of the schedule. The totals above the filters cover the whole workspace.

Scheduled LinkedIn posts keep the selected personal profile or company page. If an account changes, review the destination and choose a new time. Interrupted sends appear in **Publishing history** for a check before retrying.

From a scheduled draft’s actions, choose **Return to ideas…** to reopen the idea. Review how many unposted drafts will be discarded before confirming. Inkspring keeps versions with publishing or reply history. You can also generate an image for eligible X and Instagram drafts. For ideas that cite an X post, **Create quote draft** saves an editable draft for manual posting. Use **Open quote in X…** in the writing studio or Schedule to open the X composer.

Configure **Cloudflare R2 for Instagram** in **Settings → Storage & backups** to upload private media and provide Instagram a temporary download link. R2 credentials stay in Keychain. You can also use an existing HTTPS media URL.

Sign in to **Substack** from **Settings → Connections**, then choose the publication. The newsletter editor saves Markdown locally, exports Markdown or HTML, syncs to Substack, and shows an explicit review before scheduling or publishing. Use **Write or refine with AI** to draft from a brief and up to six references from the selected project. Generation saves an editable draft. Substack owns the remote schedule and reports whether the send was scheduled, canceled, or published.

## Preview coverage

The preview includes the writing workspace, ZIP backup and restore, native MCP, public-source research and idea generation, Obsidian review, X replies, account analytics refresh, social sign-in, and publishing review for X, LinkedIn, Instagram, Reddit, and TikTok. Tests use synthetic provider responses. Live sign-in, publishing, research, and analytics are still unverified with personal accounts.

In **Research**, choose a source and find topics based on the selected project. Use **Write for** to choose a destination before opening a draft from an angle. For X results, **Reply to source** opens a reply draft with the original post attached. Search saved references by title or text and open a new draft from any reference.

**Refresh ideas** fills open queue slots with a mix of timely research, project work, and ideas based on measurements. Each generated idea needs a matching source. The refill can leave slots empty when the available sources do not support them. Automatic refill, when enabled, can refresh the research sources you selected in Settings.

Substack and R2 are verified against local fixtures.

Under **Settings → Ideas & sources → Idea source schedule**, review recent Git activity and local Claude Code and Codex recaps before saving selected summaries. To refresh automatically, choose project and Obsidian folders, set the interval, and enable the schedule for that project. Changing folders pauses the schedule. Automatic imports resume once enabled in the app.

## iPhone and iPad companion

Open [InkspringCompanion.xcodeproj](InkspringCompanion.xcodeproj) and run the **InkspringCompanion** scheme. The app shows scheduled posts and newsletters across projects, including the channel, local posting time and review status. Canceling a social post sends the exact schedule revision back to the Mac and keeps the draft. A send already claimed by the Mac cannot be canceled from iPhone. Substack newsletters are visible on iPhone and their delivery is managed in Substack or Inkspring on Mac.

Both builds must have CloudKit entitlements for `iCloud.com.protomota.inkspring` and use the same CloudKit environment and Apple Account. Associate the container with `com.protomota.inkspring.native` and `com.protomota.inkspring.iphone` in [Apple Developer Identifiers](https://developer.apple.com/account/resources/identifiers/list). A signed Mac build accepts a matching profile in `INKSPRING_MAC_ICLOUD_PROFILE` and an optional entitlement override in `INKSPRING_MAC_ICLOUD_ENTITLEMENTS`. The included Mac entitlement file targets the production environment. For development testing use profiles and entitlements for the development environment on both devices. Deploy the `InkspringSchedule` record type in [CloudKit Console](https://icloud.developer.apple.com/dashboard/) before a production rollout.

On Mac, choose **Settings → Storage & backups → iPhone and iPad** and turn on schedule sync. The schedule shares titles, project names, channels, times, and status. Inkspring checks iCloud for a cancellation before publishing a synced post. The companion can cancel a social post while the Mac is offline if the phone or tablet can reach iCloud.

Turn on **library sync** in the same panel to review recent drafts and ideas, edit unscheduled drafts, add review notes, and skip or restore ideas on mobile. Draft editing and attachment indicators require an updated Mac app. Notes save when you leave the field. Changes upload to private iCloud automatically and the Mac applies them on its next sync. Attachment indicators sync as text metadata. Media files, credentials, and backups stay where you configured them.

Use **New ideas** to write ideas manually or brainstorm with the on-device Apple Intelligence model on supported iPhone and iPad models running iOS or iPadOS 26 or later. Save the idea once and Inkspring syncs it to your project automatically. When iCloud is unavailable, Inkspring keeps the save and retries automatically while the app is open. Ideas saved in previous companion builds also join the sync queue.

After restoring a workspace on a new Mac, turn on schedule sync there and confirm **Use this Mac for mobile sync** if iCloud still lists the old workspace. Transfer pauses automatic posting on the receiving Mac and waits for any send already in progress. Review the restored drafts before scheduling them again.

## Writing formats and Find

**YouTube scripts** and **X articles** are separate writing-only formats. On Mac, each has a named sidebar section. On iPhone and iPad, choose **New → New YouTube script** or **New → New X article**, and use the **YouTube** or **X article** platform filter. X articles carry an explicit **X article** label so they cannot be confused with tweets or threads. Neither format enters the publishing queue.

Both formats keep the complete text, copyable project ID, Markdown preview, autosave, proofreading, revision history, and iCloud sync. Open the updated Mac app to exchange these formats with mobile. An older Mac cannot accept their edits; mobile retains them locally until a compatible Mac syncs.

While editing on mobile, the text uses the available content area and the metadata stays in the preview. **Done** returns to the preview. **Find** searches within the editor and jumps between matches. On Mac, use **Find** or Command-F in the writing editor. X replies edit in place with **Back to thread**, preserving the parent draft and autosaving changes.

MCP tools `list_scripts`, `get_script`, `save_script`, `list_articles`, `get_article`, and `save_article` read and save supplied text locally without an API key or a model call. Pass the last-read `expected_updated_at` when editing and a stable `request_key` when retrying creation. Scripts, articles, posts, and newsletters share each project's reference-ID sequence.
