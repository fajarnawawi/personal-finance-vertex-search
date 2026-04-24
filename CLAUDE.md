# CLAUDE.md

Context for Claude Code (or any Claude session) working on this repo. Read this first before making changes.

## What this repo is

Personal finance second brain. Ingests podcasts (AWS Transcribe), PDFs, articles, voice memos, and receipts (OCR) → indexes in Vertex AI Search → exposes over Telegram bot with grounded answers + source citations. Instrumented with Google Tag Gateway (server-side GTM) pushing events to GA4 + BigQuery.

**Single user: the repo owner.** No multi-tenancy. Don't add auth complexity, role systems, or user models beyond a hardcoded Telegram user ID allowlist.

**Learning project first, product second.** If there's a boring-production-tested way and an interesting-teaches-something way to do something, lean toward the interesting way unless it creates real risk. Document the reasoning in an ADR under `docs/decisions/`.

Read `PROJECT.md` for the full plan. This file is the working-with-the-code companion.

## Architecture quick reference

Two clouds, deliberately:

- **AWS** — S3 (audio storage), Lambda (RSS watcher, Transcribe completion handler), Transcribe (batch transcription). Lambda writes cross-cloud to GCP via Workload Identity Federation — no long-lived service account keys in AWS.
- **GCP** — Cloud Run (bot webhook + tag server), Vertex AI Search (two datastores: media + generic), BigQuery (receipts, podcasts, events), GCS (indexed content, receipt images), Gemini (via Vertex AI for receipt extraction + transcript cleanup).

Telegram bot is the primary UI. Optional Vercel dashboard is deferred past milestone 1 — don't build it unless explicitly asked.

## Current milestone

Check `PROJECT.md` → Milestones section for current scope. Don't build features from later milestones unless the user explicitly asks. If a change would require work from a deferred milestone, surface that tradeoff rather than silently expanding scope.

## Coding conventions

### Language and framework

- Python 3.11+ for all backend code (bot, Lambda functions)
- `python-telegram-bot` v20+ (async, not the legacy sync API)
- `async def` handlers throughout — the bot is I/O-bound (Telegram API, Vertex AI Search, BigQuery), not CPU-bound
- Type hints required on function signatures. Internal types OK to skip.
- `uv` or `pip-tools` for dependency management; pin versions in `pyproject.toml`

### Error handling philosophy

- **User-facing errors on Telegram** should be actionable, not technical. "Couldn't transcribe — file might be corrupted, try again?" not "AWS Transcribe returned 400 ValidationException."
- **Logs** should carry full technical detail + a correlation ID. Every bot interaction gets a `request_id` that threads through all downstream calls and logs.
- **Never catch broad `Exception`** without re-raising or logging with full traceback. Silent swallowing has bitten me before — don't do it.
- **Transient failures** (Transcribe throttling, Vertex AI Search 503s) get retried with exponential backoff. Permanent failures (malformed audio, invalid receipt image) get surfaced to the user and logged.

### Secrets

- Never hardcode. Never commit to `.env` files that aren't `.env.example`.
- Google Secret Manager is the primary store. AWS Secrets Manager for things Lambda needs.
- Local dev: `.env` file (gitignored), loaded via `python-dotenv`.
- In Cloud Run: secrets mounted as env vars via Secret Manager integration, not fetched at runtime.

### Cost-awareness

This project runs on free credits but those will run out. Every new feature that calls a billable API should answer:

1. What SKU does this hit?
2. How many times per user action?
3. Is there a cheaper path that gets 80% of the value?

Annotate expensive code paths with a comment: `# BILLABLE: Vertex AI Search Ranking, ~$X per 1k queries`

### Analytics events

Every meaningful bot interaction should emit an event via `bot.analytics.tag_client`. See `PROJECT.md` → Event taxonomy for the canonical list. If you add a new event type, update the taxonomy doc in the same commit.

Never log PII in event properties. Telegram user IDs are hashed. Receipt amounts are fine (they're mine). Raw query text is fine (also mine).

## Key abstractions to preserve

### Two datastores, not one

There's a **media datastore** (podcast/video transcripts with timestamp metadata) and a **generic datastore** (notes, PDFs, articles, receipt OCR text). Queries fan out to both and merge. Don't collapse them into one store — the timestamp behavior on media is the whole point, and the Media Search API SKU depends on this split.

### Query router

Incoming text queries classify as **quantitative** (→ BigQuery SQL against receipts) or **qualitative** (→ Vertex AI Search RAG). Ambiguous queries try both. The router lives in `bot/query/router.py` and starts as regex/keyword; it can upgrade to an LLM classifier later. Don't skip this split — quantitative queries through RAG give garbage answers.

### Language awareness

Mixed EN/ID corpus. Every indexed document has a `language` metadata field. Every query detects language. Don't hard-filter by language on query — boost instead. Cross-language retrieval is a feature.

### Check Grounding is not optional

Every generated answer runs through Check Grounding. Low-grounding answers get a warning footer, not silent suppression. The grounding score is logged to the `answer_returned` event. This is central to the project — finance hallucinations matter.

### Cross-cloud auth via WIF

AWS Lambda writes to GCS using Workload Identity Federation. Don't regress this to service account keys stored in AWS. If WIF setup is blocking you, ask the user rather than taking the shortcut.

## Things to NOT do

- **Don't add user auth/roles/permissions.** Single user. Hardcoded Telegram ID allowlist is the whole security model.
- **Don't add a web frontend** unless the user explicitly says "build the dashboard now." Telegram is the UI.
- **Don't switch to streaming transcription for podcasts.** Podcasts are pre-recorded; batch is the right fit. See PROJECT.md for the full reasoning. Streaming *may* be added for voice memos later — that's a different decision.
- **Don't add new categories to the receipt taxonomy** without asking. The fixed list is intentional — LLM-freestyled categories make dashboards useless.
- **Don't add new LLM providers.** Gemini (via Vertex AI) is the LLM. Adding OpenAI/Anthropic would fragment secrets, billing, and the "learn GCP deeply" goal.
- **Don't touch the healthcare SKUs.** Not applicable. They're explicitly out of scope.
- **Don't build premature abstractions.** This is a single-user tool with <10 handler types. Concrete code is fine.
- **Don't silently change the event schema.** Events land in BigQuery; schema changes break historical analysis. Additive changes OK, destructive changes need an ADR.
- **Don't commit without running linters.** `ruff check` + `ruff format` before every commit.

## Things to ALWAYS do

- **Read `PROJECT.md` first** if you're unclear on scope or direction.
- **Emit a `request_id` on every bot interaction** and thread it through logs and event properties.
- **Write a runbook entry** under `docs/runbooks/` when you build something that might need operational intervention (failed transcription recovery, re-indexing, etc.).
- **Add cost annotations** on billable code paths.
- **Update the SKU utilization table in PROJECT.md** when a new SKU starts getting used or an existing one changes usage pattern.
- **Write an ADR** under `docs/decisions/` for any non-obvious architectural choice. Format: problem, options considered, decision, consequences.
- **Prefer async I/O** throughout the bot. Blocking calls in async handlers block the entire event loop.
- **Validate inputs from Telegram** — voice memos can be anything, photos can be anything, forwarded links can be anything. Don't trust size, format, or content.

## Local development

### Prerequisites

- Python 3.11+
- `gcloud` CLI authenticated to the project
- `aws` CLI authenticated to the transcription account
- Telegram bot token in `.env` (see `.env.example`)
- `ngrok` or similar for exposing the local webhook to Telegram during dev

### Running the bot locally

```bash
# Install
uv sync  # or: pip install -e .

# Set webhook to ngrok URL
./scripts/set_webhook.sh https://your-ngrok.ngrok.io

# Run
python -m bot.main

# Revert webhook to prod when done
./scripts/set_webhook.sh https://bot.askfajar.com
```

### Testing

- Unit tests: `pytest tests/unit`
- Integration tests (hit real GCP but in a test project): `pytest tests/integration`
- Don't write tests that hit Telegram's API — mock the bot framework.
- Ingestion tests use fixture audio files in `tests/fixtures/audio/`.

## When making changes

### Small change (bug fix, copy tweak, new command)

Just do it. Run linters. Commit.

### Medium change (new handler, new SKU usage, schema addition)

1. Check that it fits the current milestone.
2. Update `PROJECT.md` if you're touching schemas, SKUs, or the event taxonomy.
3. Add cost annotation if billable.
4. Add a runbook entry if operational intervention might be needed.

### Large change (new pipeline, new cloud service, architectural shift)

1. Write an ADR first. Show it to the user before implementing.
2. Update `PROJECT.md` architecture diagram + milestone plan.
3. Break implementation into small commits — don't land a 2000-line PR.

## Prompts for Gemini

Two places Gemini is called: receipt extraction, and ID transcript cleanup. Prompts live in `bot/extraction/prompts/` as `.md` files, loaded at runtime. Treat prompts as code:

- Version them. When a prompt changes, the `extraction_model_version` string in the receipts schema changes too.
- Keep them concise. Long prompts cost more per call and aren't necessarily better.
- Use structured output (JSON schema) for receipt extraction. Free-form output parsing is a pit.
- Don't put user data directly in prompts without escaping. Receipt OCR text can contain injection attempts (rare, but possible with adversarial menus — stay paranoid).

## Common pitfalls (things I've hit or expect to hit)

- **Telegram 10-second webhook timeout.** Long work (transcription, large PDF parsing) must be async via queues. The webhook acks fast and the work happens elsewhere.
- **Transcribe job names must be unique.** Use `{feed}-{guid}-{timestamp}` to avoid collisions on re-runs.
- **Vertex AI Search import is eventually consistent.** After ingestion, allow ~30s before querying. Don't flake tests on this.
- **BigQuery streaming inserts are not free and have quotas.** For high-volume events, consider batch inserts via Pub/Sub → BQ subscription.
- **Telegram MarkdownV2 escaping is a nightmare.** Use a helper (`telegram.helpers.escape_markdown`) religiously or switch to HTML formatting.
- **Indonesian transcripts with code-switching.** `id-ID` Transcribe will mangle English finance terms. Gemini cleanup pass is the fix — don't try to solve this at the Transcribe layer with auto-language-detect.
- **Workload Identity Federation setup is finicky.** Expect to spend a full session getting it right the first time. Document the exact steps in `docs/runbooks/setup_wif.md` when you crack it.
- **Timestamps in Transcribe output are word-level.** Don't naively chunk by character count — respect word boundaries or you'll get broken timestamps.

## Who to ask

Just me (repo owner). If something feels ambiguous, ask in chat rather than guessing. Prefer "I want to do X, which of A/B/C aligns with your intent?" over silently picking one and building.
