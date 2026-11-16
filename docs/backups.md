# Back up and restore Inkspring

## Export Backup

1. Open **Settings → Storage & backups**
2. Save or discard unfinished edits. Keep any drive containing an attached video connected.
3. Select **Export Backup**, choose a destination and save the `.zip`. The same action is in **File → Export Backup…**.
4. Wait for the saved confirmation, then keep a copy somewhere you can recover after losing this computer.

The ZIP contains versioned `data.json`, local workspace images, and copies of the videos referenced by saved drafts. Writing includes projects, posts/drafts, ideas and their relationships, sources, newsletters with exact Markdown, publication receipts, saved research, agent suggestions, replies and analytics. It includes provider/model choices, voice/style, interests/hashtags and the idea queue target. Dates, identifiers and relationships are preserved.

Credentials, API keys, social sessions, MCP keys and TikTok publishing consent are excluded. The full Obsidian vault, external linked content and cloud-only R2 objects remain in their own storage; the accepted notes/references already saved in Inkspring are included. Connect those services/folders again on a new computer. The ZIP is not encrypted; keep it private.

Export fails clearly if an attached file is missing or changed rather than silently creating an incomplete backup. Files stream to ZIP, including large videos. Limits:100MB structured JSON,100,000records,10,000media files,4GB per file and64GB total media. No cloud upload or sync is involved.

## Import / Restore

1. Open **Settings → Storage & backups → Import / Restore**, or **File → Import / Restore…**.
2. Choose the backup ZIP. Inkspring stages it privately, checks the version, record structure, project relationships, duplicate IDs, media paths, sizes and SHA-256 hashes before changing the workspace.
3. Read the counts and replacement warning. Matching record IDs will be replaced; other local records remain. Cancel and export your current workspace first if you want to keep its current versions.
4. Select **Restore backup** to proceed. Images and video files are restored locally; credentials and sign-ins are not imported. Re-importing the same backup updates those same record IDs and reuses restored media rather than duplicating them.
5. Review restored writing and reconnect accounts where needed. Restored scheduled posts move to **Ready to schedule**, with their original time retained as metadata. Choose a new time and schedule explicitly. Automatic posting, idea refill, reply/analytics monitoring and agent access are off after restore; enable each only when ready.
6. For Substack, check the remote publication before syncing/sending again. Restored linked newsletters are marked **Check Substack**. A schedule previously accepted by Substack may still run there independently of this computer; restoring cannot cancel it.

Database changes commit together. If media staging or a database write fails, existing records and files remain and newly created media is removed. Writing and background operations are held during the transfer. Existing files are never overwritten with different bytes.

Older version1 `.json` backups remain importable, but cannot recover the images, videos or newer record types those files never contained. The import review calls out that limitation.

## Verification

Automated tests cover a meaningful full ZIP round trip into a clean on-disk workspace: posts, ideas, source relationships, exact newsletter code fences, an image, a video, voice/model preferences, analytics observations, replies, saved research and pending agent context. They also cover repeat import without duplication, excluded credentials/consent, paused schedules/automation, malformed records, missing/tampered media, unexpected ZIP entries, record-kind collisions, write-failure rollback, missing export media and legacy JSON.
