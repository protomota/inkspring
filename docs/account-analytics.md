# Local account analytics

Open **Analytics** in the desktop sidebar. Select an account, refresh it, and optionally enable a daily snapshot while Inkspring is running. Automatic reads start off and pause after reconnecting an account. X reads use the connected app's API credits. A manual refresh reads at most one profile and one page of posts; loading older posts explicitly reads one further page.

The dashboard shows followers and net growth between observed snapshots; likes, replies/comments and other available engagement on imported posts; top posts; and confirmed publishing activity from this workspace. Date ranges select a post's publication date, not when its likes arrived. Engagement counts are cumulative at the last successful refresh. Missing metrics display as unavailable rather than zero. Rankings are limited to the imported sample and show the top 50 posts.

Follower history starts with the first actual observation. Daily rows preserve the first and latest observation that day, including same-day net growth. History is keyed to the platform and stable account ID, survives restarting and reconnecting the same account, and is kept separate when switching accounts. Net growth does not distinguish follows from unfollows. Historical counts are not inferred from a current follower total.

Data lives in the workspace SQLite database (`analytics-day`, `analytics-post`, `analytics-state` records). No credentials or provider payloads are written to analytics records. Social credentials continue to use protected storage. Account metrics are not sent to writing providers. Disconnecting hides that account's data without deleting it; reconnecting the same account restores its history. Analytics records are included in the complete workspace backup ZIP. Older JSON exports did not contain them.

## Platform coverage

| Platform | Implemented reads | Access and limits |
| --- | --- | --- |
| X | Followers, following, profile post total; 25 own posts per page with likes, replies, reposts/quotes and impressions when returned | Existing `users.read` and `tweet.read` scopes. Replies included, reposts excluded from imported posts. Profile likes are **not** interpreted as likes received. |
| Instagram | Followers, following, media total; 25 media entries per page with likes and comments when returned | Business/Creator connection with `instagram_business_basic`. Hidden counts remain unavailable. Reach, views and detailed Insights are not requested. |
| TikTok | Followers/following, profile likes and public-video total; 20 public videos per page with likes, comments, shares and views | `user.info.stats` for profile counts; `video.list` and Display API access for videos. These are separate from publishing permission and are not silently added to sign-in. Private sandbox posts are absent from the public-video list. |
| LinkedIn | Member follower total | Requires approved `r_member_profileAnalytics`, absent from the normal posting connection. Member post analytics are not integrated yet. |
| Reddit | 25 own submissions per page, net score and comment count | Approved Reddit API access and `read`. Net score can be negative and is not a like count. User followers are not imported. |

All platforms also show confirmed local publishing receipts without additional read permissions. Each confirmed thread step counts once, including completed steps in a partially failed thread. Pending, uncertain and unconfirmed attempts are excluded. Counts deduplicate by platform, account and remote step ID. Activity is grouped by UTC date.

## Sources checked November 9, 2026

- [X user lookup](https://docs.x.com/x-api/users/get-user-by-id) and [own-post timeline](https://docs.x.com/x-api/users/get-posts).
- Meta's official SDK fields: [IGUser](https://github.com/facebook/facebook-python-business-sdk/blob/main/facebook_business/adobjects/iguser.py), [IGMedia](https://github.com/facebook/facebook-python-business-sdk/blob/main/facebook_business/adobjects/igmedia.py). The Meta documentation endpoint was rate limited during verification; the Instagram integration still needs a connected Business/Creator account for a live read test.
- TikTok [user info](https://developers.tiktok.com/doc/tiktok-api-v2-get-user-info), [Display API](https://developers.tiktok.com/docs/en/display-api-overview), [public video listing](https://developers.tiktok.com/docs/en/tiktok-api-v2-video-list), [video metrics](https://developers.tiktok.com/docs/en/tiktok-api-v2-video-object).
- LinkedIn [member follower statistics](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/members/follower-statistics), [member post statistics](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/members/post-statistics) (post integration not implemented).
- [Reddit API reference](https://www.reddit.com/dev/api/).
