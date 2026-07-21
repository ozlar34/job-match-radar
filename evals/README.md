# Scoring evals + guardrail + drift

Job Match Radar scores every job listing 1–10 against a personal rubric
([`scoring-prompt.md`](scoring-prompt.md)). An LLM is the judge — and like any LLM judge,
it gets things wrong. It once rated a job **10/10** that explicitly required fluent German.

This directory is the harness that catches those misses. It turns a real, months-long
human-review log into a **regression test suite + human-in-the-loop guardrail + drift log**
for the scoring prompt.

## The 10-second story

> My AI scorer rated a job 10/10 that required fluent German. Here's the eval harness that
> proves the gate catches it now, the guardrail that routes the judge's borderline calls to
> a human, and the drift log that fails the build if a future prompt edit silently regresses
> a gate.

Every case is a **real documented failure** from the live system's scoring-calibration log,
where a human reviewer caught the judge over-scoring a listing and recorded the correction.

## Run it

```bash
# offline regression baseline — replays the historical scores (no model, no API key)
python3 eval.py --judge replay

# re-run the CURRENT prompt live via the headless Claude CLI (no API key needed)
python3 eval.py --judge claude

# against a local Ollama model
python3 eval.py --judge ollama --ollama-model gemma3:4b

# record this run to the append-only drift log, keyed to the rubric version
python3 eval.py --judge claude --record

# show score/status drift across recorded runs + PASS->FAIL regression alerts
python3 eval.py --drift
```

Stdlib only — Python 3.8+, no `pip install`. Exit code is `1` if any *implemented* hard
gate regressed (CI-friendly); known gaps and soft-cap misses don't fail the build.

## The three layers

**(a) Gate eval.** Each case substitutes into the canonical prompt exactly as the
`/run-job-digest` skill does, goes to a judge, and the produced score is checked against the
case's `expected_cap`. A case **PASSES** when `score <= cap` (the gate fired). Cases are
typed: `hard` (a pre-flight auto-cap that must fire), `soft` (a precision/seniority cap), and
flagged `implemented` vs `recommended` — a `recommended` rule not yet coded is a **known GAP**,
not a regression.

**(b) Guardrail (HITL).** Independent of pass/fail, every output is routed to a human-review
queue when the score and its own rationale **disagree** — a cap-level score that names no
disqualifier, or a strong score whose rationale names a hard reject (the documented Company A-10
failure mode) — or when the score lands in the borderline `5–6` human-decision band. This
mirrors the `/job-digest-review` ritual the calibration log came from.

**(c) Drift log.** `--record` appends each run to [`drift-log.jsonl`](drift-log.jsonl), keyed
to the rubric version (its `Last sync` tag + a sha of the prompt block). `--drift` prints the
per-case trajectory across runs and flags any `PASS→FAIL` regression *within a judge* — so a
prompt edit that silently breaks a gate is caught here, not three weeks later at the next
digest review.

## What's recorded (the before/after proof)

The shipped drift log already contains both halves of the story against rubric `sync=2026-06-17`:

| Run | Judge | Result |
|-----|-------|--------|
| `r1` | `replay` (before) | **0/11** gates fired — the documented historical misses |
| `r2` | `claude` (after, live, current prompt) | **11/11** gates fired, 0 regressions |

## The cases

| Case | Gate | Type | Cap | Logged miss |
|------|------|------|-----|-------------|
| `company-a-tech-pm` | German fluency required (Q2) | hard | ≤2 | scored **10** |
| `company-b-organized-play` | Italian/Portuguese fluency (Q2) | hard | ≤2 | scored 6 |
| `company-i-community-mgr` | comp below comp floor (Q5) | hard | ≤2 | scored 6 |
| `company-d-community-iberia` | territory-named title | hard | ≤4 | scored 7 |
| `company-c-ai-innovation` | office-first, non-Berlin | hard | ≤3 | scored 7 |
| `n8n-senior-pm-enterprise` | Senior PM soft-cap | soft | ≤8 | scored 9 |
| `company-e-pm-paris-hybrid` | hybrid, non-Berlin *(recommended)* | hard | ≤3 | scored 6 |
| `company-f-senior-manager` | enterprise title-inflation *(recommended)* | soft | ≤4 | scored 6 |
| `company-g-german-jd` | non-English JD body (Q1) *(pre-split)* | hard | ≤2 | scored 7 |
| `company-h-german-fluency` | German fluency required (Q2) *(pre-split)* | hard | ≤2 | scored 8 |
| `nonsenior-smm` | non-Senior SMM title (Q3) *(pre-split)* | hard | ≤6 | scored 8 |

## Provenance & no-fabrication

`historical_score` and the calibration dates are the **real** recorded values from the
scoring-calibration log. The `description` fields are **minimal fixtures**: they embed the
trigger phrases the log quotes verbatim (e.g. "Fluency in English & German is required") so a
*live* judge has body text to parse — they are not the original scraped JDs (those aren't
archived), and the `replay` judge doesn't use them at all. `pre-split` cases were scored in
the Gemini era (before the 2026-04-25 split to the current Claude rubric) and are kept for the
rule they document, not as evidence about today's prompt.

[`scoring-prompt.md`](scoring-prompt.md) is a vendored copy of the project's canonical rubric;
point `--prompt` at the canonical file to test it directly.
