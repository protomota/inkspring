# Connect your agent from its desktop app

Claude first, Codex second. These instructions are for local desktop sessions on the same computer as Inkspring. You do not need to open Terminal. A public directory listing is not required for this setup.

## Start in Inkspring

1. Open the installed Inkspring app. Keep it in a stable location so the connection does not break when you move it.
2. Open **Settings → AI agents**.
3. Turn on **Let AI agents use Inkspring**. This gives connected agents read and write access to the workspace; it is not a read-only connection.
4. Leave **Let agents post right away** off unless you want that capability. Agents can still schedule posts, so tell your agent when you want drafts only.

## Claude Code in the Claude app

Download the desktop app if needed: [Claude download](https://claude.com/download).

1. In Inkspring's agent settings, choose **Claude Code app**.
2. Select **Save project connection**. In the folder picker, choose the working folder you want to use in Claude Code. An ordinary folder is enough; this does not have to be Inkspring's source repository.
3. Inkspring saves `.mcp.json` in that folder. It preserves other server entries and asks before replacing a different Inkspring entry. The file contains the path to the native executable and its STDIO argument. Do not publish a project configuration that contains other services' secrets.
4. Open the Claude desktop app and select **Code**.
5. Start a new local session using **This computer**, selecting the same working folder. A cloud session cannot reach the local Inkspring server.
6. Read the project MCP trust prompt and approve the Inkspring connection if you want it to access the workspace.
7. Open the session's **Connectors** panel and check for Inkspring. Ask Claude to list your Inkspring projects using its MCP tools. If the session was already running when you saved the connection, start a new session.

If an older global or Claude chat connection also uses the name `inkspring`, check it before troubleshooting the project file. Claude Code gives some existing configurations precedence. Do not create duplicate connections just to work around a stale path.

The **+ → Add connectors** and **+ → Add plugins** menus browse installed or available integrations. Inkspring is not listed there yet. **Add custom connector** is for a remotely reachable server; pasting our localhost URL there does not make this desktop app cloud-accessible.

Sources: [Claude Code desktop connections and plugins](https://code.claude.com/docs/en/desktop#connect-external-tools), [shared MCP configuration](https://code.claude.com/docs/en/desktop#mcp-servers-from-the-claude-desktop-chat-app), [local versus remote connectors](https://support.claude.com/en/articles/11725091-when-to-use-desktop-and-web-connectors).

## Codex app

1. In Inkspring's agent settings, select **Codex app**.
2. Open the Codex app's **Settings → MCP servers → Add server**. Current OpenAI documentation calls this the ChatGPT desktop app; installed versions may retain the Codex name.
3. Enter **inkspring** as the server name and choose **STDIO**.
4. Copy **Command** from Inkspring into the command field. Do not add shell quotes around paths.
5. Add each **Argument** as one separate argument. A path containing spaces is still one argument.
6. Select **Save**, then **Restart** for that server.
7. Start a local chat. Type **/mcp** in its message box to inspect connected servers. Ask it to list your Inkspring projects using MCP.

Source: [OpenAI's app-based MCP setup](https://learn.chatgpt.com/docs/extend/mcp).

## Verify reading and writing

For an authored post idea, ask the agent to use `save_idea` with the project ID, title, and text, then verify the returned ID with `get_idea`. The idea appears in **Post ideas → Open**. Local idea saving works while the Mac display is locked and does not require AI generation.

In either agent app, send:

> Use Inkspring's MCP tools to list my projects. In the project I choose, save an unpublished newsletter titled “Agent connection test” with the body “Created from my agent app.” Read it back, then change its body to “Read and write verified.” Do not generate through Inkspring's model provider, schedule, sync to Substack or publish anything.

The agent should use `list_projects`, `save_newsletter`, `get_newsletter`, and `save_newsletter` with the current revision. Open **Newsletters** in Inkspring and check the saved title and final body. This tests a real local write and edit without a social post, subscriber email or Inkspring generation charge. Your agent app's normal usage still applies.

Afterward, ask the agent to bring selected context from sources it already has permission to use. Inkspring does not gain access to email or other apps simply because the agent can reach them. Keep private information out of public-post suggestions.

## Claude desktop chat: advanced alternative

In Claude, open **Settings → Desktop app → Manage** beside **Extensions**, then **Edit config**. In older versions, use **Settings → Developer → Edit Config**. Merge the Inkspring entry shown under **Claude chat · advanced** into the existing `mcpServers` object using a text editor. Preserve other entries. Save, then fully quit and reopen Claude. This does not require Terminal.

An installable `.mcpb` extension is the planned simpler route. It has not been packaged, installed or submitted yet. Once available, its installation flow is **Settings → Desktop app → Manage beside Extensions → Advanced settings → Install Extension…**, then select the `.mcpb` file and review permissions. [Anthropic's extension instructions](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop).
