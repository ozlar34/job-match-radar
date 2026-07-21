-- Scoring columns (additive; existing rows get NULL -> filtered out by scored_at IS NULL guard).
-- Apply manually via the Supabase SQL editor. Do NOT run from n8n.
-- n8n only performs SELECT + UPDATE against the columns defined here.
--
-- Re-scoring idempotency relies on the scored_at IS NULL guard in the upstream SELECT.

ALTER TABLE listings ADD COLUMN IF NOT EXISTS score     integer;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS rationale text;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS scored_at timestamptz;

-- Index for the Phase 5 handoff query (date_seen already indexed in Phase 4; this adds the score path).
CREATE INDEX IF NOT EXISTS listings_scored_at_idx ON listings (scored_at);

-- Supports digest-candidate SELECT ordering (date + score DESC).
CREATE INDEX IF NOT EXISTS listings_date_score_idx ON listings (date_seen, score DESC);

-- ============================================================
-- v2.1 additions — feedback loop + cross-run dedup
-- Applied manually via Supabase SQL editor (same as v2.0 above).
-- ============================================================

ALTER TABLE listings ADD COLUMN IF NOT EXISTS digested_at  timestamptz;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS user_rating  smallint;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS user_feedback text;

-- Supports the digest-candidate SELECT filter (digested_at IS NULL).
CREATE INDEX IF NOT EXISTS listings_digested_at_idx ON listings (digested_at);
