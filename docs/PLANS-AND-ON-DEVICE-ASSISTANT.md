# Plans and Ask Inkspring

Implemented November 18 and reconciled with the current writing tools November 19, 2026. Release authorized by Brad on November 19.

## Use it

- Posts, ideas and newsletters have an optional **Plan**, separate from publishing copy and revision comments. In a post preview, Plan sits above Comments. Newsletter Source and Preview include the same section.
- Choose Create plan or Import Markdown, switch Preview/Markdown, and save with Save plan. Cancel intentionally discards the editing session. Draft recovery preserves text when the app is interrupted; a failed save keeps the draft open.
- New ideas and Writing Studio offer Include a plan. Ask Inkspring creation requests containing “with a plan” include a starter outline.
- Export writes a real UTF-8 `.md` file named from the copyable content ID. Imports copy the text into the content record, so the source file is not needed afterwards.
- Proofread uses on-device Apple Intelligence and preserves Markdown prefixes, links and fenced/indented code. A revision instruction generates a candidate. Review it, Apply to draft or Discard, then Save plan. Undo revision restores the prior editing draft; Restore previous plan restores the preceding saved version.
- Ask Inkspring is separate from Ask my agent. The former uses Apple Intelligence on this device; the latter keeps the existing connected-agent workflow. There is no automatic remote fallback.
- Examples: “Find my drafts”, “Read PRO-001”, “Rename PRO-001 to A clearer opening”, “Create an idea called Show the decision with a plan”, “Revise the plan for PRO-001 to add a testing checklist”. Use an exact replacement for direct title/body edits. Rewrites belong in the reviewed suggestion flow.
- Chat stores conversations locally, supports New chat/history selection and confirmed individual/all-history deletion. Deleting chats keeps writing and Plans. Mac chat history is included in workspace backup preferences.

## Save and sync behavior

Plans use stable internal content IDs and stay with records across moves, Trash/restore, restarts and ZIP backup/restore. The previous saved Plan remains in the record. User-facing IDs name exported files; renaming a project does not break the association.

Plan saves compare the exact previous document, so a comment or unrelated body edit does not falsely conflict. Concurrent Plan edits retain both versions for review. Mobile queues durable changes in the existing account/workspace-bound outbox and shows “saved on this device” / “waiting for your Mac”, never a false Mac-applied receipt. Conflicting mobile text stays available alongside the Mac Plan. An older Mac cannot receive new operations until it advertises supportsContentPlans.

The iCloud index omits large Plan text. Existing hashed, compressed full-text transport carries the current and previous documents. New optional fields preserve older snapshot decoding. Creation and update requests use the same idempotency/receipt path as existing mobile edits.

## AI boundary

Foundation Models guided generation proposes one typed operation. Application code validates explicit intent, limits, target identity and ambiguity before using Workspace/MobileLibrary APIs. Model prose is never treated as a mutation receipt. Exact replacement edits must appear in the user's request. Plan rewrites are proposals, requiring Apply before save. Cancellation is checked before executing an action.

The assistant has no SQL, shell, arbitrary file, credential or network-publishing tool. Publishing, scheduling, agent dispatch, deletion and spending stay in existing review controls. Saved content is untrusted model context. Unsupported actions return a clear explanation. Native Writing Tools remain available in text editors on supported systems.

On-device AI requires an eligible device with Apple Intelligence enabled and its model ready. Manual Plan editing/import/export remains available without it. Revision requests are bounded for the model context; proofreading uses small independent excerpts for long documents. Tests on a simulator do not establish real model execution; the real Mac Foundation Models test is separate.

## MCP

- `get_plan(content_id)` reads complete Markdown and the item's current timestamp.
- `save_plan(content_id, markdown, expected_markdown)` compares the exact old document and saves locally; it neither publishes nor dispatches an agent.
- `get_content` includes Plan fields. Connected agent rewriting receives the Plan as record context. The read-only in-app agent can read Plans only within its current project.

## Local builds and acceptance

Use `INKSPRING_MAC_CONFIGURATION=debug native-mac/build-app.sh '/Volumes/Expand/Codex Media/Inkspring Native/Plans and On-device Assistant/Local'` for a local test build. The script defaults to release for ordinary builds. Never put build output on the internal drive.

Review evidence and the separate sample workspace live under `/Volumes/Expand/Codex Media/Inkspring Native/Plans and On-device Assistant`. The sample app uses its own bundle ID and library. The public release includes these features after native, mobile and visual validation. Current tests cover complete backup restoration, document-level conflicts, full-text transport, wire capability gates, MCP scope, idempotency, ambiguity/injection checks and real Mac model execution. Physical two-device iCloud acceptance remains distinct from isolated sync-contract tests.
