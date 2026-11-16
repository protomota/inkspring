# Social sign-in and publishing

## Shared Inkspring connections

The desktop can use server-managed Inkspring developer apps. It discovers availability at https://inkspring.ai/api/desktop/connect/config and opens sign-in in the system browser. Users do not enter app IDs or app secrets for an available shared connection. An optional advanced setup still supports their own developer apps.

App secrets remain in the `inkspring-website` Vercel production environment. The server uses short-lived encrypted state and a Secure/HttpOnly/SameSite=Lax browser cookie, exchanges the platform code, and signs and encrypts the result to the requesting desktop’s ephemeral key. The protocol return contains ciphertext rather than plaintext account tokens. The desktop validates the signature and pending state, verifies platform identity directly, and stores tokens under OS credential protection. The service has no account database and does not receive drafts or publish posts. Refreshes requiring a shared app secret use a service-issued ticket bound to the refresh token.

The registered provider callbacks must be exactly:

- X: `https://inkspring.ai` (reuses the existing registered callback; OAuth state plus code/error query parameters route to the broker)
- Instagram: `https://inkspring.ai/api/auth/callback/instagram`
- LinkedIn: `https://inkspring.ai/api/auth/callback/linkedin`
- Reddit: `https://inkspring.ai/api/auth/callback/reddit`
- TikTok: `https://inkspring.ai/api/auth/callback/tiktok` (Login Kit, Web platform)

Recovered X and dedicated Instagram Login app credentials were installed as server-only secrets. LinkedIn and Reddit remain unavailable through the shared service until their app credentials are supplied. Configuration availability does not prove external-user app review or live account authorization. Provider developer dashboards: https://console.x.com/, https://developers.facebook.com/apps/, https://www.linkedin.com/developers/apps, https://www.reddit.com/prefs/apps.

The following instructions describe the optional **own developer app** mode.


In own-app mode, Inkspring exchanges social authorization codes on the user’s computer and stores account tokens in macOS Keychain. That mode bypasses the shared connection service. Neither mode requires an Inkspring account or cloud database. Research API tokens and social publishing sessions are separate.

This build supports one connected account per platform:

| Platform | Publishing supported | Requirements |
| --- | --- | --- |
| X | Text posts, single-image posts, reply-linked threads and replies to a pasted post | OAuth 2.0 app with publishing access and available API credits |
| Instagram | Single images with captions | Business or Creator account, Instagram Login permissions, public JPEG image URLs |
| LinkedIn | Personal-profile text posts | Share on LinkedIn and OpenID Connect products |
| Reddit | Subreddit text submissions, optional flair | Installed developer app, appropriate Reddit API access and subreddit permissions |
| TikTok | Single photo posts with a title and caption (Direct Post) | Login Kit and Content Posting API with `user.info.basic` and `video.publish`; until TikTok approves the app, posts must go to a private account |

## Before connecting

Users may optionally configure a **developer app they own** in Connections. Never embed a shared Protomota client secret in the desktop application.

X and Reddit default to a temporary loopback listener bound only to `127.0.0.1:43821`, used during sign-in. The renderer still has no network access. Instagram and LinkedIn default to `https://inkspring.ai/desktop-connect/`, a static page that forwards an authorization code into the installed `inkspring://` protocol. The page has no token exchange, cookies, persistent browser storage, analytics, backend, or database. Its HTTPS host can observe the initial callback request; tokens and client secrets never pass through that page.

The static callback page is deployed from the website repository’s `public/desktop-connect/` directory at **https://inkspring.ai/desktop-connect/**. Its public HTTPS page was verified in the browser. Provider developer-app configuration is still required for actual sign-in. Local page preview: http://localhost:4178/desktop-connect/ (an empty return displays instructions; it does not initiate sign-in).

A packaged installation registers the `inkspring://` protocol. The Mac app handles the sign-in callback.

## X setup

1. Open https://console.x.com/ and select or create your developer app. If your account opens the older developer dashboard, use https://developer.x.com/en/portal/dashboard.
2. Open the app’s **Settings → User authentication settings → Set up/Edit**. Enable OAuth 2.0, select a **Native App** public client, and enable **Read and Write** access. Do not select read-only permissions for publishing.
3. Register this exact callback: `http://127.0.0.1:43821/oauth/x`. Enter `https://inkspring.ai` for the required website URL. Save the settings.
4. Open the app’s **Keys and tokens** page and copy the **OAuth 2.0 Client ID**. This is different from the app-only Bearer Token used for research.
5. In Inkspring, open **Connections → X → Set up your developer app**. Paste the Client ID, leave Client Secret blank for Native App, keep the exact callback above, and click **Save developer app**.
6. Click **Connect X**. Sign in on X in your system browser and authorize the displayed permissions (`tweet.read`, `tweet.write`, `users.read`, `media.write`, `offline.access`). If you connected X before image posts existed, choose **Disconnect** and **Connect X** again so Inkspring can upload images. The loopback page confirms connection and you can return to Inkspring.
7. For direct X research, copy the app-only Bearer Token from **Keys and tokens**, then use **Settings & API keys → X Bearer Token · research → Save key**. In **Research**, choose X and **X API · direct**. Account lookups use the user timeline; hashtag/keyword search uses the last seven days. Each fetch requests 10, 15, or 30 posts, with no automatic pagination.

If you already use a confidential X client, enter its Client Secret as well. Its configured callback and application access still must match.

## Instagram setup

1. Open https://developers.facebook.com/apps/ and create/select an app you own. Add **Instagram → API setup with Instagram login**, rather than the older Basic Display API.
2. Use a **Business or Creator** Instagram account. To change an account, open https://www.instagram.com/, then **More → Settings → Account type and tools → Switch to professional account**, or use the corresponding account-type settings in the Instagram mobile app.
3. In the Meta app’s **Instagram → API setup with Instagram login**, configure Business Login and register `https://inkspring.ai/desktop-connect/` as the valid OAuth redirect URI. This static page must be deployed before sign-in. Do not use a similarly named callback from the old hosted application.
4. Enable/request `instagram_business_basic` and `instagram_business_content_publish`. For development, add your Instagram account under the app’s roles/testers, then accept the invitation from that Instagram account’s **Settings → Apps and websites → Tester invites**. Additional users require the provider’s applicable review/permissions.
5. Copy the **Instagram App ID** and **Instagram App Secret** from the Instagram setup. In Inkspring, open **Connections → Instagram → Set up your developer app**, enter those values and the exact redirect URI, then click **Save developer app**.
6. Click **Connect Instagram**, sign in and authorize the requested access. On the static return page, click **Return to Inkspring** and allow the browser to open the installed app. No secret or access token is sent through the page.
7. To publish, provide 1 public JPEG URL for the image. Meta fetches these images from the URLs; a private file on the user’s desktop is not reachable by its image publishing API. Inkspring does not upload media to an Inkspring storage service. The app waits for processing and records the published media ID before looking up its permalink.

## LinkedIn setup

1. Open [LinkedIn My Apps](https://www.linkedin.com/developers/apps) and select or create an app you own.
2. Under **Products**, enable **Share on LinkedIn** and **Sign In with LinkedIn using OpenID Connect**. Personal sign-in requests `openid`, `profile`, and `w_member_social`.
3. Open **Auth → Authorized redirect URLs for your app → Edit**, add `https://inkspring.ai/desktop-connect/` including the final slash, and save.
4. Copy the **Client ID** and **Client Secret** from **Auth**. Open **Settings → Connections** or **Connections → LinkedIn → Use your own developer app** in Inkspring. Enter the values and select **Save developer app**. Leave company Page access off for personal posting.
5. Select **Connect developer app** in the Mac app, then sign in on LinkedIn and approve access. Select **Return to Inkspring** on the callback page if prompted. Select **Test connection** on the LinkedIn card to check identity without posting. Use a text draft and review the destination before publishing or scheduling.

The bring-your-own-app flow uses the existing public callback page to hand the authorization code to the app. The desktop exchanges it directly with LinkedIn. The client secret and account tokens are stored in protected local storage. Company Page posting requires Community Management approval and the appropriate Page role.

## Reddit setup

1. Read the provider’s current access requirements at https://support.reddithelp.com/hc/en-us/articles/14945211791892-Reddit-Data-API-Wiki and obtain access applicable to your intended use. Creating a client does not guarantee API approval.
2. Open https://www.reddit.com/prefs/apps, then click **create another app…** or **are you a developer? create an app…**.
3. Enter a name, choose **installed app**, and register `http://127.0.0.1:43821/oauth/reddit` as the exact redirect URI. Save the application.
4. Copy the client ID below the application name. Installed apps do not require a client secret.
5. In Inkspring, open **Connections → Reddit → Set up your developer app**, paste the Client ID, keep the redirect URI above, and click **Save developer app**.
6. Click **Connect Reddit**. Sign in and authorize identity, read, and submit access in your browser. Return to Inkspring after the loopback confirmation.
7. When publishing, enter the destination subreddit such as `r/test` and its flair ID if required. Reddit’s subreddit rules and account restrictions still apply.

## Publish a draft

1. Open **Writing studio**, choose the channel and supported format, and finish the content. For X threads, separate posts with a blank line.
2. Click **Review & publish**. Inkspring first saves the draft locally.
3. Add any required destination/media details and click **Review post**. Check the connected account, subreddit, exact text, image order, and any already-published thread segments.
4. Click **Publish to [platform]**. Do not close the app while publishing. The UI shows a confirmed platform result and saves a local receipt with returned post IDs/links in **Connections → Publishing history**.
5. For a partly published X thread, review the same draft again to publish only the remaining segments. If a request ended without a confirmed result, open the platform and check it first. Publishing history requires an explicit acknowledgment before another attempt; an unconfirmed post might already exist.
6. To disconnect, open **Connections → [platform] → Disconnect**. This removes the local account session, including refresh tokens. To revoke the provider grant as well, open the corresponding connected-app settings: X https://x.com/settings/connected_apps, Instagram https://www.instagram.com/accounts/manage_access/, LinkedIn https://www.linkedin.com/mypreferences/d/permitted-services, Reddit https://www.reddit.com/prefs/apps.

## Validation limits

The automated suite covers simulated provider responses, OAuth callback validation and a real loopback listener, token refresh/rotation, canceled sign-in, account changes, publication payloads, processing, duplicate prevention, uncertain outcomes, and partial-thread recovery. These tests do not establish that any real account has approved the app. No live authorization grant, paid provider request, or social post was made during this implementation. Provider app registration, permissions/review, and a live permitted account are required for final acceptance testing.

Primary references: X OAuth https://docs.x.com/fundamentals/authentication/oauth-2-0/authorization-code and publishing https://docs.x.com/x-api/posts/create-post; Meta Instagram Login https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/ and content publishing https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/content-publishing/; LinkedIn OAuth https://learn.microsoft.com/en-us/linkedin/shared/authentication/authorization-code-flow and publishing https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/posts-api; Reddit OAuth https://github.com/reddit-archive/reddit/wiki/oauth2.

## TikTok setup

TikTok photo posts follow TikTok's Content Sharing Guidelines. Before every post Inkspring reads the creator's live posting options and shows the account nickname, an editable title and caption, a privacy menu with no default, an Allow comments box that starts off (and is disabled when the account turned comments off), a content disclosure toggle with Your brand and Branded content, and the Music Usage Confirmation (plus Branded Content Policy when it applies). Branded content cannot be private. After posting, Inkspring polls TikTok until the post completes and tells the person it can take a few minutes to appear.

TikTok only pulls photos from a URL the app has verified, so:

- **Shared Inkspring app:** the desktop converts the image to a JPEG of at most 1080p and uploads it to `https://inkspring.ai/api/desktop/media` with the person's TikTok token. The service checks the token with TikTok, stores the image in a private Vercel Blob store, serves it at `https://inkspring.ai/tiktok-media/<file>.jpg` for at most two hours, and deletes it once TikTok finishes. Verify the URL prefix `https://inkspring.ai/tiktok-media/` (or the domain) in the TikTok app. The service needs `TIKTOK_CLIENT_KEY`, `TIKTOK_CLIENT_SECRET` and `BLOB_READ_WRITE_TOKEN` in the website's Vercel environment.
- **Your own developer app:** register the Desktop redirect `http://127.0.0.1:43821/oauth/tiktok`, paste the Client key and Client secret in **Connections → TikTok → Use your own developer app**, and enter a public image URL on a domain you verified for that app when posting.

Unaudited TikTok apps can only post to private accounts and to at most five users a day.
