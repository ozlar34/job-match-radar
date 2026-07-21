-- Listings schema for Job Match Radar.
-- Apply manually via the Supabase SQL editor. Do NOT run from n8n.
-- n8n only performs INSERTs into the table defined here.

CREATE TABLE IF NOT EXISTS listings (
  id              bigserial PRIMARY KEY,
  source          text NOT NULL,                          -- 'linkedin' | 'greenhouse' | 'ashby'
  external_id     text,                                   -- source-provided job ID, nullable (LinkedIn sometimes null)
  url             text NOT NULL,                          -- absolute apply URL; used as dedup fallback when external_id IS NULL
  title           text,
  company         text,
  location        text,
  salary          text,                                   -- pass-through; varies wildly across sources
  description     text,
  priority_bonus  boolean NOT NULL DEFAULT false,
  date_seen       date NOT NULL DEFAULT CURRENT_DATE,     -- D-07 Phase 5 query filters on this
  created_at      timestamptz NOT NULL DEFAULT now()      -- audit only; not queried by Phase 5
);

-- D-04 dedup key. COALESCE handles the case where a source provides no external_id.
-- The unique index is the conflict arbiter for the Postgres node's upsert
-- (ON CONFLICT (source, COALESCE(external_id, url)) DO UPDATE). As of 2026-06-03 the node
-- is a raw executeQuery upsert, NOT insert+skipOnConflict: a re-scrape now refreshes
-- company/title/location/description/date_seen, so a mislabel (e.g. the 2026-05-21
-- static-item bug) self-heals on the next run instead of being frozen by DO NOTHING.
-- company is deliberately NOT in the key (a job is the same job regardless of label; adding it
-- would let a mislabeled + correct row coexist as duplicates).
-- The exact expression (source, COALESCE(external_id, url)) MUST match the node's ON CONFLICT
-- target; any drift here re-opens Pitfall 1 in 04-RESEARCH.md.
CREATE UNIQUE INDEX IF NOT EXISTS listings_dedup_idx
  ON listings (source, COALESCE(external_id, url));

-- D-07 query performance. Cheap at this volume and future-proofs the Phase 5 handoff.
CREATE INDEX IF NOT EXISTS listings_date_seen_idx ON listings (date_seen);
