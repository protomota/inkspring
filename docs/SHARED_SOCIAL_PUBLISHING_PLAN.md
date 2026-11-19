# Shared TikTok and LinkedIn publishing

Requested by Brad on November 18, 2026. **Critical priority. Planning only; do not implement or deploy this service yet.**

## Recommendation

Use Inkspring’s approved developer applications so customers can connect their own TikTok and LinkedIn accounts without creating developer applications or entering business secrets. Each customer must authorize their own account through the platform’s OAuth flow. Our app credentials identify Inkspring; they do not authorize posting as every customer.

We need a trusted cloud backend for confidential credentials and token operations. We already have an OAuth broker, so this is an extension and verification project, rather than an entirely missing middleware client. Serverless endpoints can handle this work; a dedicated always-running VM is not inherently required.

The Mac owns the schedule and triggers publishing while it is awake. The cloud service exists to protect our confidential application credentials and handle authenticated platform operations. **Cloud scheduling, cloud-owned job queues, and publishing while a Mac is asleep are outside this plan.**

Keeping our client secret on the server does not, by itself, mean every byte must pass through our cloud. OAuth token exchange and refresh require the confidential backend. A provider API operation that uses only a user access token can technically run on a native client where the provider permits that token arrangement. For the shared TikTok/LinkedIn connection, the recommended gateway holds provider tokens and handles publishing calls; large approved media transfers can still go directly from the Mac to the platform. [TikTok server-side token exchange](https://developers.tiktok.com/docs/en/oauth-get-a-user-access-token).

X is excluded from this shared-credentials rollout as requested. Preserve existing X connections and bring-your-own-developer-app support. Its cost is a product decision, not a technical inability to build a gateway.

## What exists today

Read-only inspection on November 18 found:

| Component | Current implementation | What it means |
| --- | --- | --- |
| Hosted OAuth broker | Website `api/connect.js`, `server/connect.mjs`, `server/connect-crypto.mjs`; native `ManagedSocialAuth.swift` | Shared OAuth start, callback, encrypted return and refresh already exist. |
| Public connection configuration | `https://inkspring.ai/api/desktop/connect/config` returns TikTok available and LinkedIn unavailable | This proves configured availability only, not the approved product/scopes, successful posting or public-post audit status. |
| Native TikTok publishing | `TikTokPublishing.swift` | Creator-info lookup, video upload, photo handling, publishing status and explicit posting options already exist. |
| Hosted TikTok photos | Website `api/media.js` and `server/media.mjs` | Existing hosting and deletion code can be evaluated and reused. |
| Current credential arrangement | Server exchanges/refreshes tokens, then returns an encrypted session; native app keeps provider tokens in Keychain and calls publishing APIs | We must review this against the current provider rules before enabling a wider rollout. |

The relevant repositories are `protomota/inkspring-site` for the native app and `protomota/inkspring-website` for the website/gateway. The shared payment backend in `protomota/protomota-com` is separate; do not put social credentials into the payment service merely because it already exists.

TikTok’s current token guidance calls for server-side token exchange, storage, refresh and revocation. The recommended target therefore uses a server token vault and publishing gateway, with an opaque connection handle in the native app, rather than treating the existing token-return broker as the finished architecture. [TikTok token management](https://developers.tiktok.com/docs/en/oauth-user-access-token-management), [token exchange](https://developers.tiktok.com/docs/en/oauth-get-a-user-access-token).

## Approval checks before building

### TikTok

- Brad reports that TikTok posting is approved. Verify which production application was approved, the redirect URIs, `video.publish`, applicable account/creator limits, and whether the Direct Post audit permits public posting.
- Distinguish Direct Post from upload-to-inbox and Login Kit approval. They are different capabilities. Do not substitute an advertising/Business API credential for the Content Posting API application.
- The historical Inkspring candidate is app `7704773145382717492`; verify the actual current approved application in [TikTok’s developer portal](https://developers.tiktok.com/apps/), rather than assuming this is still the right one.
- Record approval evidence and limitations in this task without copying secrets. Verify photo/video requirements and ownership of the actual media-serving domain.

Scope approval and a successful login do not by themselves establish unrestricted public publishing. [Direct Post prerequisites](https://developers.tiktok.com/docs/en/content-posting-api-get-started).

### LinkedIn

- Verify the current status of app **266734420**, including the business-vetting appeal. Earlier Community Management access was denied; this plan does not assume that was reversed.
- Treat personal-profile posting (`w_member_social`, Share on LinkedIn) separately from company-page posting (`w_organization_social`, Community Management and an authorized page role).
- Verify Development versus Standard access and the approved member/app quotas before a public rollout. Do not use a limited development approval as proof of unrestricted multi-customer access.
- Detect whether our approved application actually receives refresh tokens. Offer reconnect when required rather than assuming every LinkedIn application can refresh indefinitely.

Review: [application dashboard](https://www.linkedin.com/developers/apps/266734420/products), [Share on LinkedIn](https://learn.microsoft.com/en-us/linkedin/consumer/integrations/self-serve/share-on-linkedin), [Posts API permissions](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/posts-api), [Community Management tiers](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/community-management-overview), [refresh eligibility](https://learn.microsoft.com/en-us/linkedin/shared/authentication/programmatic-refresh-tokens).

## Proposed architecture

```text
Mac scheduler (mobile reviews/requests sync to the Mac)
  ├─ Local schedule, library, post editor, preview and consent
  ├─ Platform OAuth through the system browser
  └─ Opaque, revocable connection/session handle in Keychain
                  │ HTTPS
                  ▼
Inkspring gateway on inkspring.ai
  ├─ OAuth callback, token exchange and refresh
  ├─ Encrypted provider-token vault with per-owner authorization
  ├─ Creator/page capabilities and publishing operations
  └─ Publish receipts, status reconciliation and disconnect
                  │ User-specific platform authorization
                  ▼
            TikTok / LinkedIn

Video bytes: native device → provider-approved upload URL where supported
Hosted photos: temporary, verified Inkspring media domain → TikTok
```

### Credential and account boundaries

1. Retrieve application client secrets from Bitwarden Secrets Manager for deployment. Keep them in server-only configuration. Never put them in app bundles, public source, browser code, logs or task notes.
2. Store per-user access and refresh tokens encrypted on the server. Rotation must be atomic so parallel refreshes cannot overwrite the newest credential. Use returned expiry fields; avoid hard-coded lifetimes.
3. Reuse and review the existing callback protection, state checks and encrypted handoff. Apply provider-supported PKCE. Return an opaque Inkspring session/connection handle instead of provider tokens.
4. Prove ownership on every request. An arbitrary connection ID, page URN or post ID supplied by a client is not authorization. Include device revocation, replay protection, request limits and app-wide quota protection.
5. Keep connection identity separate from paid support identity. Do not silently require a paid-support account or add a general Inkspring login. Define device-bound sessions and any future cross-device account recovery explicitly.
6. Disconnect must revoke the platform grant where supported, invalidate Inkspring sessions, stop pending local publication attempts, and remove retained credentials. Keep only necessary, redacted publication receipts under a documented retention policy.

## Publishing and scheduling

### The Mac schedules; the gateway handles confidential operations

- The user selects a project, platform account, final content, media and time in the existing native UI.
- The Mac retains the schedule and initiates publishing through the gateway at the chosen time. Mobile keeps the existing simple day/hour workflow and Mac-owned preferences.
- The gateway performs provider-authenticated operations and returns a receipt. For local videos, initialize a provider upload and send large bytes directly to its allowlisted upload URL instead of routing video bodies through ordinary serverless requests.
- Preserve the existing requirement that the Mac runs the schedule. No new cloud scheduler or always-running publishing worker is needed.
- Capture a consented revision of the post. If content or disclosure settings change, require review again where needed. Preserve ideas and source drafts.

### Request flow at the scheduled time

1. The awake Mac selects a due post from its existing local schedule and acquires the existing publication lease.
2. It sends the gateway the authorized connection handle, selected destination, approved content revision and an idempotency key. The app never sends or contains our client secret.
3. The gateway checks ownership and permissions, refreshes the user's token when needed, and initiates the provider operation. It responds to the Mac; it does not take ownership of future scheduled jobs.
4. The Mac sends local video bytes to the returned allowlisted provider upload URL where supported. Photos that TikTok must pull use the verified Inkspring media host with limited retention.
5. The Mac/gateway reconcile processing status using the saved provider operation ID, then save the receipt to the existing publication history.
6. On a timeout, reconnect, or app restart, reconcile the existing operation before retrying. Reject stale revisions and respect cancellation before provider submission. Do not promise exactly-once delivery across every external API.

Test expiry, concurrent refresh, gateway outages, rate limits, cancellation, duplicate requests, app restarts and uncertain provider responses. These are request/retry concerns for a Mac-owned schedule, not a separate cloud-scheduling project.

## Platform-specific acceptance

**TikTok:** retrieve current creator capabilities and show the target account; require the user’s privacy choice without a preset; respect interaction restrictions; capture the applicable consent and commercial disclosures; preserve editable content and preview; show processing versus published status. Confirm the planned scheduling UX complies before enabling unattended execution. Use device video upload versus verified-domain URL transfer appropriately. This must be a product for creators, not an internal bulk-upload utility. [TikTok content-sharing requirements](https://developers.tiktok.com/docs/en/content-sharing-guidelines).

**LinkedIn:** show profile/page destination explicitly, verify page permissions, initialize and finish media before creating the post, save the returned post URN, and use the supported versioned Posts API. Handle missing permissions, revoked page roles, API sunset versions and reconnect separately from transient errors. [Posts API](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/posts-api).

Neither platform’s publishing documentation should be treated as a promise of unlimited, permanently free API access. Verify current terms and approved quotas. Infrastructure, storage and bandwidth still cost money even if organic posting has no listed per-post fee. This plan creates no paid service and changes no X billing arrangement.

## App explanations and release gate

Keep the explanation beside the connection and scheduling controls, in plain language:

- **Connect:** “Connect your own TikTok or LinkedIn account. Inkspring securely handles the connection. You don’t need developer API keys.” Show only capabilities actually approved and configured.
- **Schedule:** “Your Mac publishes scheduled posts while Inkspring is open, your Mac is awake, and it has an internet connection.” Explain the actual existing behavior for overdue posts after a restart; do not invent a delivery guarantee.
- **Service role:** “Inkspring’s web service protects our app credentials and handles authorized publishing requests. Your schedule stays on your Mac.”
- **Mobile:** “Schedule changes sync to your Mac, which publishes the post.” Show request acceptance separately from successful publication.
- **Status:** distinguish Connected, Reconnect needed, Service unavailable, Scheduled, Uploading, Processing, Published and Failed. A receipt or confirmed provider status is required before showing Published.
- **Unavailable setup:** say “TikTok posting isn’t available yet” or the equivalent LinkedIn capability, with a useful retry/help action. Do not display internal errors, missing secret names, or instructions for ordinary users to create our developer credentials.

Brad’s November 18 release instruction: after authorized implementation and service setup, create a separate local Mac build for Brad to test. Provide the build path and real recordings/screenshots. **Do not release a new Mac build, update the public installer or Sparkle feed, or trigger Mac release distribution until Brad has tested locally and authorized release.** A plan or a successful build is not that approval.

Provider credentials and any account-side steps are deferred until needed. First inspect existing approved app configuration and available Secrets Manager entries. Reuse valid credentials; do not create duplicates. Complete everything possible autonomously, and give Brad only the precise account-side actions that genuinely require him, with exact URLs and steps. Track those actions as Critical/Urgent To do items in OpenTalon, unassigned and without invented due dates.

## Implementation sequence and review gates

1. **Inventory and approval evidence:** confirm actual approved apps/scopes/audit status, callbacks, deployed routes, existing credentials by name only, provider limits and current tests. Link the existing TikTok review task INK-005 and LinkedIn appeal work without assuming historical blockers still apply.
2. **Design review:** approve the gateway/vault boundary, device identity and minimal retention. Preserve Mac-owned scheduling. Keep core editing and ordinary local use independent of this service.
3. **Gateway foundation:** harden existing broker, implement isolated token ownership/rotation/revocation, rate limits and provider adapters. Separate staging credentials and account connections from production.
4. **TikTok pilot:** test two independently authorized users, video and photo paths, privacy choices, processing outcomes, token rotation and disconnect. Use permitted visibility/test accounts; obtain approval before publishing any real content.
5. **LinkedIn pilot:** ship only the approved profile/page capability. Test text and supported media, page-role removal and token expiry. Keep unavailable capabilities clearly labeled.
6. **Existing scheduler integration and local review:** verify that a due post from the awake Mac publishes through the shared gateway using the existing Mac/mobile workflow. Verify the explanations above and capture real recordings. Create the local Mac build for Brad’s testing. Website changes go through GitHub only when authorized. Keep provider switches and rollback available. Hold Mac distribution until Brad has tested locally and authorizes release. Do not add cloud scheduling.

## Definition of done

- Customers connect their own approved platform accounts without entering our secrets or making developer apps.
- Two users cannot read, refresh, revoke or post through each other’s connections.
- No shared secret or provider refresh token is present in the distributed native app or public source; logs and errors are redacted.
- A real approved TikTok post and an approved LinkedIn profile/page post have verified platform receipts and visible results, not just successful login responses.
- Scheduled retry, cancellation and uncertain-outcome tests demonstrate no duplicate publish caused by our executor.
- Reconnect, disconnect, expired authorization, account restrictions, provider quotas and API failures have understandable UI.
- Scheduling stays on the Mac. The gateway holds confidential credentials and handles authorized requests; it does not introduce a cloud-owned schedule, background job queue, or sleeping-Mac publication feature.
- Real flow recordings and evidence are attached to the OpenTalon item before rollout is called complete.

## Current status

Research and plan only. Brad clarified that this is exclusively about protecting shared API credentials while the awake Mac executes its schedule. Cloud scheduling is excluded. No TikTok/LinkedIn code, keys, account settings, connections, publishing jobs or deployments were changed for this request. TikTok approval is reported by Brad and must be matched to the exact production application during the first implementation step. The separate, already-authorized support/TestFlight release is unrelated to this plan.
