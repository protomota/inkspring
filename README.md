<p align="center"><img src="public/readme-app-icon.svg" alt="" width="120" height="120"></p>

<h1 align="center">Inkspring</h1>

<p align="center"><strong>Craft, schedule and post your social posts from your Mac.</strong><br>Research an idea, shape the post for X, LinkedIn, Reddit and Substack, and decide when it goes out.</p>

<p align="center"><a href="https://inkspring.ai/download"><strong>Download for Mac</strong></a> · <a href="#build-it-yourself">Build it yourself</a> · <a href="https://inkspring.ai">Visit Inkspring</a> · <a href="LICENSE">public domain (Unlicense)</a></p>

## Your social posts, crafted on Mac

Collect references and post ideas, then turn an idea into an editable social draft or a newsletter. Write by hand, use a connected agent, or bring an API key. Review the text, attachments, and destination before you schedule or publish.

![Inkspring Post Ideas on Mac showing six ideas and actions for developing drafts](docs/screenshots/mac-post-ideas.webp)

## Review and schedule on iPhone and iPad

Review and edit recent drafts, save ideas, and choose a posting day and hour. With iCloud sync configured, your Mac receives the scheduling request and applies your preferred posting hours and minute settings.

<table>
<tr><th>iPhone · Choose a posting time</th><th>iPad · Review a draft</th></tr>
<tr>
<td align="center" valign="top"><img src="docs/screenshots/iphone-schedule.webp" alt="Choosing a posting day and hour on iPhone" width="267"></td>
<td align="center" valign="top"><img src="docs/screenshots/ipad-review.webp" alt="Draft list, selected draft, review notes, and Schedule action on iPad" width="425"></td>
</tr>
</table>

*Native app screenshots show sample content.*

## What's inside

- **Research and ideas.** Save sources, explore angles by project, and turn an idea into a draft for the platforms you choose. The original idea stays in your workspace.
- **Writing and newsletters.** Edit a post, attach an image or video, and draft newsletters with Markdown and previews.
- **Scheduling.** Set preferred hours by platform on Mac and review what's ready, scheduled, and already published.
- **AI and integrations.** Connect Claude or Codex on Mac, or configure a supported provider. Inkspring uses the connections you enable for AI, research, and publishing.
- **Storage and backups.** The Mac workspace is stored locally. Export a ZIP with drafts and media, restore it, or set up scheduled backups. The companion uses your private iCloud account for sync.

[Social setup](SOCIAL_SETUP.md) · [Agent setup](docs/agent-app-setup.md) · [Newsletter setup](docs/substack-newsletters.md) · [Backups](docs/backups.md)

## Build it yourself

Use a Mac with Xcode installed. The Mac app supports macOS 14 and later.

```sh
git clone https://github.com/protomota/inkspring.git
cd inkspring
native-mac/build-app.sh "$PWD/.build/local"
open "$PWD/.build/local/Inkspring.app"
```

For iPhone and iPad, open [InkspringCompanion.xcodeproj](native-mac/InkspringCompanion.xcodeproj) and run the **InkspringCompanion** scheme on a simulator. A physical device requires your own signing team and bundle identifier. Cross-device iCloud sync in your own build also requires your own CloudKit container and matching entitlements.

[Native build and usage guide](native-mac/README.md) · [Validation guide](VALIDATION.md)

## Open source, public domain (Unlicense)

Inkspring is free, and its source is open under the [public domain (Unlicense)](LICENSE). Use it, change it, ship it, sell it. Your posts remain yours. Third-party components keep their own licenses.

[Website](https://inkspring.ai) · [Send feedback](https://protomota.com/apps?app=inkspring#feedback)

---

<p align="center">
  <a href="https://protomota.com"><img src="docs/readme/protomota-logo.png" width="40" height="40" alt="Protomota"></a>
</p>

<p align="center"><strong>Made by <a href="https://protomota.com">Protomota</a>.</strong> Free apps, open source and public domain (Unlicense).</p>

<p align="center">
  <a href="https://opentalon.ai">OpenTalon</a> ·
  <a href="https://inkspring.ai">Inkspring</a> ·
  <a href="https://jotley.ai">Jotley</a> ·
  <a href="https://glimmertoday.com">Glimmer</a> ·
  <a href="https://pulsecanvas.ai">PulseCanvas</a> ·
  <a href="https://voxley.si">Voxley</a> ·
  <a href="https://textley.ai">Textley</a> ·
  <a href="https://graphley.ai">Graphley</a> ·
  <a href="https://bucksley.ai">Bucksley</a>
</p>

<p align="center"><a href="https://lab.protomota.com">Join the Lab</a> · <a href="https://newsletter.protomota.com">Newsletter</a> · <a href="https://protomota.com/open-source">Open source at Protomota</a></p>
