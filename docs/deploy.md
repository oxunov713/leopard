# Deploying the Leopard API

Target: **Google Cloud Run** (region `us-central1`, scale to zero) with
**Neon** serverless Postgres. Both have free tiers that cover a single-user
service; the budget alert below is the safety net.

Replace the `UPPER_CASE` values. Commands assume a POSIX shell.

## 0. Prerequisites

- A Google Cloud account with billing enabled (required even for free-tier use).
- `gcloud` installed and logged in: `gcloud auth login`.
- A Neon account: <https://neon.tech>.

## 1. Database (Neon)

1. Create a project (pick a US region close to `us-central1`, e.g. AWS `us-east-2`).
2. Copy the connection string and make sure it ends with `sslmode=require`:

   ```
   postgres://USER:PASSWORD@ep-xxxx.us-east-2.aws.neon.tech/neondb?sslmode=require
   ```

   Use the **direct** host (the one without `-pooler` in its name). The API
   keeps its own small pool (at most 5 connections), uses prepared statements,
   and takes a session-level advisory lock while migrating; all of these
   assume a real session, which a transaction-mode pooler does not provide.

The API creates its schema itself on first start (embedded migrations).

## 2. Project and APIs

```sh
export PROJECT_ID=leopard-YOURSUFFIX
export REGION=us-central1

gcloud projects create "$PROJECT_ID"
gcloud config set project "$PROJECT_ID"
gcloud billing projects link "$PROJECT_ID" --billing-account=BILLING_ACCOUNT_ID   # gcloud billing accounts list
gcloud services enable run.googleapis.com cloudbuild.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com billingbudgets.googleapis.com
```

## 3. Budget alert at $1

Do this **before** deploying.

```sh
gcloud billing budgets create \
  --billing-account=BILLING_ACCOUNT_ID \
  --display-name="leopard-1usd" \
  --budget-amount=1USD \
  --filter-projects="projects/$PROJECT_ID" \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0
```

A budget **notifies** (email to billing admins); it does not stop spending.
The hard limits are the `--max-instances=1` and scale-to-zero settings below.

## 4. Secrets

```sh
# Database URL
printf '%s' 'postgres://USER:PASSWORD@HOST/neondb?sslmode=require' \
  | gcloud secrets create leopard-database-url --data-file=-

# Server key (encrypts the TOTP secret at rest). Back this value up offline:
# without it, master-password login stops working.
openssl rand -base64 32 | tr -d '\n' | gcloud secrets create leopard-server-key --data-file=-

# One-time setup token: only someone who knows it can initialise the vault.
openssl rand -hex 24 | tr -d '\n' | tee /dev/stderr | gcloud secrets create leopard-setup-token --data-file=-
```

Give the Cloud Run runtime service account access:

```sh
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
for s in leopard-database-url leopard-server-key leopard-setup-token; do
  gcloud secrets add-iam-policy-binding "$s" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role=roles/secretmanager.secretAccessor
done
```

## 5. Deploy

From the repository root (Cloud Build builds `backend/Dockerfile`):

```sh
gcloud run deploy leopard-api \
  --source=backend \
  --region="$REGION" \
  --allow-unauthenticated \
  --min-instances=0 \
  --max-instances=1 \
  --concurrency=40 \
  --cpu=1 --memory=256Mi \
  --timeout=30 \
  --set-env-vars=LEOPARD_TRUST_PROXY=1,LEOPARD_WEB_ORIGIN=https://YOUR-WEB-APP-ORIGIN \
  --set-secrets=DATABASE_URL=leopard-database-url:latest,LEOPARD_SERVER_KEY=leopard-server-key:latest,LEOPARD_SETUP_TOKEN=leopard-setup-token:latest
```

Why these flags:

| Flag | Reason |
|---|---|
| `--allow-unauthenticated` | The API does its own authentication; the phone and browser cannot present Google IAM tokens. |
| `--min-instances=0` | Scale to zero: no cost while idle. The first request after idle takes about a second longer (cold start plus Neon wake-up). |
| `--max-instances=1` | Caps cost, and is **required for correctness of rate limiting**: the limiter is in process memory, so limits are per instance. |
| `LEOPARD_TRUST_PROXY=1` | Cloud Run appends the real client IP as the last `X-Forwarded-For` entry. Without this every client appears to share one IP. Do **not** set it when clients can reach the service directly. If you later put a load balancer in front, set it to `2`. |
| `LEOPARD_WEB_ORIGIN` | Exact origin of the web app (`https://host`, no path, no trailing slash). Comma-separate several. Until the web app exists you may omit it; the phone does not need CORS. |

Check it:

```sh
URL=$(gcloud run services describe leopard-api --region="$REGION" --format='value(status.url)')
curl -s "$URL/healthz"        # {"status":"ok"}
```

`PORT` is set by Cloud Run; do not set it yourself.

## 6. First-time setup

The phone app performs `POST /v1/setup` and must send the setup token in the
`X-Leopard-Setup-Token` header. After setup succeeds the endpoint refuses
forever (`409 already_initialised`), so the token can be removed:

```sh
gcloud run services update leopard-api --region="$REGION" --remove-secrets=LEOPARD_SETUP_TOKEN
```

## 7. Operations

- **Logs:** `gcloud run services logs read leopard-api --region="$REGION" --limit=50`.
  Logs are JSON, one line per request, with the route pattern, status, duration
  and client IP. They never contain tokens, proofs or bodies.
- **Update:** re-run the `gcloud run deploy` command. Migrations apply on start.
- **Rotating `LEOPARD_SERVER_KEY`** is not supported in v1: the TOTP secret is
  encrypted under it. Keep the backup.
- **Database backups:** Neon keeps point-in-time history (length depends on
  plan). The data is ciphertext, so a `pg_dump` can be stored anywhere:

  ```sh
  pg_dump "$DATABASE_URL" --no-owner > leopard-$(date +%F).sql
  ```

- **Start over (destroys the vault):** drop all tables in the Neon SQL editor
  (`DROP SCHEMA public CASCADE; CREATE SCHEMA public;`) and redeploy.

## 8. Cost notes

Cloud Run's free tier covers 2 million requests and 180,000 vCPU-seconds per
month in `us-central1`; a personal password manager uses a tiny fraction.
Artifact Registry stores the container image (0.5 GB free). Neon's free plan
covers one small database that suspends when idle. Check the current free-tier
terms of both providers before relying on these numbers.
