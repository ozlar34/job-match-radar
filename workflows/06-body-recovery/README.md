# 06 — Body Recovery (LinkedIn JSON-LD)

**Status:** Live, manual-trigger only by design (`active: false` on import).

## Purpose

Recovers full job descriptions for listings quarantined with `quarantine_reason IS NOT NULL` (typically `no_body`). Targets LinkedIn rows that came back from the Apify scraper with empty `description` fields — those rows can't be scored without a body, so they get quarantined upstream. This workflow is the cheap recovery path before falling back to a paid API.

## Strategy

Public LinkedIn job pages embed a `<script type="application/ld+json">` block with `@type: JobPosting` containing the description, even unauthenticated. This workflow:

1. SELECTs a small batch of quarantined LinkedIn rows (default `batch_size = 5`).
2. HTTP GETs each `url` with a realistic User-Agent.
3. Extracts the JobPosting JSON-LD block.
4. Decodes HTML entities, strips tags.
5. If body length ≥ `min_body_length` (default 200), updates the row and clears its quarantine.

Cheapest possible recovery path — $0 per row. If recovery rate proves poor, fallback is a paid Apify detail-actor (out of scope here).

## Trigger

Manual only. No webhook. No automation. Fire from the n8n UI when you want to run a recovery batch.

## Dry-run mode

The `Set: Config` node has a `dry_run` boolean (default `true`). In dry-run:

- HTTP fetch + JSON-LD extraction runs as normal.
- DB writes are skipped.
- The `Code: Format Preview` node outputs a summary: total, recovered count, recovery rate, sample previews, and per-failure reasons.

Inspect the preview output in the n8n UI. Once recovery quality looks good across 3–5 batches, flip `dry_run` to `false` to enable the live UPDATE branch.

## Live mode

`Code: Filter Recovered` drops failures (they stay quarantined as-is). `Postgres: Update Recovered` writes per-row:

```sql
UPDATE listings
SET description = $1, quarantine_reason = NULL, quarantined_at = NULL
WHERE id = $2
RETURNING id, LENGTH(description) AS body_length;
```

Failures keep their `quarantine_reason` so the next run can retry them.

## Known limits

- LinkedIn may serve a stub or login redirect for some rows. Those surface as `reason: no_jobposting_jsonld` or `reason: too_short_<n>` in the preview. They stay quarantined.
- No cookies/auth. If LinkedIn tightens public-page restrictions in the future, the JSON-LD path may degrade — fallback would be a paid Apify detail-actor.
- No `body_recovered_at` audit column today. To distinguish recovered rows from original-scrape rows in analytics, add `ALTER TABLE listings ADD COLUMN body_recovered_at timestamptz NULL;` and re-add the field to the UPDATE.

## Concurrency landmine (verified empirically)

The n8n HTTP Request node ran 89 fetches in **1.4 seconds** — effectively parallel from LinkedIn's perspective. Recovery rate collapsed from 5/5 (small serial batch) to **7/89** at `batch_size = 100`. LinkedIn responds to bursts with tiny stub bodies that still return HTTP 200; combined with `neverError: true` and `continueRegularOutput`, those silently fall through as `reason: no_jobposting_jsonld`.

**Operating envelope:** keep `batch_size <= 5` per fire. To clear larger backlogs without per-fire UI clicks, the workflow needs one of:

- A Wait node between rows (e.g., 2–5s) so n8n stops bursting.
- Switch the HTTP Request to "execute once per item with delay" via a SplitInBatches + Wait pattern.
- Or just fire small batches manually multiple times.

Until that pacing is added, treat each manual fire as 5 rows max.

## Credentials

| Credential | Type |
|------------|------|
| Supabase - job-match-radar | `postgres` |

The exported JSON has credential IDs blanked. Create the Postgres credential in your n8n instance and re-bind after import.
