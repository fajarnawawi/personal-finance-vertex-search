# Personal Finance Second Brain

A personal knowledge base that ingests finance podcasts, articles, PDFs, voice memos, and receipts — then lets you query everything through a Telegram bot with grounded answers and source citations.

Built on Vertex AI Search (RAG), AWS Transcribe (audio → text), and Google Tag Gateway (server-side analytics) as a learning project to exercise Google Cloud free credits.

---

## Goals

**Primary goal:** A working personal finance brain over Telegram that I'll actually use day-to-day.

**Learning goals:**
- Exercise Vertex AI Search SKUs end-to-end (indexing, ranking, grounded generation, check grounding, media search, OCR, layout parsing)
- Learn Google Tag Gateway (server-side GTM) on a real project
- Practice cross-cloud architecture (AWS Transcribe → GCP Vertex AI Search)
- Build a production-shaped system solo, without work constraints

**Non-goals:**
- Multi-user support. This is personal, single-tenant.
- Polished UX. Telegram bot is the primary interface; any web UI is secondary.
- Real-time audio streaming. Near-real-time batch is sufficient.
- Financial advice. This is a retrieval/reference tool, not an advisor.

---

## Architecture Overview

Three layers across two clouds:

```
┌─────────────────────────────────────────────────────────────────┐
│                      TELEGRAM (primary UI)                      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   BOT WEBHOOK (Cloud Run, GCP)                  │
│            Routes: question / photo / voice / forward           │
└─────────────────────────────────────────────────────────────────┘
          │                    │                    │
          ▼                    ▼                    ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│   QUERY PATH     │  │   RECEIPT PATH   │  │  INGESTION PATH  │
│                  │  │                  │  │                  │
│ Vertex AI Search │  │  OCR → Gemini    │  │  RSS watcher →   │
│ (media+generic)  │  │  → BigQuery      │  │  AWS Transcribe  │
│ → Grounded Gen   │  │                  │  │  → GCS → Vertex  │
│ → Check Grounding│  │                  │  │                  │
└──────────────────┘  └──────────────────┘  └──────────────────┘
          │                    │                    │
          └────────────────────┼────────────────────┘
                               ▼
              ┌────────────────────────────────┐
              │  GOOGLE TAG GATEWAY (Cloud Run)│
              │  tags.askfajar.com             │
              │  → GA4 + BigQuery events table │
              └────────────────────────────────┘
```

### Data stores

| Store | Content | Query type |
|---|---|---|
| Vertex AI Search — Media datastore | Podcast + video transcripts with timestamps | Semantic, returns timestamp citations |
| Vertex AI Search — Generic datastore | Notes, PDFs, newsletter text, receipt OCR text, forwarded articles | Semantic, returns document citations |
| BigQuery `receipts` table | Structured receipt data (merchant, amount, category, line items) | SQL, for quantitative queries |
| BigQuery `podcasts` table | Episode metadata, indexing status | SQL, for `/podcasts` command |
| BigQuery `events` table | All bot and query events | SQL, for usage analysis |
| S3 bucket | Raw podcast MP3s, voice memos, Transcribe output JSON | Source of truth for audio |
| GCS buckets | Transcribed chunks, PDFs, receipt images, cleaned text | Source of truth for indexed content |

### Cloud split rationale

- **AWS:** Transcribe (handles English + Indonesian well, free credits available), S3 for audio storage (cheap egress-free-within-AWS).
- **GCP:** Vertex AI Search (the point of the project), BigQuery (analytics), Cloud Run (bot webhook + tag server), GCS (indexed content).
- **Vercel:** Optional dashboard for corpus browsing / spend viz. Deferred past milestone 1.

### Cross-cloud auth

Workload Identity Federation between AWS Lambda and GCP service accounts. No long-lived service account keys stored in AWS. Lambda assumes a GCP identity via OIDC to write to GCS and trigger Vertex AI Search ingestion.

---

## Ingestion Pipelines

### Pipeline 1: Podcast RSS → Transcribe → Index

Triggered: Cloud Scheduler every 30 minutes

```
1. RSS watcher polls 3 feeds:
   - Motley Fool Money (en-US, ~5 episodes/week)
   - Investing Insights from Morningstar (en-US, ~1-2/week)
   - Cuap Cuap Cuan (id-ID, ~1-2/week, possibly manual ingestion)

2. For each new episode (compared to last_seen_guid):
   - Download MP3 to S3: s3://finance-brain-audio/podcasts/{feed}/{guid}.mp3
   - Submit AWS Transcribe batch job with language_code from feed config
   - Insert row in BQ podcasts table with status='transcribing'

3. On Transcribe job completion (EventBridge → Lambda):
   - Fetch transcript JSON from S3
   - If language_code == 'id-ID': run Gemini cleanup pass for EN finance terms
   - Chunk transcript into 60-90s windows with 10-15s overlap
   - Preserve start_timestamp_sec on every chunk
   - Write chunks + metadata to GCS: gs://finance-brain-ingest/podcasts/{episode_id}/
   - Trigger Vertex AI Search media datastore import
   - Update BQ podcasts row with status='complete', transcript_gcs_uri
   - Send Telegram notification: "🎧 New episode indexed: {title}"
```

End-to-end latency: 5-15 min from publish to queryable.

### Pipeline 2: Voice Memo → Transcribe → Index

Triggered: User sends voice message to Telegram bot

```
1. Bot receives voice message (OGG format from Telegram)
2. Bot uploads to S3: s3://finance-brain-audio/voice-memos/{user_id}/{timestamp}.ogg
3. Bot acks user: "📝 Transcribing..."
4. Transcribe batch job (batch is fine for milestone 1; streaming is a later upgrade)
5. On completion → push to GCS → index in generic datastore
6. Bot sends transcript back: "✅ Indexed. Transcript: [text preview]"
```

### Pipeline 3: Receipt Photo → OCR → Extraction → BigQuery + Index

Triggered: User sends photo to Telegram bot

```
1. Bot receives photo, uploads to GCS: gs://finance-brain-receipts/{user_id}/{timestamp}.jpg
2. Vertex AI Search OCR for Document Understanding extracts raw text
3. Gemini structured output extracts fields:
   {
     merchant_name, merchant_category, transaction_date,
     currency, subtotal, tax, service_charge, total,
     payment_method, line_items: [{description, quantity, price}]
   }
4. Category chosen from fixed taxonomy (see below)
5. Bot replies with extracted fields for confirmation:
   "📸 Receipt from {merchant}, {total} on {date}. Category: {category}. Confirm? ✅/✏️"
6. On user confirm → insert row in BQ receipts table, index OCR text in generic datastore
7. On user edit → allow inline correction via Telegram buttons
```

**Fixed category taxonomy:**
- Groceries
- Dining
- Transport
- Utilities
- Healthcare
- Shopping
- Entertainment
- Wedding (temp category through May 2026)
- Other

### Pipeline 4: Forwarded Link → Fetch → Index

Triggered: User forwards message with URL to bot

```
1. Bot extracts URL(s) from forwarded message
2. Fetch content:
   - If PDF: download → Layout Parsing → extract structured content
   - If HTML article: fetch → readability extraction → clean text
3. Push to GCS: gs://finance-brain-ingest/articles/{hash}/
4. Index in generic datastore with source URL as metadata
5. Bot acks: "🔗 Indexed: {title}"
```

### Pipeline 5: Manual Upload (CCC fallback)

Triggered: User sends MP3 attachment to bot with `/add_episode` command

```
1. Bot receives audio file + command args (title, show_name)
2. Upload to S3
3. Enter standard podcast transcription pipeline
```

---

## Query Flow

### Query router

When bot receives a text message (not a command), classify intent:

```
Quantitative indicators:
  - "how much", "total", "average", "sum", "spend"
  - Category names, date ranges, merchant names
  → Route to BigQuery receipts

Qualitative indicators:
  - "what did", "who said", "explain", "compare", "opinion"
  - Topic words, episode references
  → Route to Vertex AI Search

Ambiguous → try both, merge, let Gemini decide relevance
```

Start with keyword/regex classifier. Upgrade to LLM router if accuracy is poor.

### RAG query flow (qualitative)

```
1. Detect query language (EN vs ID)
2. Fan out to both datastores in parallel:
   - Media datastore (Media Search API)
   - Generic datastore (Search API Standard + LLM Add-on)
3. Apply Ranking to re-score results from each
4. Merge top-K from both (K=5 each typically)
5. Pass merged context to Advanced Generative Answers
   - Include citation instructions: media cites with timestamp, generic with source
6. Run Check Grounding on generated answer
7. If grounding score < threshold (e.g. 0.7), add warning footer
8. Format response for Telegram:
   - Answer text
   - Sources list with clickable deep links (YouTube ?t= or Spotify episode link)
   - Thumb up/down buttons for feedback
```

### SQL query flow (quantitative)

```
1. Gemini converts natural language → SQL against receipts schema
2. Validate SQL (whitelist of allowed operations — SELECT only, no DELETE/UPDATE)
3. Execute in BigQuery
4. Gemini formats result as natural language + optional table
5. Return to user
```

### Web Grounded Generation (special cases)

For queries with live-data indicators ("current", "latest", "today", "now", regulatory questions), add Web Grounded Generation as a third source. Costs more per query, so gate behind keyword detection.

---

## Telegram Bot Interface

### Message types handled

| Input | Handler | SLA |
|---|---|---|
| Text (question) | Query router → answer | < 10s |
| Photo | Receipt pipeline | < 30s to confirmation prompt |
| Voice memo | Voice transcription pipeline | < 60s for typical 1-2 min memo |
| Forwarded message with URL | Link ingestion pipeline | < 30s |
| Document (PDF, audio file) | Manual upload pipeline | Depends on size |

### Commands

| Command | Behavior |
|---|---|
| `/start` | Welcome + quick help |
| `/help` | Full command reference |
| `/podcasts` | List last 10 indexed episodes with dates |
| `/spend` | Current month spend summary by category |
| `/spend [month]` | Spend summary for specified month |
| `/sources` | Stats on indexed corpus (count by type) |
| `/status` | System health: queue depth, last index time |
| `/add_episode` | Manual podcast upload (for CCC fallback) |
| `/export` | Export receipt data as CSV |
| `/feedback` | Send arbitrary feedback to logs |

### Response formatting

- Use Telegram MarkdownV2 for formatting
- Citations as inline links where possible
- For timestamp citations: `🎧 [MFM 2026-04-20 @ 23:14](https://...)`
- Keep answers under 4096 chars (Telegram limit); split if longer
- Always include a feedback row (👍 / 👎) via inline keyboard

---

## Data Schemas

### BigQuery: `receipts`

```sql
CREATE TABLE receipts (
  receipt_id STRING NOT NULL,
  uploaded_at TIMESTAMP NOT NULL,
  merchant_name STRING,
  merchant_category STRING,  -- from fixed taxonomy
  transaction_date DATE,
  currency STRING,  -- IDR, USD, etc.
  subtotal NUMERIC,
  tax NUMERIC,
  service_charge NUMERIC,
  total NUMERIC,
  payment_method STRING,
  line_items ARRAY<STRUCT<
    description STRING,
    quantity NUMERIC,
    unit_price NUMERIC,
    line_total NUMERIC
  >>,
  raw_ocr_text STRING,
  image_gcs_uri STRING,
  ocr_confidence FLOAT64,
  extraction_model_version STRING,
  user_confirmed BOOL,
  user_edits STRING  -- JSON of any fields user corrected
)
PARTITION BY DATE(uploaded_at)
CLUSTER BY merchant_category, transaction_date;
```

### BigQuery: `podcasts`

```sql
CREATE TABLE podcasts (
  episode_id STRING NOT NULL,  -- RSS GUID
  feed_name STRING NOT NULL,
  feed_language STRING NOT NULL,  -- en-US, id-ID
  episode_title STRING,
  episode_description STRING,
  publish_date TIMESTAMP,
  duration_seconds INT64,
  mp3_s3_uri STRING,
  transcript_gcs_uri STRING,
  indexed_at TIMESTAMP,
  status STRING,  -- pending / transcribing / indexing / complete / failed
  transcript_word_count INT64,
  transcribe_confidence_avg FLOAT64,
  transcribe_job_id STRING,
  error_message STRING
)
PARTITION BY DATE(publish_date);
```

### BigQuery: `events`

```sql
CREATE TABLE events (
  event_id STRING NOT NULL,
  event_timestamp TIMESTAMP NOT NULL,
  event_name STRING NOT NULL,
  user_id STRING,  -- Telegram user ID (hashed)
  session_id STRING,
  properties JSON,
  source STRING  -- 'telegram_bot', 'web', etc.
)
PARTITION BY DATE(event_timestamp)
CLUSTER BY event_name;
```

### Event taxonomy

| Event name | Key properties |
|---|---|
| `query_submitted` | query_text, detected_language, classified_type |
| `answer_returned` | query_id, latency_ms, citation_count, grounding_score, used_web_grounding |
| `citation_clicked` | query_id, source_type, position |
| `timestamp_jumped` | query_id, episode_id, timestamp_sec |
| `receipt_uploaded` | merchant, amount, category, currency, ocr_confidence |
| `receipt_confirmed` | receipt_id, user_edited |
| `voice_memo_received` | duration_sec, transcript_word_count |
| `link_forwarded` | domain, content_type |
| `episode_indexed` | feed_name, episode_id, transcribe_duration_sec |
| `answer_rated` | query_id, rating (up/down) |
| `command_invoked` | command_name |

### Vertex AI Search metadata schema

On every indexed document, attach:

```json
{
  "source_type": "podcast | article | pdf | voice_memo | receipt | note",
  "language": "en | id",
  "created_at": "ISO timestamp",
  "source_name": "Motley Fool Money | Morningstar | ...",
  "source_id": "episode GUID or URL hash",
  "title": "...",
  "chunk_start_sec": 123,  // media only
  "chunk_end_sec": 213,     // media only
  "original_uri": "s3:// or gs:// or https://"
}
```

---

## SKU Utilization Plan

| SKU | Used in | Expected volume |
|---|---|---|
| Data Index | Both datastores | ~6 hrs/week podcasts + ~10 receipts/week + articles |
| Search API — Standard | Generic datastore queries | Every text query |
| Search API — LLM Add-on | Enables gen answers on generic | Every text query |
| Media Search API | Podcast queries | Every qualitative query (fanout) |
| Ranking | Both datastores | Every query |
| Layout Parsing | PDF ingestion | Occasional (forwarded PDFs) |
| OCR for Document Understanding | Receipt pipeline | Every receipt |
| Grounded Generation | Answer synthesis | Every qualitative query |
| Advanced Generative Answers | Answer with follow-ups | Every qualitative query |
| Check Grounding | Post-hoc verification | Every generated answer |
| Web Grounded Generation | Live-data queries | Gated by keyword detection |

**Not used:** Healthcare SKUs (3) — not applicable to personal finance.

---

## Google Tag Gateway Setup

Server-side GTM container hosted on Cloud Run at `tags.askfajar.com`.

### Container configuration

**Trigger:** HTTP event on `/collect` endpoint from bot backend.

**Variables:**
- Event name
- User ID (hashed Telegram ID)
- Session ID
- All custom properties from event payload

**Tags:**
1. GA4 event tag → GA4 property (for dashboards, retention, funnels)
2. BigQuery tag → `events` table (for SQL analysis, joins with receipts/podcasts)

### Why server-side for a bot

This project has no browser frontend, so the "server-side" pattern is literally the only pattern. Bot backend (Cloud Run) calls `tags.askfajar.com/collect` with event payloads. Gateway forwards to GA4 + BigQuery. This is a cleaner learning setup than typical web-tracking server-side, because there's no client/server hybrid to confuse things.

### Privacy

Single-user (me). Telegram user IDs are hashed before sending. No PII in event payloads. Receipt amounts are logged (they're mine anyway).

---

## Milestones

### Milestone 1: End-to-end thin slice (2-3 weekends)

**Scope:**
- AWS: S3 bucket, Transcribe batch pipeline, RSS watcher for 3 feeds
- GCP: Media + generic datastores, Cloud Run bot webhook, BQ schemas deployed
- Telegram bot handles: text questions, photo receipts, voice memos
- Commands: `/podcasts`, `/help`, `/status`
- Tag Gateway deployed, events flowing for `query_submitted`, `receipt_uploaded`, `episode_indexed`
- 10 test podcast episodes indexed, 10 test receipts processed

**Explicitly deferred:**
- Web dashboard (Vercel)
- Forwarded link handler
- `/spend` command
- Web Grounded Generation
- Streaming transcription for voice memos (use batch)
- Gemini cleanup pass for ID podcasts

**Done =** I can ask the bot a question about a Motley Fool episode and get a grounded answer with a clickable timestamp, AND I can snap a receipt photo and see it in BigQuery within 60 seconds.

### Milestone 2: Quality + coverage (2 weekends)

- Forwarded link handler with Layout Parsing for PDFs
- `/spend` command with category breakdown
- Gemini cleanup pass for `id-ID` transcripts
- Web Grounded Generation gated by keyword detection
- Telegram confirmation flow for receipts (edit fields before commit)
- Cuap Cuap Cuan ingestion path (RSS if available, else manual)

### Milestone 3: Feedback loop + dashboard (1-2 weekends)

- Answer rating buttons → `answer_rated` events
- Vercel dashboard:
  - Spend trends (from receipts)
  - Corpus browser (indexed content by source)
  - Query quality view (grounding scores, low-confidence queries)
- BigQuery scheduled queries for weekly insights (sent as Telegram summary)

### Milestone 4: Nice-to-haves (open-ended)

- Streaming transcription for voice memos
- Ticker symbol post-processing for US equity podcasts
- `/export` receipts to CSV
- Cross-source insights ("Morningstar is bullish on X, but my spend pattern shows...")
- OCR for scanned bank statements

---

## Open Decisions

Tracked here until resolved:

- [ ] **Cuap Cuap Cuan RSS availability** — verify before building. If unavailable, milestone 1 starts with 2 feeds only.
- [ ] **Telegram user allowlist** — hardcoded single user ID, or small allowlist? (Probably single user to start.)
- [ ] **Vercel dashboard: build or skip?** — deferred to milestone 3; may skip entirely if Telegram + BigQuery UI is enough.
- [ ] **Secrets management** — Google Secret Manager for everything, or split between AWS Secrets Manager + GCP Secret Manager along cloud lines?
- [ ] **Telegram bot framework** — `python-telegram-bot` vs `aiogram` vs raw webhook handler. Leaning `python-telegram-bot` for familiarity.

---

## Tech Stack Summary

| Layer | Technology |
|---|---|
| Bot webhook | Python 3.11+ on Cloud Run |
| Bot framework | python-telegram-bot (v20+, async) |
| RSS watcher | Python on AWS Lambda + EventBridge cron |
| Transcription | AWS Transcribe (batch) |
| Audio storage | AWS S3 |
| Indexed content storage | GCS |
| RAG | Vertex AI Search (Discovery Engine) |
| Structured data | BigQuery |
| LLM for extraction/cleanup | Gemini 2.5 Flash via Vertex AI |
| Analytics | Google Tag Gateway (Cloud Run) → GA4 + BigQuery |
| Optional dashboard | Next.js on Vercel |
| IaC | Terraform (eventually; start with gcloud/aws CLI scripts) |
| Secrets | Google Secret Manager (primary), AWS Secrets Manager (for Lambda) |
| Monitoring | Cloud Logging + Cloud Monitoring |

---

## Repository Structure

```
finance-brain/
├── README.md
├── CLAUDE.md                    # Context for Claude Code sessions
├── PROJECT.md                   # This document
├── .env.example
├── pyproject.toml
│
├── bot/                         # Telegram bot (Cloud Run)
│   ├── main.py                  # Webhook entrypoint
│   ├── handlers/
│   │   ├── text.py              # Query routing
│   │   ├── photo.py             # Receipt pipeline
│   │   ├── voice.py             # Voice memo pipeline
│   │   ├── document.py          # Forwarded links/PDFs
│   │   └── commands.py          # Slash commands
│   ├── query/
│   │   ├── router.py            # Qualitative vs quantitative classifier
│   │   ├── rag.py               # Vertex AI Search + grounding
│   │   └── sql.py               # NL → SQL for receipts
│   ├── extraction/
│   │   ├── receipt.py           # OCR + Gemini structured extraction
│   │   └── transcript_cleanup.py # ID language post-processing
│   ├── analytics/
│   │   └── tag_client.py        # Event forwarding to Tag Gateway
│   └── config.py
│
├── ingestion/                   # AWS Lambda functions
│   ├── rss_watcher/
│   │   ├── handler.py
│   │   └── feeds.yaml           # Feed definitions
│   ├── transcribe_complete/
│   │   └── handler.py           # Post-Transcribe processing
│   └── shared/
│       ├── gcs_client.py        # Via Workload Identity Federation
│       └── vertex_search.py
│
├── tag_server/                  # Server-side GTM container config
│   └── README.md                # Setup instructions (container is configured via UI)
│
├── infra/
│   ├── terraform/               # Eventually
│   └── scripts/                 # gcloud/aws CLI bootstrap scripts
│       ├── bootstrap_gcp.sh
│       ├── bootstrap_aws.sh
│       └── create_datastores.sh
│
├── schemas/
│   ├── bigquery/                # BQ table DDL
│   │   ├── receipts.sql
│   │   ├── podcasts.sql
│   │   └── events.sql
│   └── vertex_ai_search/
│       └── metadata_schema.json
│
├── dashboard/                   # Vercel Next.js app (deferred)
│   └── README.md
│
└── docs/
    ├── architecture.md
    ├── runbooks/
    │   ├── onboarding_new_podcast.md
    │   ├── failed_transcription.md
    │   └── reindex_corpus.md
    └── decisions/               # ADRs
```

---

## Success Metrics

Since this is personal + learning-focused, success looks like:

- **Usage:** Am I actually querying the bot at least 3x/week after 1 month?
- **Receipt capture:** Am I logging most real-life receipts via the bot? (Target: 70%+)
- **Answer quality:** Are >80% of answers rated thumbs-up?
- **Grounding:** Is the average Check Grounding score >0.75?
- **Learning:** Can I explain server-side tagging, Vertex AI Search RAG flow, and cross-cloud IAM to someone else fluently?

---

## Cost Guardrails

Free credits cover most of this, but safety limits to avoid runaway bills:

- Cloud Run: max instances = 2 (bot webhook) + 2 (tag server)
- AWS Transcribe: monthly budget alarm at $20
- Vertex AI Search: monitor query count daily; alarm if >500/day (indicates runaway loop)
- BigQuery: slot reservation = none (on-demand), query cost alarm at $5/day
- Cloud Scheduler: no more than 48 invocations/day
