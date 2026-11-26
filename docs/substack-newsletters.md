# Substack newsletters

Newsletters is a separate long-form workspace in the desktop sidebar. Each project keeps its own newsletters. The editor has Markdown source, a split view and a reader preview. Fenced and indented code blocks preserve text, indentation and line breaks, with a language label when supplied. Inline code, headings, nested lists, bold, italic, strikethrough, quotes, rules and HTTPS links are supported. Raw HTML is treated as text. Standalone Markdown images become Substack image blocks; the local preview shows remote images as links. An attached local cover uploads directly to Substack; no R2 bucket is required.

Original Markdown is stored in the local SQLite workspace and included in workspace backup ZIPs. Import/export Markdown files, or export a formatted HTML article. Substack controls its final typography and code presentation.

## Connect

1. Open **Connections → Substack newsletters → Sign in to Substack**. The destination is https://substack.com/sign-in . Sign in yourself, including any email code or verification.
2. If sign-in has not completed the connection, choose **Check connection**.
3. Choose the intended publication from **Publication**. Inkspring lists publications the account can edit and does not silently select the first one.

This is an unofficial connection to Substack's web interface, not a supported public publishing API. It can need maintenance or reconnection when that interface changes. API requests go only to substack.com or its publication subdomains, including for publications with custom domains. Sign-in uses an isolated local browser session. Cookies are never exposed to the writing renderer or MCP and are excluded from workspace backups. Disconnect clears that browser session.

## Write and send

1. Write or import Markdown in **Newsletters**. Optionally select references and use your configured writing provider to generate/refine a draft. This uses provider credits and shares the displayed brief, saved draft, approved project/voice context and selected references.
2. Choose everyone, paid subscribers or founding members, and whether to email subscribers or publish on the web only. Attach a cover if desired.
3. **Save local draft** keeps it on this computer. **Save to Substack** creates/updates a remote draft and verifies its returned content. It does not publish or email anything.
4. Choose **Schedule a time** or **Publish now**. Time is shown in your computer's time zone. The default uses an uneven minute; any exact minute, including :00, is allowed. Substack permits scheduling within three months.
5. Review shows the publication, audience, email choice and exact time. Check the acknowledgement and use the final confirmation button. A sent email cannot be recalled.

Confirmed schedules appear in **Schedule**. Substack delivers them even with Inkspring closed. The social-post pause switch does not pause Substack. **Check status** reconciles the saved state with Substack. **Cancel scheduled send** requests and verifies cancellation while retaining the remote draft. Disconnecting Inkspring does not cancel an existing Substack schedule. The publication dashboard is `https://<your-publication>.substack.com/publish/posts`.

Reviews are single-use, expire, and bind the saved revision, account, publication and remote content. Edits require another review. Unconfirmed requests are never automatically retried. Interrupted sync/send operations recover as uncertain after restart. ZIP restores preserve linked remote metadata but mark those newsletters Check Substack, with email delivery off. They never submit or resume a send. Check existing remote schedules on Substack before sending again. Older JSON imports restore local drafts only.

## MCP and validation

`list_newsletters`, `get_newsletter` and `save_newsletter` provide local read/write access. Updates require the current revision. `list_schedule` includes newsletters' saved remote status. Agents cannot upload, schedule or send newsletters through these tools; a person reviews those steps in the app.

Automated tests simulate Substack responses, covering scheduling, publishing, cancellation, uncertain results, changed accounts/content, duplicate prevention and Markdown/code preservation. Native editor checks use an isolated workspace. Real sign-in, draft round-trip and an approved live send are separate acceptance checks; passing tests do not claim an email was sent.

Protocol references checked November 9, 2026: [Substack scheduling help](https://support.substack.com/hc/en-us/articles/360037870412-How-do-I-schedule-an-article-to-publish-for-a-future-date-on-Substack), [API terms](https://substack.com/api-tos), and the [unofficial interface reference](https://github.com/cotletdev/substack-api-mcp-server). No third-party Substack client code is bundled.
