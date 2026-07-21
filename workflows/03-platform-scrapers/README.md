# Platform Scrapers — Workflow 03

n8n workflow that runs an Apify LinkedIn-jobs actor and normalizes the output into a common schema. Consumed by Workflow 04 (dedup + storage) via the shared `listings` table.

**Workflow file:** `platform-scrapers-main.json`
**n8n import path:** Menu → Import from File → select the JSON.

## Scope

LinkedIn only. Indeed was built, tested, and dropped after manual review showed Indeed DE listings were overwhelmingly German-language and mostly outside the target-company orbit (which skews English-first and LinkedIn-dominant). Additional DACH platforms (XING, StepStone, Bundesagentur) are out of scope for the current pipeline.

## Branches

| Source | Actor | maxItems |
|--------|-------|----------|
| linkedin | `cryptosignals~linkedin-jobs-scraper` | 100 |

Actor IDs use Apify's `username~actor-name` URL-safe format (the `/`-form from docs returns "resource not found" through the n8n community node).

## Search query

LinkedIn `keywords` field uses phrase-OR matching to target a specific role family:

```
"community manager" OR "community lead" OR "head of community" OR "social media manager" OR "community operations" OR "AI project manager" OR "AI program manager" OR "head of social" OR "creator community" OR "product community" OR "community strategy" OR "community operations lead"
```

`location: "Germany"`, `maxItems: 100`, `action: "search"`. Quotes force phrase matching and suppress the "any token" noise (marketing manager, operations manager standalone, etc.) the un-quoted form produced. Adjust the keyword list and location to match your own search intent — this is the rubric the operator has chosen.

## Common output schema

The single `Code: Normalize LinkedIn` node emits items with exactly these fields:

| Field | Type | Notes |
|-------|------|-------|
| title | string \| null | Fall back: `positionName`, `name` |
| company | string \| null | Fall back: `employerName`, `companyName` |
| url | string \| null | Absolute URL; fall back: `jobUrl`, `applyUrl` |
| source | string | Hardcoded `linkedin` |
| location | string | City/region or empty string |
| dateRetrieved | string | ISO 8601 (`new Date().toISOString()`) |
| salary | string \| null | Pass through actor-provided salary field |
| description | string \| null | Pass through actor-provided description |
| externalId | string \| null | Source-side id; used by Workflow 04 dedup |
| **priorityBonus** | boolean | True if title or description matches the configured priority keyword. Promoted to top-of-digest in scoring downstream. |

## Post-scrape filters (inside the Code node)

Applied after normalization, before the workflow output:

1. **Marketing/sales exclusion** — drop items whose title matches: `marketing manager`, `brand manager`, `performance marketing`, `growth marketing`, `sales manager`, `key account`, `business development`, `PR manager`, `communications manager`.

Listings flagged `priorityBonus: true` (title/description matches the configured priority keyword) are kept regardless and pinned to the top of the digest downstream.

Filters are regex-based, case-insensitive.

## Schedule

The original system runs this on a weekly cron (`0 8 * * 2`, Tuesday 08:00 Europe/Berlin) — Tuesday gives a 3-day settle window before the Friday digest. **The workflow exported here has the Schedule Trigger removed** (manual-trigger / webhook only) because cron was unreliable on a laptop-only n8n instance. Re-add a Schedule Trigger if your n8n runs on always-on infrastructure (VPS, server).

- **Per-run cost:** $1.00 (100 events × $0.01 on Apify Pay-Per-Event)
- **Projected monthly cost (weekly run):** ~$4.30
- **Budget ceiling:** $5/mo Apify free tier — leaves ~$0.70/mo headroom for one ad-hoc run

## Credentials

- `Apify account` — Apify API credential in n8n. Create this credential in your n8n instance and re-bind the HTTP Request nodes after import. The exported JSON has the credential ID blanked.

## Re-export procedure

After any workflow edit in the UI, either:

1. Use n8n's Menu → Download on the workflow and overwrite `platform-scrapers-main.json`, or
2. Use the n8n MCP tools (`mcp__n8n-nodes__n8n_get_workflow` with `mode: "full"`) to fetch the canonical state and write it to the file.

Prefer option 2 — it's scriptable and the export includes server-side defaults that the UI download sometimes omits.

## Downstream

Workflow 04 (ATS Pulls + Storage) consumes the `Code: Normalize LinkedIn` output as the single normalized stream. Do not add transformation nodes after the Normalize node in this workflow — additional transformation lives in Workflow 04.

When a second platform is added later, re-introduce a Merge node (mode: Append, 2 inputs) to combine streams before Workflow 04 consumption.

## Storage handoff

Two extra nodes append to this workflow after `Code: Normalize LinkedIn`:

1. `Code: Rename for Supabase` — converts the camelCase normalized output (`priorityBonus`, `externalId`, `dateRetrieved`) into the snake_case `listings` table shape (`priority_bonus`, `external_id`, `date_seen` as `YYYY-MM-DD`).
2. `Postgres: Insert listings` — inserts into the shared Supabase `listings` table using the `Supabase - job-match-radar` credential (Postgres node, `skipOnConflict: true`).

Net flow:

```
... → Code: Normalize LinkedIn → Code: Rename for Supabase → Postgres: Insert listings
```

Dedup happens at the DB level via the `listings_dedup_idx` unique index on `(source, COALESCE(external_id, url))`. See `../04-ats-pulls-storage/README.md` for the full storage schema + coverage map.

The downstream scoring/digest stage consumes LinkedIn + ATS rows uniformly via:

```sql
SELECT * FROM listings WHERE date_seen = CURRENT_DATE;
```
