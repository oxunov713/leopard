# Deploying the Leopard API

> **Live setup (2026-11):** the API runs on **Render** (free web service, Docker)
> with **Neon** Postgres, and the web app on **Netlify**. Render is used because
> Google Cloud asked for a $50 prepayment to open billing. The Render steps are in
> section 0a; the Cloud Run sections below remain a working alternative.

## 0a. Render (current)

1. Neon: copy the connection string with **Connection pooling off** (no `-pooler`
   in the host), ending in `?sslmode=require`.
2. Generate the secrets and keep both offline (the server key is needed forever):
   `openssl rand -base64 32` (server key), `openssl rand -hex 24` (setup token).
3. Render → New → Web Service → connect GitHub (only the `leopard` repo).
   Language **Docker**, branch `main`, region Virginia, **Root Directory `backend`**,
   instance **Free**, health check path `/healthz`.
4. Environment: `DATABASE_URL`, `LEOPARD_SERVER_KEY`, `LEOPARD_SETUP_TOKEN`,
   `LEOPARD_TRUST_PROXY=2`, and after the web app exists
   `LEOPARD_WEB_ORIGIN=https://<site>.netlify.app`. Do not set `PORT`.
   - `LEOPARD_TRUST_PROXY=2`: Render's proxy does not strip a client-supplied
     `X-Forwarded-For`; Cloudflare appends the real client IP and Render appends
     Cloudflare's, so the client is the 2nd entry from the right. Check once in
     the Logs that the `ip` field is your real IP.
5. `https://<service>.onrender.com/healthz` → `{"status":"ok"}`.
6. Create the vault on the phone (server address + setup token), then delete
   `LEOPARD_SETUP_TOKEN` from the Render environment.

Free-tier trade-off: the service sleeps after ~15 minutes idle and the first
request takes 30-60 s. Deploys are automatic on every push to `main` that
Render picks up.

**Windows build note:** with the project on another drive than the pub cache,
Kotlin incremental compilation fails ("different roots"); `apps/mobile/android/
gradle.properties` sets `kotlin.incremental=false` for this. Run `flutter clean`
after a failed build.

---

## Alternative: Google Cloud Run

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

## 8. Web (Netlify)

The web app (`apps/web`, Flutter Web) is a static site on **Netlify**'s free
tier. It is built outside Netlify (its build image has no Flutter) and the
prebuilt `build/web` directory is uploaded. `apps/web/netlify.toml` holds the
publish directory, security headers and caching rules. It is only read when
you deploy **from `apps/web`**, so every command below runs there.

### 8.1 Build

From the repository root, with the Cloud Run URL from step 5:

```sh
cd apps/web
flutter build web --release --no-web-resources-cdn --csp \
  --dart-define=LEOPARD_API_URL=https://<cloud-run-host>
```

`--no-web-resources-cdn` bundles CanvasKit into `build/web/canvaskit/`, so the
page never loads code from a third-party CDN (the CSP forbids it). `--csp`
builds without `eval`/`new Function`, which is what CI checks against
`script-src 'self'`; a build without it is not the build CI verified.

### 8.2 Create the site and deploy

Do not let Netlify build the repository. Create an empty site and push the
prebuilt directory:

```sh
npm install -g netlify-cli
netlify login
netlify sites:create --name YOUR-SITE-NAME     # note the site ID
cd apps/web
netlify deploy --prod --dir=build/web --site=NETLIFY_SITE_ID
```

`netlify.toml` is read from the directory you run the command in. Running it
from the repository root publishes the site **without** CSP, HSTS and the other
headers, so always deploy from `apps/web`.

For non-interactive use (CI, or deploying a downloaded GitHub Actions
artifact), set a personal access token and the site ID instead of logging in:

```sh
export NETLIFY_AUTH_TOKEN=...     # User settings > Applications > Personal access tokens
export NETLIFY_SITE_ID=...        # Site configuration > Site ID
cd apps/web
netlify deploy --prod --dir=build/web
```

For the Actions artifact: download it, unzip it into `apps/web/build/web`, and
run the same command. Store the token and site ID as repository secrets
(`NETLIFY_AUTH_TOKEN`, `NETLIFY_SITE_ID`); never commit them. Linking the
private repository in the Netlify UI is possible but not recommended: Netlify
would try to build it and fail without Flutter.

### 8.3 Allow the web origin on the API

Set `LEOPARD_WEB_ORIGIN` on Cloud Run to the **exact** site origin:
`https://YOUR-SITE-NAME.netlify.app` or your custom domain, with no path and no
trailing slash. Comma-separate several.

```sh
gcloud run services update leopard-api --region="$REGION" \
  --update-env-vars=LEOPARD_WEB_ORIGIN=https://YOUR-SITE-NAME.netlify.app
```

### 8.4 Fill in the CSP placeholder

In `apps/web/netlify.toml`, replace `https://LEOPARD_API_HOST` in `connect-src`
with the Cloud Run origin (for example `https://leopard-api-xxxx-uc.a.run.app`),
then redeploy. The policy is a starting point: if the browser console reports a
blocked resource, widen only that directive and only as far as needed.

### 8.5 Verify

```sh
curl -sI https://YOUR-SITE-NAME.netlify.app/ | grep -i -E \
  'content-security-policy|strict-transport|x-content-type|referrer-policy|x-frame|cross-origin|permissions-policy|cache-control'
curl -sI https://YOUR-SITE-NAME.netlify.app/main.dart.js | grep -i cache-control   # no-cache
# CORS: an allowed origin gets 204, any other origin is refused with 403.
curl -si -X OPTIONS "$URL/v1/setup" -H 'Origin: https://YOUR-SITE-NAME.netlify.app' \
  -H 'Access-Control-Request-Method: POST' | head -5
curl -si "$URL/healthz" -H 'Origin: https://evil.example' | head -1
```

Checklist:

- [ ] `Strict-Transport-Security` present (Netlify serves HTTPS only).
- [ ] CSP header present and the placeholder `LEOPARD_API_HOST` is gone.
- [ ] Browser console shows no CSP violations while loading, logging in and copying a password.
- [ ] A request from any other `Origin` is rejected by the API (`403 origin_not_allowed`).
- [ ] `index.html`, `main.dart.js` and `canvaskit/*` return `Cache-Control: no-cache`
      (Flutter does not hash file names, so nothing is cached without revalidation).
- [ ] The app uses hash routes (`/#/...`); there is no SPA fallback, so an unknown
      path such as `/nope` returns 404.

## 9. Cost notes

Cloud Run's free tier covers 2 million requests and 180,000 vCPU-seconds per
month in `us-central1`; a personal password manager uses a tiny fraction.
Artifact Registry stores the container image (0.5 GB free). Neon's free plan
covers one small database that suspends when idle. Check the current free-tier
terms of both providers before relying on these numbers.
