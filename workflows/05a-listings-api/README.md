# 05a — Listings Data API

Thin n8n workflow that exposes two HTTP endpoints over the `listings` table so an external scoring caller can run an LLM-driven scoring loop without putting an LLM inside n8n.

**Why this exists:** scoring originally lived inside n8n via an LLM node, but a billing surprise + an SQL bug broke the digest. Splitting scoring out — n8n becomes a thin data API, the LLM lives in the caller — turned out to be much easier to debug and rate-limit.

**Workflow file:** `listings-api.json`

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/webhook/listings/unscored` | Returns rows with `scored_at IS NULL AND date_seen >= CURRENT_DATE - INTERVAL '8 days'`. Phantom-row filter applied. |
| POST | `/webhook/listings/score` | Body: `{id, score, rationale}`. Runs `UPDATE listings SET score, rationale, scored_at = NOW() WHERE id = $1` and returns `{id, score}`. |

## Architecture

```
GET /listings/unscored ─> Postgres: Select Unscored ─> Filter: Drop Phantom Rows ─(response)
POST /listings/score   ─> Postgres: UPDATE Score ─(response)
```

Node inventory (5 total):

| # | Node | Purpose |
|---|------|---------|
| 1 | Webhook: GET listings/unscored | `httpMethod: GET`, `responseMode: lastNode` |
| 2 | Postgres: Select Unscored | `SELECT id, source, title, company, location, description, priority_bonus FROM listings WHERE scored_at IS NULL AND date_seen >= CURRENT_DATE - INTERVAL '8 days'` |
| 3 | Filter: Drop Phantom Rows | `id > 0` — drops the `{success:true}` phantom n8n's Postgres v2 emits on zero-row SELECTs |
| 4 | Webhook: POST listings/score | `httpMethod: POST`, `responseMode: lastNode` |
| 5 | Postgres: UPDATE Score | `executeQuery` with `$1/$2/$3` from `body.score / body.rationale / body.id`, `RETURNING id, score` |

## Caller contract

- **Single-row gotcha:** `GET /listings/unscored` returns a single object (not an array) when exactly one row matches. Callers must wrap with `Array.isArray(r) ? r : [r]`.
- **Skip sentinel:** if the caller can't score a listing, POST `{id: 0, score: 0, rationale: "skip"}`. `id = 0` matches no real row, so the UPDATE no-ops and `scored_at` stays NULL — the listing is retried next run.
- **Score range:** `score` is `integer`. Clamp to `[1, 10]` defensively before posting.

## Credentials

| Credential | Type |
|------------|------|
| Supabase - job-match-radar | `postgres` |

Create the Postgres credential in your n8n instance and re-bind after import. The exported JSON has credential IDs blanked.

## Schema dependencies

Same `listings` table as `05b-digest-email/`. Schema DDL lives at `../05b-digest-email/schema-additions.sql` (the columns this workflow reads/writes were added before the scoring split).

## Operational runbook

**Smoke test the GET:**

```bash
curl -s http://localhost:5678/webhook/listings/unscored | jq .
```

**Smoke test the POST** (no-op against id 0):

```bash
curl -s -X POST http://localhost:5678/webhook/listings/score \
  -H 'Content-Type: application/json' \
  -d '{"id": 0, "score": 0, "rationale": "smoke test"}'
```

## Related

- `../05b-digest-email/README.md` — the email side of the split.
