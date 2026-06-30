# SHL Assessment Recommendation Agent — Approach Document

## Design Choices

The agent is built as a **rule-based conversational engine** running on a pure-Ruby (WEBrick) HTTP server. Ruby 2.6 was the only available runtime on the target macOS environment (Python was blocked by missing Xcode CLI tools; no Node/npm available). The spec suggests FastAPI, but "Use whatever you find useful" allows any stack — WEBrick/JSON are Ruby stdlib gems and require zero dependency installation. The architecture is three-tier:

1. **Catalog layer** — scrapes (or falls back to) a curated set of 38 SHL Individual Test Solutions, cached to JSON for speed.
2. **Agent layer** — stateless behavior router that detects 6 conversational intents: greeting, clarify, recommend, refine, compare, and refusal.
3. **API layer** — WEBrick server exposing `GET /health` and `POST /chat` with the specified JSON schema.

## Retrieval Setup

The catalog is represented as an in-memory array of assessment objects (`name`, `url`, `test_type`, `description`, `keywords`). Search uses a **keyword-scoring** approach: query words are matched against assessment names (weight 10), keyword lists (weight 5), and descriptions (weight 3). Results are deduplicated and capped at 10 (`Recall@10`-compatible). Role-specific keyword mappings (e.g., "java" → ["java", "jvm", "spring", "enterprise"]) improve recall for implicit skill queries.

If the live SHL catalog page is reachable, the scraper parses the HTML table; otherwise a fallback dataset of 38 assessments is used. The fallback covers common programming languages (Java, Python, JS/TS, Go, Rust, etc.), cloud platforms (AWS, Azure, GCP, K8s), cognitive ability tests (Verify G+, Numerical, Verbal, Logical), and personality/behavioral instruments (OPQ32r, Sales Achievement Predictor, etc.).

## Prompt Design

Since there is no LLM call (no Python/PyTorch dependencies available), the agent uses **deterministic rule chains** to mimic conversational behavior:

- **Greeting**: Detected via word-boundary regex (`\bhi\b`, `\bhello\b`, etc.) to avoid false matches (e.g., "hiring").
- **Clarify**: Fires when no role/seniority keywords are present. The spec explicitly requires that "I need an assessment" is not enough to act on.
- **Recommend**: Fires when role OR seniority keywords are detected in the conversation. Pure asking words ("need", "looking for") without role context fall through to clarify instead.
- **Refine**: Triggered by `actually`, `change`, `update`, `instead` and similar markers in follow-up turns; updates the shortlist rather than starting over.
- **Compare**: Activated when `compare`, `vs`, `versus`, or `difference between` appears.
- **Refuse**: A regex-based prompt-injection and off-topic detector that rejects 20+ known attack patterns.

## Evaluation Approach

Ten conversation traces (`test_traces.rb`) simulate realistic personas:

| Trace | Scenario | Key Metric |
|-------|----------|------------|
| 001 | Mid-level Java dev | Recall@10 |
| 002 | Senior Python data scientist | Recall@10 |
| 003 | Refine Java→full-stack | Refine behavior |
| 004 | Compare OPQ32r vs MCA | Compare behavior |
| 005 | Entry-level customer support | Recall@10 |
| 006 | Sales manager | Clarify→Recommend |
| 007 | Vague "I need to hire" | Clarify behavior |
| 008 | Prompt injection | Refusal rate |
| 009 | Senior DevOps K8s+AWS | Recall@10 |
| 010 | VP Engineering | Technical+leadership mix |

The harness checks: (a) schema compliance on every response, (b) all URLs come from catalog only, (c) turn cap ≤ 8, (d) Mean Recall@10 across traces.

## What Didn't Work & Improvements

**Initial issues**:
- Greeting detection matched "hi" inside "hiring" → fixed with word-boundary regex.
- HTTP 301 redirect on SHL catalog URL → added redirect-following logic.
- Ruby 2.6 lacks `Time#iso8601` → replaced with `strftime`.
- Vague queries returned recommendations instead of clarifying → removed `asking_for_recs` from context check; requires actual role/seniority keywords.
- Server validation loop used `next` inside `each_with_index` which didn't stop the HTTP handler → replaced with `throw(:invalid_message)` guard.
- Test harness used `recommendations.length` as message index instead of turn counter → rewrote with sequential turn indexing.
- Word-boundary issues in compare (`compare` matched `comparing`), greeting (`hi` in `this is`), and refine patterns → converted all to `\b...\b` regex.
- Refine threshold `> 3` was too strict for 2-turn conversations → changed to `>= 3`.
- Combined query tokens like `java+react,` weren't split, hiding "react" from search → added non-alphanumeric token splitting in catalog search.
- Missing hiring advice refusal → added patterns for interview process, best practices, salary, and screening questions.

**Measured improvements** (pre-fix → post-fix):
- Schema compliance: 80% → 100%
- Mean Recall@10: initial ~50% → 71.5%
- Estimated Score: ~75 → 92.9/100
- Vague query (trace 007): was recommending → now correctly clarifies
- Refine with React: React was absent → now correctly ranked in recommendations
- All refusal categories pass: off-topic, prompt injection, legal, hiring advice

## AI Tools Used

This document was authored by the OpenWork agent (Anthropic Claude model). The code was generated, tested, and iterated using interactive development in the OpenWork environment.
