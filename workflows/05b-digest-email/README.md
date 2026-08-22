# 05b — Digest Email

n8n workflow that selects already-scored listings (`score >= 6`, not yet digested) and emails a ranked HTML digest. Scoring itself happens upstream (see `../05a-listings-api/`), which writes `score / rationale / scored_at` back before this workflow fires.

**Workflow file:** `digest-email.json`
**Webhook:** `POST /webhook/job-digest-run`

## Scope

Reads `score >= 6 AND digested_at IS NULL AND date_seen >= CURRENT_DATE - INTERVAL '8 days' ORDER BY score DESC`, deduplicates by (title, company) preferring non-LinkedIn rows, builds an HTML email, and (if any matches) sends via Gmail and stamps `digested_at = NOW()` on every included listing for cross-run dedup. Empty-candidate runs are suppressed silently.

## Architecture

```
Manual Trigger ──┐
                 ├─> Postgres: Select Digest Candidates ─> Code: Assemble Digest ─> IF: Has Matches ─(true)─> Gmail: Send Digest ─> Postgres: Mark Digested
Webhook Trigger ─┘                                                                  └─(false, unconnected) — silent exit
```

Node inventory (7 total):

| # | Node | Purpose |
|---|------|---------|
| 1 | Manual Trigger | UI testing |
| 2 | Webhook Trigger | `POST /webhook/job-digest-run` — invoked by the digest caller |
| 3 | Postgres: Select Digest Candidates | `score >= 6 AND digested_at IS NULL AND date_seen >= CURRENT_DATE - INTERVAL '8 days'` |
| 4 | Code: Assemble Digest | Phantom filter, cross-source dedup, HTML cards, emits `{subject, html, count, included_ids}` |
| 5 | IF: Has Matches | `count > 0`; false branch unconnected → silent exit on empty digests |
| 6 | Gmail: Send Digest | `emailType: html`, `appendAttribution: false`. **Replace the `sendTo` placeholder with your own address after import.** |
| 7 | Postgres: Mark Digested | `UPDATE listings SET digested_at = NOW() WHERE id = ANY(ARRAY[…]::bigint[])` against `included_ids` |

## Trigger model

Manual / webhook only. There is no Schedule Trigger — the original system was hosted on a laptop-only n8n instance where cron was unreliable. If your n8n runs on always-on infrastructure (VPS, server), re-add a Schedule Trigger as needed.

## Credentials

| Credential | Type |
|------------|------|
| Supabase - job-match-radar | `postgres` |
| Gmail | `gmailOAuth2` |

For self-hosted n8n + Google OAuth: use a Web-application client type in the Google Cloud console, register the exact n8n redirect URI, add your own email as a test user (if the OAuth screen is in testing), and enable the Gmail API on the GCP project. Use the Gmail-specific credential type, not generic Google OAuth2.

The exported JSON has credential IDs blanked and the `sendTo` email replaced with `your-email@example.com`. Re-bind credentials and update the recipient after import.

## Schema dependencies

Column + index DDL lives in `schema-additions.sql`. Apply manually via the Supabase SQL editor (not run from n8n). Adds `score / rationale / scored_at / digested_at / user_rating / user_feedback` to `listings` plus three indexes.

## Digest contract

- **Per-card fields:** score badge (X/10), company, title (linked to `url`), rationale, source tag.
- **Sort:** `score DESC`.
- **No hard cap** on card count. All `score >= 6` rows surface.
- **Empty state:** silent exit (false branch unconnected). No "0 matches" email is sent.
- **Cross-source dedup:** same (lowercased title, lowercased company) pair across sources keeps the non-LinkedIn row.
- **HTML safety:** inline styles only (Gmail mobile strips `<style>`); `escapeHtml` helper on title/company/rationale/url/source.
- **Cross-run dedup:** `Postgres: Mark Digested` stamps `digested_at` on every included listing post-send. Listings never reappear in future digests once stamped.

## Operational runbook

**Manual trigger** (testing): n8n UI → open this workflow → Manual Trigger → Execute. Webhook smoke test:

```bash
curl -X POST http://localhost:5678/webhook/job-digest-run
```

**Today's state:**

```sql
SELECT id, source, company, title, score, digested_at
FROM listings
WHERE date_seen >= CURRENT_DATE - INTERVAL '8 days'
ORDER BY score DESC NULLS LAST;
```

**Re-send a previously digested listing** (rare; use only if the email failed):

```sql
UPDATE listings SET digested_at = NULL WHERE id = <listing_id>;
-- Then fire the webhook.
```

**Re-export after edits:** `mcp__n8n-nodes__n8n_get_workflow` with `mode: "full"` → write to `digest-email.json`.

## Related

- `../05a-listings-api/README.md` — the data API the scoring loop talks to.
- `../03-platform-scrapers/README.md`, `../04-ats-pulls-storage/README.md` — upstream listings producers.
