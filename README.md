# discourse-indexnow

[English](README.md) | [中文](README.zh_CN.md)

[![Discourse Plugin CI](https://github.com/imlotso/discourse-indexnow/actions/workflows/discourse-plugin.yml/badge.svg)](https://github.com/imlotso/discourse-indexnow/actions/workflows/discourse-plugin.yml)

Automatically submit Discourse topic URLs to the [IndexNow](https://www.indexnow.org/) protocol so Bing, Yandex, and other IndexNow-compatible search engines can discover public content faster.

## Features

- Submit new public topics and topic-changing edits automatically.
- Submit the paginated URL automatically on new replies (with configurable per-URL cooldown).
- Submit topic URLs when a topic is destroyed so IndexNow-aware engines can recheck them and remove them faster.
- Include localized topic URLs when Discourse Content Localization and its crawler locale parameter are enabled.
- Submit localized URLs when a translation is created, including translations completed after the initial topic submission.
- Submit the main topic URL and all existing localizations in one IndexNow `urlList` batch.
- Reuse the same batching engine for historical backfills, with automatic 10,000-URL chunks.
- Apply hourly and daily submission limits using a sliding window, and honor IndexNow `Retry-After` responses.
- Rotate the IndexNow key; the previous key is invalidated immediately.
- Verify that `/<key>.txt` is publicly accessible from the admin panel.
- Re-submit or exclude content when topics move, categories change visibility, or tags update.
- Track batch IDs, locales, a seven-day success trend, and categorized failure reasons.
- Preview and submit historical topics by category and date range from the admin panel.
- Submit manually chosen URLs from the admin panel, one per line.
- Keep all submissions asynchronous and privacy-aware.
- Provide English and Simplified Chinese admin interfaces.

## Requirements

- Discourse latest stable or tests-passed branch.
- No extra gems or frontend theme changes.
- Localized URL submission requires the optional Content Localization feature.

## Installation

1. Install the plugin in your Discourse container:
   ```sh
   cd /var/discourse
   ./launcher enter app
   bash -c "cd plugins && git clone https://github.com/imlotso/discourse-indexnow.git"
   exit
   ```
2. Rebuild the container:
   ```sh
   cd /var/discourse
   ./launcher rebuild app
   ```
3. Navigate to **Admin > Plugins > discourse-indexnow**.
4. Generate a key, or provide an existing 32-character hex key.
5. Enable the plugin.
6. Verify the public key URL:
   ```text
   https://your-forum-domain.com/<key>.txt
   ```
   This should return the key itself and HTTP 200. The admin panel also displays a cached accessibility check.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `indexnow_enabled` | `false` | Master toggle for the plugin. |
| `indexnow_api_key` | `""` | The current 32-character hex key. |
| `indexnow_submit_on_create` | `true` | Submit when a new topic is published. |
| `indexnow_submit_on_edit` | `true` | Resubmit when first post or topic attributes change. |
| `indexnow_submit_on_reply` | `false` | Submit the paginated URL on new reply. |
| `indexnow_url_cooldown_minutes` | `1` | Per-URL cooldown (minutes) to prevent spamming. |
| `indexnow_excluded_category_ids` | `""` | Additional categories to exclude. |
| `indexnow_excluded_tag_names` | `""` | Additional tags to exclude. |
| `indexnow_hourly_limit` | `200` | Max URLs to submit per hour. |
| `indexnow_daily_limit` | `10000` | Max URLs to submit per day. |

The plugin refuses to enable if the site requires login, and automatically disables itself if that setting is turned on later.

The `submit on create` and `submit on edit` settings govern automatic submissions for new and edited topics only. Historical backfilling and manual submission are separate admin actions:

- **Historical backfill:** Filter topics by category and date range, preview the matches, and bulk submit eligible historical topics.
- **Manual submission:** Paste URLs, one per line, to submit specific links instantly. External URLs and ineligible topic URLs are filtered out.

## Localized URLs

When Discourse Content Localization is enabled and crawler locale URLs are available, the plugin generates the main URL and a variant URL for every localization actually present on the topic. URLs use the exact locale query parameter configured in Discourse, usually `?tl=es`, rather than a hardcoded parameter name.

All eligible URLs share a single batch ID in the logs. This keeps the main URL and each locale URL searchable individually while showing they belong to the same submission. If a topic is private, restricted, deleted, excluded, or otherwise ineligible, all localized variants are excluded alongside it.

## Batching and throttling

The plugin attempts to send the `urlList` array in a single request whenever possible. Logical batches larger than 10,000 URLs are split automatically and tracked with a batch index.

Redis counters enforce hourly and daily limits. IndexNow 429 responses set a global throttle deadline using `Retry-After` when provided; otherwise the job uses an increasing retry delay. Rate-limited submissions are recorded as failures with `rate_limit_exceeded`.

## Admin panel

The panel under **Admin > Plugins > discourse-indexnow** includes:

- Plugin and key status.
- Cached public accessibility state for `/<key>.txt`.
- Today's success and failure counts.
- Quota bars showing current usage and time until capacity frees up.
- A seven-day success and failure trend.
- Failure breakdowns for rate limits, key errors, domain mismatches, and other errors.
- Historical backfill preview and submission by category and date range.
- Manual URL submission with one URL per line.
- Batch-aware logs with URL, locale, status, trigger reason, response code, and error filters.
- Pagination and one-click key generation.

The page works through both Ember navigation and direct browser visits or hard refreshes.

## Privacy and safety

Submissions are filtered before enqueueing and re-checked inside the job. The plugin excludes:

- Sites requiring login.
- Private messages.
- Categories with `read_restricted`.
- Unlisted topics, and deleted topics outside the deletion notification event.
- Categories in `indexnow_excluded_category_ids`.
- Topics carrying a tag in `indexnow_excluded_tag_names`.

The key route is intentionally public, returns 404 for unknown keys, and is limited to 100 requests per minute per IP. Generating a new key immediately invalidates the previous key.

## Known limitations

- Google does not participate in IndexNow.
- Localized URLs are submitted only when Content Localization crawler locale URLs are enabled and content exists.

## Development

From a Discourse development checkout:

```sh
bundle exec rspec plugins/discourse-indexnow/spec
```

CI runs the official Discourse plugin workflow on every push and pull request.

## License

MIT
