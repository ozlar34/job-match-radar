# ATS Pulls — Workflow 04

n8n workflow that hits a watchlist of companies' public ATS JSON endpoints and inserts new listings into Supabase. Consumed by the scoring/digest stage via `SELECT * FROM listings WHERE date_seen = CURRENT_DATE`. The companies below are placeholders (`Company A`–`I`) — swap in your own watchlist.

**Workflow file:** `ats-pulls-main.json`
**n8n import path:** Menu → Import from File → select the JSON.

## Scope

Example watchlist of companies covered via public Greenhouse + Ashby JSON APIs. The watchlist is editable — add/remove branches to match your own target list.

## Branches (example watchlist)

| # | Company | ATS | Slug | Endpoint URL |
|---|---------|-----|------|--------------|
| 1 | Company A | Greenhouse | company-a | https://boards-api.greenhouse.io/v1/boards/company-a/jobs?content=true |
| 2 | Company B | Greenhouse | company-b | https://boards-api.greenhouse.io/v1/boards/company-b/jobs?content=true |
| 3 | Company C | Greenhouse | company-c | https://boards-api.greenhouse.io/v1/boards/company-c/jobs?content=true |
| 4 | Company D | Greenhouse | company-d | https://boards-api.greenhouse.io/v1/boards/company-d/jobs?content=true |
| 5 | Company E | Greenhouse | company-e | https://boards-api.greenhouse.io/v1/boards/company-e/jobs?content=true |
| 6 | Company F | Ashby | company-f | https://api.ashbyhq.com/posting-api/job-board/company-f?includeCompensation=true |
| 7 | Company G | Ashby | company-g | https://api.ashbyhq.com/posting-api/job-board/company-g?includeCompensation=true |
| 8 | Company H | Ashby | company-h | https://api.ashbyhq.com/posting-api/job-board/company-h?includeCompensation=true |

Each HTTP Request node is set to continue on failure (`onError: "continueRegularOutput"`). A 404 or malformed response from one provider logs the error and lets the other branches proceed.

Greenhouse URLs include `?content=true` to inline the full job description. Greenhouse's content field is HTML; the Normalize Code nodes strip tags before storage.

## Common output schema

Every per-branch `Code: Normalize <Provider> (<company>)` node emits items with exactly the `listings` table shape (snake_case):

| Field | Type | Notes |
|-------|------|-------|
| source | string | One of: `greenhouse`, `ashby` |
| external_id | string \| null | Source-side ID. Greenhouse returns numbers (coerced to string via `String(j.id)`); Ashby returns UUID strings. |
| url | string | Absolute apply URL; Greenhouse `absolute_url`, Ashby `jobUrl` or `applyUrl`. Items with null URL are dropped. |
| title | string \| null | |
| company | string | Hardcoded per branch. |
| location | string | Greenhouse `location.name`; Ashby primary `location` joined with secondary locations on `;`. |
| salary | string \| null | Ashby only (`compensation.compensationTierSummary`); Greenhouse always null. |
| description | string \| null | Greenhouse: tag-stripped `content` (from `?content=true`); Ashby: `descriptionPlain`. |
| priority_bonus | boolean | True if title or description matches `/\b(your-priority-keyword)\b/i`. Promoted to top-of-digest in scoring. |
| date_seen | string | YYYY-MM-DD at normalization time. Stored as `date` (not timestamp) so same-day re-runs collide on the dedup index. |

## Post-scrape filters (inside each Code node)

Applied after normalization, before the workflow output. All Code nodes use identical filter logic:

1. **URL-required drop** — items with null/empty url are dropped (schema requires `url NOT NULL`).
2. **Marketing/sales exclusion** — drop items whose title matches `marketing manager`, `brand manager`, `performance marketing`, `growth marketing`, `sales manager`, `key account`, `business development`, `PR manager`, `communications manager`.
3. **Priority override** — if `priority_bonus` is true, keep the listing regardless of the location filters (priority keyword wins).
4. **Americas-only exclusion** — drop listings whose location matches `americas only`, `us only`, `u.s. only`, `us-only`, `us based`, `us-based`, `canada only`, `latam`, `apac only`, `north america only`.
5. **Location whitelist** — require the location to match one of: `germany`, `deutschland`, `berlin`, `munich`, `münchen`, `hamburg`, `cologne`, `köln`, `frankfurt`, `düsseldorf`, `stuttgart`, `dublin`, `london`, `amsterdam`, `paris`, `madrid`, `barcelona`, `lisbon`, `stockholm`, `copenhagen`, `helsinki`, `vienna`, `zurich`, `warsaw`, `emea`, `europe`, `eu`, `remote`.

Filters are regex-based, case-insensitive. This is one example filter list — adjust to your own market and language requirements.

## Schedule

The original system runs daily at `0 8 * * *` (08:00 Europe/Berlin). **The exported JSON has the Schedule Trigger removed** (manual-trigger only) because the system was originally hosted on a laptop-only n8n instance where cron was unreliable. Re-add a Schedule Trigger if your n8n runs on always-on infrastructure.

- **Cost:** $0/run. All endpoints are public, unauthenticated, and unrate-limited at these volumes.
- **Supabase free tier headroom:** ~100 rows/day × 365 days ≈ 36 MB/year, far below the 500 MB free-tier cap.

Supabase free-tier projects auto-pause after 7 days without DB connections. The daily cron keeps the project warm. If the workflow is disabled for >7 days, unpause the project manually in the Supabase dashboard before reactivating.

## Credentials

- `Supabase - job-match-radar` — Postgres credential. Uses Supabase's Supavisor transaction-mode pooler URL (`aws-0-eu-west-1.pooler.supabase.com:6543`), SSL Require. Create this credential in your n8n instance and re-bind the Postgres nodes after import. The exported JSON has credential IDs blanked.

## Schema

See `schema.sql` for the full DDL. Key invariants:

- Table `public.listings` with 12 columns (10 writable + `id bigserial` + `created_at timestamptz`).
- Unique index `listings_dedup_idx ON listings (source, COALESCE(external_id, url))` enforces dedup at the DB level. Without this exact expression, `INSERT ... ON CONFLICT DO NOTHING` cannot infer the conflict target and duplicate rows would accumulate.
- Secondary index `listings_date_seen_idx` for the scoring/digest handoff query.

Verify the dedup index is in place before running the workflow for the first time:

```sql
SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'listings' ORDER BY indexname;
```

Expect 3 rows including `listings_dedup_idx` with `COALESCE(external_id, url)` in the definition.

## Coverage gaps

The ATS workflow scope is strictly Greenhouse + Lever + Ashby. If a target company runs on Workable, Recruitee, SmartRecruiters, etc., either:

- Rely on the LinkedIn stream (Workflow 03) for fallback coverage, or
- Extend the workflow with a new branch that handles that ATS.

## One-time Supabase setup

1. Create a Supabase project (or any Postgres instance), region of your choice, free tier is fine.
2. Apply `schema.sql` via the Supabase SQL Editor.
3. Copy the Supavisor transaction-mode pooler URL from Settings → Database → Connection pooling.
4. Create an n8n Postgres credential named `Supabase - job-match-radar`: Host, Port `6543`, Database `postgres`, User `postgres.<project-ref>`, Password from project setup, SSL Require.
5. Test the credential (must go green) before activating the workflow.

## How to add a watched company

To wire a new company into the ATS pull pipeline:

### Step 1 — Identify the ATS and board slug

Find the company's careers page and check which ATS provider is in use. Test endpoints in order:

```bash
curl -s -o /dev/null -w "%{http_code}" "https://boards-api.greenhouse.io/v1/boards/<slug>/jobs?content=true"
curl -s -o /dev/null -w "%{http_code}" "https://api.ashbyhq.com/posting-api/job-board/<slug>?includeCompensation=true"
curl -s -o /dev/null -w "%{http_code}" "https://api.lever.co/v0/postings/<slug>?mode=json"
```

A `200` response on any one means you have your ATS and slug. The slug is usually the lowercase company name or a variant (remove spaces, try hyphens).

### Step 2 — Add the branch

Duplicate one of the existing branches (HTTP Request → Normalize Code) in the n8n UI, point the URL at the new endpoint, and update the hardcoded `company` value inside the Code node.

### Step 3 — If the ATS is out of scope

If none of Greenhouse / Ashby / Lever return 200, the company uses an unsupported provider. Either extend the workflow with a new branch type, or rely on LinkedIn coverage (Workflow 03) as best-effort fallback.

### Notes

- Lever endpoint returns an array: `[]` with 200 is valid (no open roles right now) — still add the branch.
- Adding branches does not require schema changes. The `listings` table already handles all three ATS `source` values.

## Re-export procedure

After any workflow edit in the UI, either:

1. Use n8n's Menu → Download on the workflow and overwrite `ats-pulls-main.json`, or
2. Use the n8n MCP tools (`mcp__n8n-nodes__n8n_get_workflow` with `mode: "full"`) to fetch the canonical state.

Prefer option 2 — it's scriptable and the export includes server-side defaults that the UI download sometimes omits.

## Downstream

The scoring/digest stage (Workflows 05a + 05b) consumes new rows via:

```sql
SELECT * FROM listings WHERE date_seen = CURRENT_DATE;
```

Do not add transformation nodes after the Postgres Insert in this workflow. Any cross-source preference logic (e.g. "prefer Greenhouse row over LinkedIn row when both exist for the same company") lives in digest assembly, not here.
