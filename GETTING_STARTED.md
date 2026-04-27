# Getting Started with Claude Code — Finance Brain

This document is your step-by-step guide to working on this project using Claude Code. Follow it in order the first time. After initial setup is done, use the "Starting a new session" section at the top of each working session.

---

## Starting a new session (after initial setup is complete)

Paste this at the start of every Claude Code session:

```
Read CLAUDE.md and PROJECT.md. Current milestone is Milestone 1.
Today I want to work on: [describe what you're doing].
Don't build anything from Milestone 2+ unless I ask explicitly.
```

That's it. The two docs give Claude Code full context so you don't re-explain architecture every time.

---

## Prerequisites checklist

Complete these manually before running any Claude Code commands. These are account/console steps that can't be scripted.

### Google Cloud

- [ ] Create a GCP project. Suggested project ID: `finance-brain-[yourname]`
- [ ] Enable billing on the project (required even for free-credit usage)
- [ ] Note your Project ID — you'll need it in every session
- [ ] Enable APIs — run this once in Cloud Shell or your terminal:
  ```bash
  gcloud services enable \
    run.googleapis.com \
    bigquery.googleapis.com \
    storage.googleapis.com \
    discoveryengine.googleapis.com \
    aiplatform.googleapis.com \
    secretmanager.googleapis.com \
    cloudscheduler.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com
  ```
- [ ] Create a GA4 property at analytics.google.com. Note the Measurement ID (G-XXXXXXX) and the GA4 API secret.

### AWS

- [ ] Confirm your free credits are active in the AWS console
- [ ] Note your AWS Account ID and preferred region (suggest `ap-southeast-1` for latency from Indonesia)
- [ ] Create an IAM user named `finance-brain-lambda` with programmatic access. Save the access key + secret — you won't see the secret again.
- [ ] Permissions for that IAM user: `AmazonTranscribeFullAccess`, `AmazonS3FullAccess` (scope to your bucket later)

### Telegram

- [ ] Message @BotFather on Telegram → `/newbot` → follow prompts
- [ ] Save the bot token (format: `123456789:ABCdef...`)
- [ ] Get your personal Telegram user ID: message @userinfobot, it replies with your ID
- [ ] Note both values — they go into Secret Manager

### Domain

- [ ] Confirm you have access to DNS for `askfajar.com`
- [ ] Plan two subdomains: `bot.askfajar.com` (webhook), `tags.askfajar.com` (tag server)

---

## Phase 0: Repo initialization

Open Claude Code in a new empty directory and run:

```
Initialize the finance-brain repository structure exactly as defined in PROJECT.md under "Repository Structure". 

Create all directories and placeholder files. For each placeholder file, add a one-line comment describing what will go in it. 

Also create:
- pyproject.toml with Python 3.11+, these dependencies: python-telegram-bot[webhooks]>=20.0, google-cloud-bigquery, google-cloud-storage, google-cloud-discoveryengine, google-cloud-aiplatform, boto3, feedparser, httpx, pydantic>=2.0, python-dotenv, ruff
- .env.example with every env var the project needs, values as placeholder strings with descriptions
- .gitignore appropriate for a Python project on GCP/AWS (include .env, __pycache__, .venv, *.pyc, service account key files)
- README.md with a 10-line project summary linking to PROJECT.md and CLAUDE.md

Do not write implementation code yet. Structure only.
```

After this runs, verify the directory tree looks right, then:

```bash
git init
git add .
git commit -m "chore: initial repo structure"
```

---

## Phase 1: Infrastructure — GCP

### Step 1.1: Bootstrap GCP resources

```
Write infra/scripts/bootstrap_gcp.sh — a bash script that creates all GCP resources needed for Milestone 1.

The script should be idempotent (safe to run twice). Use gcloud CLI. Include:

1. GCS buckets:
   - finance-brain-ingest (indexed content: transcript chunks, PDFs, articles)
   - finance-brain-receipts (receipt images)
   Set uniform bucket-level access, region asia-southeast2 (Jakarta).

2. BigQuery dataset: finance_brain
   Region: asia-southeast2

3. BigQuery tables from schemas/bigquery/ DDL files (receipts.sql, podcasts.sql, events.sql)

4. Service account: finance-brain-bot@{PROJECT_ID}.iam.gserviceaccount.com
   Roles: roles/bigquery.dataEditor, roles/storage.objectAdmin, roles/discoveryengine.editor, roles/aiplatform.user

5. Secret Manager secrets (create empty versions — values added manually):
   TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USER_ID, GCP_PROJECT_ID, 
   GA4_MEASUREMENT_ID, GA4_API_SECRET, GEMINI_MODEL

6. Print a summary of what was created and what still needs manual action.

Read CLAUDE.md and PROJECT.md before writing. Use PROJECT_ID as a variable at the top of the script.
```

Then write the BigQuery DDL files:

```
Write schemas/bigquery/receipts.sql, podcasts.sql, and events.sql using the exact schemas defined in PROJECT.md under "Data Schemas". Include CREATE TABLE IF NOT EXISTS, partitioning, and clustering as specified.
```

Run the bootstrap script:

```bash
export PROJECT_ID="your-project-id"
chmod +x infra/scripts/bootstrap_gcp.sh
./infra/scripts/bootstrap_gcp.sh
```

### Step 1.2: Bootstrap AWS resources

```
Write infra/scripts/bootstrap_aws.sh — a bash script using AWS CLI that creates:

1. S3 bucket: finance-brain-audio
   - Prefix structure: podcasts/{feed_name}/, voice-memos/, transcribe-output/
   - Block all public access
   - Region: ap-southeast-1

2. IAM policy: FinanceBrainLambdaPolicy
   Permissions: s3:GetObject, s3:PutObject, s3:ListBucket on finance-brain-audio
   transcribe:StartTranscriptionJob, transcribe:GetTranscriptionJob

3. Attach policy to the finance-brain-lambda IAM user created in prerequisites.

4. EventBridge rule: finance-brain-transcribe-complete
   Event pattern: Transcribe job state change to COMPLETED or FAILED
   Target: Lambda function name finance-brain-transcribe-complete (placeholder, Lambda not created yet)

5. Print summary and remind which steps still need manual Lambda deployment.

Use REGION and ACCOUNT_ID as variables at the top.
```

### Step 1.3: Workload Identity Federation

This is the cross-cloud auth link between AWS Lambda and GCP. Do this carefully.

```
Write docs/runbooks/setup_wif.md — a step-by-step runbook for setting up Workload Identity Federation so AWS Lambda can write to GCS without long-lived service account keys.

Cover:
1. Create a Workload Identity Pool in GCP named finance-brain-aws-pool
2. Add an AWS provider to the pool using the AWS Account ID
3. Create a service account binding: finance-brain-ingest@{PROJECT_ID}.iam.gserviceaccount.com
   Roles: storage.objectCreator on finance-brain-ingest bucket, discoveryengine.editor
4. Generate the credential configuration JSON that Lambda will use
5. How to set the credential JSON as an AWS Secrets Manager secret
6. How to verify the setup with a test aws sts assume-role-with-web-identity call

Be explicit about every gcloud command. This is a learning project — explain why each step is needed, not just what to do.
```

Read the runbook, follow it manually, then note your WIF pool ID and provider ID — you'll need them in the Lambda environment.

### Step 1.4: Create Vertex AI Search datastores

```
Write infra/scripts/create_datastores.sh — a script using gcloud CLI (or curl against the Discovery Engine API if gcloud doesn't support it yet) that creates:

1. Media datastore:
   - Name: finance-brain-media
   - Type: MEDIA
   - Region: global
   - Content config: content with metadata

2. Generic/unstructured datastore:
   - Name: finance-brain-generic
   - Type: GENERIC
   - Region: global
   - Content config: unstructured documents

Also write schemas/vertex_ai_search/metadata_schema.json with the document metadata schema from PROJECT.md — source_type, language, created_at, source_name, source_id, title, chunk_start_sec, chunk_end_sec, original_uri.

After creating datastores, print their IDs — needed in bot config.
```

Note the datastore IDs from the output. Add them to Secret Manager or `.env`.

---

## Phase 2: Infrastructure — Google Tag Gateway

The tag server is a separate Cloud Run service. Google provides a one-click deploy template, but you need to configure it correctly.

```
Write tag_server/README.md with a complete setup guide for Google Tag Gateway on Cloud Run for this project.

Cover:
1. Deploying the server-side GTM container via the Google Tag Manager UI (Settings → Container → Server)
   - Container type: Server
   - Default URL will be a *.run.app URL initially
2. Getting the container config snippet from GTM
3. Deploying to Cloud Run using the GTM-provided container image:
   gcloud run deploy finance-brain-tag-server \
     --image gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable \
     --region asia-southeast2 \
     --max-instances 2 \
     --set-env-vars CONTAINER_CONFIG={your_config_snippet}
4. Mapping the custom domain tags.askfajar.com to the Cloud Run service
5. Configuring the GTM server container:
   - Add a GA4 client
   - Add a GA4 event tag pointing to your GA4 property
   - Add a BigQuery tag pointing to {PROJECT_ID}.finance_brain.events
   - Define the variables: event_name, user_id, session_id, properties
6. Testing: how to send a test event and verify it lands in both GA4 and BigQuery

Note clearly which steps are done in the GTM web UI vs. gcloud CLI.
```

Follow the runbook to deploy the tag server. Once `tags.askfajar.com` is live, proceed.

---

## Phase 3: Bot foundation

### Step 3.1: Config and analytics client

```
Write bot/config.py — loads all config from environment variables (via python-dotenv for local, Secret Manager for Cloud Run).

Include:
- GCP_PROJECT_ID
- TELEGRAM_BOT_TOKEN
- TELEGRAM_ALLOWED_USER_ID (single int, for allowlist check)
- VERTEX_MEDIA_DATASTORE_ID
- VERTEX_GENERIC_DATASTORE_ID
- BIGQUERY_DATASET (default: finance_brain)
- GCS_INGEST_BUCKET
- GCS_RECEIPTS_BUCKET
- TAG_GATEWAY_URL (e.g. https://tags.askfajar.com/collect)
- GEMINI_MODEL (default: gemini-2.5-flash)
- AWS_REGION
- AWS_S3_BUCKET
- GROUNDING_SCORE_THRESHOLD (default: 0.7, float)

Use pydantic BaseSettings for validation. Fail fast on startup if required vars are missing.
```

```
Write bot/analytics/tag_client.py — async HTTP client that sends events to the Tag Gateway.

Interface:
  async def track(event_name: str, properties: dict) -> None

Implementation:
- Generate a unique event_id (UUID)
- Add event_timestamp, source="telegram_bot"
- Hash the user_id (SHA-256, consistent across calls) before sending
- POST to TAG_GATEWAY_URL with the event payload
- Fire-and-forget: don't await or block bot response on analytics
- Log failures with WARNING level, never raise — analytics must never break bot flow
- Include a request_id in every log line

Read CLAUDE.md before writing. Annotate the HTTP call as BILLABLE if applicable.
```

### Step 3.2: Bot entrypoint and middleware

```
Write bot/main.py — the Cloud Run webhook entrypoint for the Telegram bot.

Requirements:
- Use python-telegram-bot v20+ async webhook mode
- On startup: validate config, log datastore IDs, log "Bot ready"
- Middleware: check every incoming update against TELEGRAM_ALLOWED_USER_ID. If not allowed, silently drop (don't send any response — don't leak the bot exists)
- Attach a request_id to every update context (use context.user_data or a custom key)
- Register handlers:
  - MessageHandler(filters.TEXT & ~filters.COMMAND) → handlers/text.py
  - MessageHandler(filters.PHOTO) → handlers/photo.py
  - MessageHandler(filters.VOICE) → handlers/voice.py
  - MessageHandler(filters.Document.ALL) → handlers/document.py (stub for now)
  - CommandHandlers for /start, /help, /podcasts, /status → handlers/commands.py
- Set webhook URL to {BOT_WEBHOOK_URL}/webhook on startup
- Health check endpoint at /health that returns 200 OK

Read CLAUDE.md. Note that Telegram webhook timeout is 10 seconds — any long work must be dispatched async.
```

### Step 3.3: Command handlers

```
Write bot/handlers/commands.py with these async command handlers:

/start — Welcome message explaining what the bot does. Include a quick-start example query and list of commands.

/help — Full command reference. Format nicely for Telegram MarkdownV2.

/status — Query BigQuery for: total indexed episodes (by feed), total receipts logged, last episode indexed timestamp, any podcasts table rows with status='failed' in last 24h. Format as a short status card.

/podcasts — Query BQ podcasts table for last 10 completed episodes ordered by publish_date desc. Format each as: "🎧 {feed_name} | {episode_title} | {publish_date}". Truncate titles at 50 chars.

Each handler should:
- Emit the appropriate analytics event via tag_client.track("command_invoked", {"command_name": ...})
- Use escape_markdown for all dynamic content
- Handle BQ errors gracefully — "Couldn't fetch data right now" not stack traces

Read CLAUDE.md before writing.
```

### Step 3.4: Query handler (text → RAG)

This is the core of the bot. Build it in two passes.

**Pass 1 — router only:**

```
Write bot/query/router.py — classifies incoming text queries as 'quantitative' or 'qualitative'.

Quantitative indicators (route to BigQuery receipts):
  Keywords: how much, total, average, sum, spend, spent, cost, price, berapa, habis
  Category names: groceries, dining, transport, utilities, healthcare, shopping, entertainment, wedding
  Time expressions: this month, last month, this week, january, february, etc.

Qualitative indicators (route to Vertex AI Search):
  Keywords: what did, who said, explain, compare, opinion, think, recommend, discuss, talk about, podcast, episode
  
Ambiguous (neither or both match): route to 'both'

Return type: Literal['quantitative', 'qualitative', 'both']

Write unit tests in tests/unit/test_router.py with at least 10 test cases including Indonesian queries (berapa, habis berapa, apa pendapat).
```

**Pass 2 — RAG path:**

```
Write bot/query/rag.py — handles qualitative queries against Vertex AI Search.

Function: async def query_rag(query_text: str, request_id: str) -> RagResult

Steps:
1. Detect query language (simple heuristic: if >30% words are Indonesian common words, tag as 'id', else 'en')
2. Fan out to both datastores in parallel (asyncio.gather):
   - Media datastore via discoveryengine SearchServiceClient
   - Generic datastore via discoveryengine SearchServiceClient
   Both with ranking enabled (use RELEVANCE boost spec)
3. Merge top 5 from each datastore (10 chunks total)
4. Call Grounded Generation with merged context
5. Call Check Grounding on the result — attach grounding_score to RagResult
6. Format citations:
   - Media: "🎧 {source_name} @ {chunk_start_sec formatted as MM:SS}"
   - Generic: "📄 {source_name} — {title}"
7. Return RagResult(answer, citations, grounding_score, source_types_used)

RagResult is a pydantic model.

# BILLABLE: Media Search API + Search API Standard + LLM Add-on + Ranking + Grounded Generation + Check Grounding — ~6 API calls per query

If grounding_score < GROUNDING_SCORE_THRESHOLD, append to answer:
"⚠️ Low confidence — verify against source."

Read CLAUDE.md. Handle DiscoveryEngine exceptions with retry (max 2, exponential backoff).
```

**Pass 3 — wire to handler:**

```
Write bot/handlers/text.py — the main message handler.

Flow:
1. Emit query_submitted event (query_text, request_id)
2. Send "🔍 Thinking..." typing action to Telegram
3. Call router.classify(text)
4. Based on result:
   - 'qualitative' → call rag.query_rag()
   - 'quantitative' → stub response: "📊 Spend queries coming soon. For now, ask me about podcasts or finance topics!"
   - 'both' → call rag.query_rag() (quantitative deferred to Milestone 2)
5. Format response with citations as inline links
6. Add 👍 👎 inline keyboard
7. Send response
8. Emit answer_returned event (latency_ms, grounding_score, citation_count)

Keep total handler execution under 8 seconds to stay within Telegram webhook timeout. If RAG takes longer, send a "Still working..." message and use send_message from a background task.

Read CLAUDE.md before writing.
```

### Step 3.5: Receipt handler

```
Write bot/extraction/receipt.py — OCR + Gemini structured extraction.

Function: async def extract_receipt(image_gcs_uri: str, request_id: str) -> ReceiptExtraction

Steps:
1. Call Vertex AI Document AI OCR (OCR for Document Understanding SKU) on the GCS image URI
   # BILLABLE: OCR for Document Understanding
2. Take raw OCR text → pass to Gemini with structured output schema:
   {
     merchant_name: str,
     merchant_category: str (must be from fixed taxonomy),
     transaction_date: str (YYYY-MM-DD or null),
     currency: str (IDR/USD/etc),
     subtotal: float | null,
     tax: float | null,
     service_charge: float | null,
     total: float | null,
     payment_method: str | null,
     line_items: [{description, quantity, unit_price, line_total}]
   }
3. If merchant_category is not in taxonomy, map to closest or 'Other'
4. Return ReceiptExtraction pydantic model with ocr_confidence field

Fixed taxonomy: Groceries, Dining, Transport, Utilities, Healthcare, Shopping, Entertainment, Wedding, Other

Prompt lives in bot/extraction/prompts/receipt_extraction.md — load at module init, not inline.

Write bot/extraction/prompts/receipt_extraction.md with a clear extraction prompt. Include: "Return ONLY valid JSON, no markdown backticks, no preamble."
```

```
Write bot/handlers/photo.py — receipt photo handler.

Flow:
1. Bot acks: "📸 Processing receipt..."
2. Download photo from Telegram, upload to GCS receipts bucket
3. Call extract_receipt() 
4. Format confirmation message:
   "📸 *{merchant_name}*
   💰 {currency} {total:,.0f}
   📅 {transaction_date}
   🏷️ {category}
   
   Confirm? ✅ or ✏️ Edit"
5. Send with inline keyboard: [✅ Confirm] [✏️ Edit category]
6. On confirm callback: insert to BQ receipts table + index OCR text in generic datastore
7. Emit receipt_uploaded event (merchant, amount, category, currency, ocr_confidence)
8. On edit callback: show category picker inline keyboard (all 9 categories as buttons)

Handle the callback query handlers for confirm/edit in the same file.
For now, only allow editing the category — other field editing is Milestone 2.

# BILLABLE: OCR for Document Understanding + Gemini generation per receipt
```

### Step 3.6: Voice memo handler

```
Write bot/handlers/voice.py — voice memo handler.

Flow:
1. Bot acks: "📝 Transcribing voice note..."
2. Download OGG from Telegram
3. Upload to S3: s3://finance-brain-audio/voice-memos/{user_id}/{request_id}.ogg
4. Submit AWS Transcribe batch job:
   - JobName: voicememo-{request_id}
   - LanguageCode: auto-detect (use automatic language identification)
   - OutputBucketName: finance-brain-audio
   - OutputKey: transcribe-output/voice-memos/{request_id}.json
5. Poll for completion (max 60s, check every 5s) — voice memos are short
6. Fetch transcript JSON from S3, extract plain text
7. Push transcript to GCS as generic document with metadata:
   {source_type: "voice_memo", language: detected_language, created_at: now}
8. Trigger generic datastore import
9. Reply: "✅ Indexed!\n\n_{transcript preview, first 200 chars}_"
10. Emit voice_memo_received event (duration_sec, transcript_word_count)

Note: AWS Transcribe automatic language identification supports EN + ID. Use it here.
```

---

## Phase 4: Ingestion pipeline (AWS Lambda)

### Step 4.1: RSS watcher Lambda

```
Write ingestion/rss_watcher/feeds.yaml with feed definitions:

feeds:
  - name: motley_fool_money
    rss_url: "https://feeds.megaphone.fm/MLN2155636180"  # verify this is current
    language_code: en-US
    enabled: true
  - name: morningstar_investing_insights
    rss_url: "https://feeds.megaphone.fm/morningstar"  # verify this is current
    language_code: en-US
    enabled: true
  - name: cuap_cuap_cuan
    rss_url: null  # TBD — verify RSS availability first
    language_code: id-ID
    enabled: false  # disabled until RSS URL confirmed

Note at the top: RSS URLs must be verified before use. Check each feed's official podcast page.
```

```
Write ingestion/rss_watcher/handler.py — AWS Lambda function.

Lambda event: scheduled EventBridge cron (every 30 min)

Steps:
1. Load feeds from feeds.yaml (skip disabled feeds)
2. For each enabled feed:
   a. Fetch last_seen_guid from S3 state file: s3://finance-brain-audio/state/{feed_name}/last_guid.txt
   b. Parse RSS feed with feedparser
   c. Find entries newer than last_seen_guid
   d. For each new entry (process oldest first):
      - Download MP3 from entry.enclosures[0].url to S3: podcasts/{feed_name}/{guid}.mp3
      - Submit Transcribe job:
          JobName: {feed_name}-{sanitized_guid}-{timestamp}
          LanguageCode: from feeds.yaml
          Media.MediaFileUri: s3://finance-brain-audio/podcasts/{feed_name}/{guid}.mp3
          OutputBucketName: finance-brain-audio
          OutputKey: transcribe-output/podcasts/{guid}.json
      - Write to BQ podcasts table (via GCS + BQ load, not direct API — Lambda doesn't have direct BQ access)
        Actually: write a JSON record to GCS, Cloud Function picks it up. OR use WIF to call BQ API directly.
        Use WIF + BQ API directly — consistent with cross-cloud auth approach.
      - Update last_seen_guid in S3 state file
3. Log summary: feeds checked, new episodes found, jobs submitted

Use the WIF credential config to authenticate GCS and BQ writes.
Handle feedparser errors gracefully — one bad feed shouldn't kill the others.
```

### Step 4.2: Transcribe completion handler

```
Write ingestion/transcribe_complete/handler.py — AWS Lambda triggered by EventBridge on Transcribe job completion.

Event structure: Transcribe state change event with job name, status, output location.

Steps for COMPLETED status:
1. Parse job name to extract feed_name, guid
2. Fetch transcript JSON from S3 output location
3. Extract word-level items from Transcribe JSON format
4. Chunk into 60-90 second windows with 10-15 second overlap:
   - Each chunk: {text, start_sec, end_sec, word_count}
   - Respect word boundaries — never split mid-word
5. Build document for each chunk:
   {
     id: {guid}-chunk-{index},
     content: chunk.text,
     metadata: {
       source_type: "podcast",
       language: "en" or "id",
       source_name: feed_name,  
       source_id: guid,
       title: episode_title (fetch from BQ podcasts table),
       chunk_start_sec: chunk.start_sec,
       chunk_end_sec: chunk.end_sec,
       original_uri: mp3_s3_uri
     }
   }
6. Write all chunk documents as JSONL to GCS: gs://finance-brain-ingest/podcasts/{guid}/chunks.jsonl
7. Trigger Vertex AI Search media datastore import via Discovery Engine API (using WIF)
8. Update BQ podcasts row: status='complete', transcript_gcs_uri, transcript_word_count, indexed_at
9. Send Telegram notification via Bot API:
   "🎧 New episode indexed: *{episode_title}*\n_{feed_name}_\nAsk me anything about it!"

For FAILED status:
1. Update BQ podcasts row: status='failed', error_message from event
2. Log error with full event details

Note: chunking logic is the most important part to get right.
Write a standalone test in tests/unit/test_chunking.py with a sample Transcribe JSON fixture.
```

---

## Phase 5: Deployment

### Step 5.1: Containerize the bot

```
Write a Dockerfile for the bot service:
- Base: python:3.11-slim
- Non-root user
- Install dependencies from pyproject.toml
- Copy bot/ directory
- CMD: python -m bot.main
- Health check: curl http://localhost:8080/health

Write a .dockerignore excluding .env, __pycache__, tests/, docs/, infra/, .git

Write infra/scripts/deploy_bot.sh that:
1. Builds the container image: gcr.io/{PROJECT_ID}/finance-brain-bot:latest
2. Pushes to Google Container Registry
3. Deploys to Cloud Run:
   - Service name: finance-brain-bot
   - Region: asia-southeast2
   - Max instances: 2
   - Min instances: 0 (scale to zero)
   - Memory: 512Mi
   - CPU: 1
   - Port: 8080
   - Secrets mounted from Secret Manager as env vars
   - Service account: finance-brain-bot@{PROJECT_ID}.iam.gserviceaccount.com
4. Maps custom domain bot.askfajar.com
5. Sets Telegram webhook to https://bot.askfajar.com/webhook
```

### Step 5.2: Deploy Lambda functions

```
Write infra/scripts/deploy_lambdas.sh that:

1. Creates a Lambda deployment package for rss_watcher:
   - pip install feedparser boto3 google-auth google-cloud-bigquery into a package dir
   - zip with ingestion/rss_watcher/ and ingestion/shared/
   - Create/update Lambda function:
       Name: finance-brain-rss-watcher
       Runtime: python3.11
       Handler: handler.lambda_handler
       Timeout: 300s (5 min — download can be slow)
       Memory: 512MB
       Environment: AWS_REGION, GCS_INGEST_BUCKET, BQ_DATASET, GCP_PROJECT_ID, GCP_WIF_CREDENTIAL (from Secrets Manager)

2. Same for transcribe_complete Lambda:
       Name: finance-brain-transcribe-complete
       Timeout: 120s
       Trigger: EventBridge rule finance-brain-transcribe-complete

3. Create EventBridge rule for RSS watcher:
       Schedule: rate(30 minutes)
       Target: finance-brain-rss-watcher

Print ARNs of created resources.
```

---

## Phase 6: End-to-end smoke test

Once everything is deployed, verify the full Milestone 1 flow:

```
Write docs/runbooks/smoke_test_milestone1.md with a step-by-step smoke test:

1. Bot reachability: send /start to the bot. Expect welcome message within 5s.

2. Status check: send /status. Expect BQ query response with 0 episodes (fresh). If BQ error, check service account permissions.

3. Receipt test: 
   - Take a photo of any receipt (or use a test image from tests/fixtures/receipts/)
   - Send to bot
   - Expect: confirmation message with extracted fields within 30s
   - Tap ✅ Confirm
   - Verify: row appears in BQ receipts table within 60s
   - Query: SELECT * FROM finance_brain.receipts ORDER BY uploaded_at DESC LIMIT 1

4. Voice memo test:
   - Record a 30-second voice note: "This is a test of the finance brain. I'm thinking about investing in index funds for retirement."
   - Send to bot
   - Expect: "📝 Transcribing..." then transcript confirmation within 90s

5. RSS trigger test:
   - Manually invoke the rss_watcher Lambda from AWS console
   - Check CloudWatch logs for feed parsing activity
   - Wait 10-15 minutes for Transcribe to complete
   - Check BQ podcasts table: SELECT * FROM finance_brain.podcasts ORDER BY indexed_at DESC LIMIT 5
   - Expect at least one row with status='complete'

6. RAG query test (requires at least one indexed episode):
   - Send to bot: "What was discussed in the latest Motley Fool episode?"
   - Expect: grounded answer with at least one citation
   - Check BQ events table for query_submitted and answer_returned events

7. Tag Gateway test:
   - Check GA4 real-time view — events should appear within 30s
   - Query BQ: SELECT event_name, COUNT(*) FROM finance_brain.events GROUP BY 1
   - Expect: query_submitted, answer_returned, receipt_uploaded events present

Document any failures and their resolution in a "Known issues" section at the bottom.
```

---

## Common Claude Code session patterns

### Adding a new feature

```
I want to add [feature name].
It's part of Milestone [N] in PROJECT.md.
Read CLAUDE.md first.
Here's what I want it to do: [describe behavior]
Don't change any existing files unless necessary for integration.
```

### Debugging a specific component

```
The [component] is failing with this error: [paste error]
Relevant file: [path]
Read CLAUDE.md first, then diagnose and fix.
Don't change unrelated files.
```

### Checking a piece of work before committing

```
Review [file or directory] for:
1. Compliance with CLAUDE.md conventions
2. Missing cost annotations on billable paths
3. Missing analytics events (check PROJECT.md event taxonomy)
4. Any hardcoded secrets or credentials
5. Any blocking calls in async functions
Give me a prioritized list of issues, skip nitpicks.
```

### Writing tests for existing code

```
Write tests for [module path].
Unit tests in tests/unit/, integration tests in tests/integration/.
Don't mock Vertex AI Search or BigQuery in integration tests — use the real services against a test datastore.
Use pytest. Follow existing test patterns in the tests/ directory.
```

### Adding a new podcast feed

```
Add a new podcast feed to the RSS watcher:
- Feed name: [name]
- RSS URL: [url]  
- Language: [en-US / id-ID]

Update ingestion/rss_watcher/feeds.yaml.
Check if any code needs to change for this language if it's new.
Also update PROJECT.md under the podcast profiles section.
```

---

## Troubleshooting quick reference

| Symptom | First place to check |
|---|---|
| Bot not responding | Cloud Run logs, check webhook URL with getWebhookInfo |
| Receipt extraction failing | OCR confidence in logs, check GCS permissions |
| Transcribe job stuck | AWS Transcribe console, check S3 permissions |
| RAG returning empty results | Vertex AI Search console, check datastore import status |
| Events not in BigQuery | Tag Gateway Cloud Run logs, check GTM container preview |
| WIF auth errors | Check token audience in WIF pool config, check service account binding |
| BQ permission denied | Check service account roles, confirm dataset region matches |
| Telegram MarkdownV2 error | Use escape_markdown() on all dynamic content |

---

## What's in scope for Milestone 1 (reference)

✅ AWS S3 + Transcribe batch pipeline
✅ RSS watcher for Motley Fool Money + Morningstar (CCC if RSS available)
✅ Vertex AI Search: media datastore + generic datastore
✅ BigQuery: receipts, podcasts, events tables
✅ Cloud Run: bot webhook
✅ Telegram bot: text questions, photo receipts, voice memos
✅ Commands: /start, /help, /podcasts, /status
✅ Tag Gateway: deployed, GA4 + BigQuery, 3 core events flowing
✅ Smoke test passing end-to-end

❌ /spend command (Milestone 2)
❌ Forwarded link handler (Milestone 2)
❌ Vercel dashboard (Milestone 3)
❌ Web Grounded Generation (Milestone 2)
❌ Streaming transcription (Milestone 4)
❌ Gemini ID transcript cleanup (Milestone 2)
❌ Receipt field editing beyond category (Milestone 2)
