# Supabase Migration Research (Core OSS)

## Goal

You asked for a full research pass on this repository and a practical plan to migrate away from Supabase, especially:

- Database move from Supabase Postgres to Neon Postgres (with Drizzle ORM; "Tristle" interpreted as Drizzle)
- Replacement options for other Supabase capabilities (Auth, Realtime, Storage, APIs, Functions)
- Future-friendly path to self-hosting with Docker
- Concrete tasks, effort estimate, and alternative paths

---

## 1) How this repository works today

Based on repository inspection, this is a monorepo with 3 apps:

- `core-api`: FastAPI backend (Python)
- `core-web`: React + Vite frontend (TypeScript)
- `core-image-proxy`: Cloudflare Worker for image proxying

### Current Supabase usage (important)

Supabase is not only the DB here. It is used as:

1. **Postgres data plane** with SQL migrations and RLS
2. **Authentication provider** (Supabase Auth JWTs)
3. **Realtime provider** (Postgres changes + presence + broadcast)
4. **PostgREST-style data access SDK** via Supabase Python + JS clients
5. **Storage schema usage** (`storage.*`) in SQL migrations

Evidence paths:

- Frontend auth + client:
  - `core-web/src/lib/supabase.ts`
  - `core-web/src/stores/authStore.ts`
  - `core-web/src/api/client.ts`
- Frontend realtime:
  - `core-web/src/hooks/useGlobalRealtime.ts`
  - `core-web/src/hooks/useWorkspacePresence.ts`
  - `core-web/src/hooks/useAgentRealtime.ts`
- Backend auth + DB clients:
  - `core-api/lib/supabase_client.py`
  - `core-api/api/dependencies.py`
  - `core-api/api/services/auth.py`
- DB schema / policies / realtime setup:
  - `core-api/supabase/migrations/*.sql`
  - Includes: realtime publication setup, signup trigger, storage config

### Architectural implication

This app is **deeply coupled** to Supabase primitives, especially JWT model + realtime channels + user-scoped DB access with RLS.  
So migration should be phased, not big-bang.

---

## 2) What Supabase provides and what to replace it with

Supabase capability map (official):  
- [Supabase Features](https://supabase.com/features)  
- [Supabase Docs](https://supabase.com/docs)  
- [Supabase Self-Hosting Docker](https://supabase.com/docs/guides/self-hosting/docker)

### Capability-by-capability replacement matrix

1) **Database (Postgres)**
- Current: Supabase Postgres
- Recommended replacement now: **Neon Postgres**
- Future self-host: **PostgreSQL + PgBouncer + backups**
- Docs:
  - [Neon connect](https://neon.tech/docs/get-started/connect-neon)
  - [Neon pooling](https://neon.tech/docs/connect/connection-pooling)
  - [Neon branching workflow](https://neon.tech/docs/get-started/workflow-primer)
  - [PgBouncer](https://www.pgbouncer.org/config.html)

2) **ORM + migrations**
- Recommended: **Drizzle ORM + drizzle-kit**
- Why: typed schema, SQL-first migrations, good TS developer ergonomics
- Docs:
  - [Drizzle migrations](https://orm.drizzle.team/docs/migrations)
  - [drizzle-kit generate](https://orm.drizzle.team/docs/drizzle-kit-generate)

3) **Authentication**
- Today: Supabase Auth JWTs
- Viable replacements:
  - **Auth.js + Drizzle adapter** (app-centric, easiest for React ecosystem)
  - **Better Auth + Drizzle** (similar modern app-owned auth approach)
  - **ZITADEL** (strong managed-to-self-host path)
  - **Keycloak** (enterprise grade, heavier ops)
- Docs:
  - [Auth.js Drizzle adapter](https://authjs.dev/getting-started/adapters/drizzle)
  - [ZITADEL self-hosting](https://zitadel.com/docs/self-hosting/deploy/overview)
  - [Keycloak containers](https://www.keycloak.org/server/containers)

4) **Realtime**
- Today: Supabase Realtime (`postgres_changes`, `presence`, `broadcast`)
- Options:
  - Keep similar model: self-host Supabase Realtime service
  - GraphQL subscriptions path: Hasura
  - Sync model: ElectricSQL
  - Event bus model: NATS
- Docs:
  - [Supabase Realtime protocol](https://supabase.com/docs/guides/realtime/protocol)
  - [Hasura subscriptions](https://hasura.io/docs/latest/subscriptions/postgres/index/)
  - [ElectricSQL docs](https://electric-sql.com/docs)
  - [NATS websockets](https://docs.nats.io/running-a-nats-service/configuration/websocket)

5) **Storage**
- Today: mixed model (Cloudflare R2 app usage + Supabase `storage.*` schema references in SQL)
- Options:
  - Managed: stay on **Cloudflare R2** or S3
  - Self-host: **MinIO**
- Docs:
  - [Cloudflare R2](https://developers.cloudflare.com/r2/)
  - [MinIO Docker quickstart](https://docs.min.io/docs/minio-docker-quickstart-guide)

6) **Auto APIs / RPC access**
- Today: many flows use Supabase client pattern (PostgREST/RPC style)
- Options:
  - Keep backend-only API access (FastAPI as source of truth)
  - Add PostgREST explicitly if needed
- Docs:
  - [PostgREST](https://docs.postgrest.org/en/stable/)

7) **RLS**
- Important: RLS is PostgreSQL-native, not Supabase-only
- You can keep your policy model on Neon or self-hosted Postgres
- Docs:
  - [PostgreSQL RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
  - [CREATE POLICY](https://www.postgresql.org/docs/15/sql-createpolicy.html)

---

## 3) Recommended migration strategy for this repo

## Phase 0: Discovery and safety baseline (3-5 days)

- Inventory all Supabase touchpoints (frontend, backend, SQL, CI envs)
- Freeze a migration branch and add integration tests for:
  - auth session flow
  - core CRUD routes
  - realtime critical paths (messages, notifications, presence)
- Define data cutover and rollback checkpoints

## Phase 1: Database substrate move first (1-2 weeks)

- Provision Neon project and environments
- Port SQL migrations from `core-api/supabase/migrations` to neutral migration pipeline
- Run schema + extension validation on Neon
- Verify RLS parity behavior with smoke tests

Notes:
- This phase should avoid changing auth/realtime at first.
- Goal: move storage of data first while minimizing surface area.

## Phase 2: Backend decoupling from Supabase client patterns (1-2 weeks)

- Replace `core-api/lib/supabase_client.py` dependency chain with neutral DB access pattern:
  - either SQLAlchemy/psycopg service layer
  - or controlled PostgREST adapter (temporary bridge)
- Remove reliance on `postgrest.auth(user_jwt)` as authorization engine
- Introduce explicit auth context propagation (`user_id`, `workspace_id`, roles)

## Phase 3: Auth migration (1-2.5 weeks)

- Choose target auth:
  - simpler app-owned path: Auth.js/Better Auth
  - stronger IAM path: ZITADEL/Keycloak
- Implement JWT claim mapping to preserve current authorization semantics
- Replace frontend `supabase.auth.*` flows with new auth SDK
- Update backend token verification middleware/dependencies

Critical success criterion:
- JWT claims must map cleanly to existing RLS/permission model.

## Phase 4: Realtime migration (1.5-3 weeks)

- Replace frontend channels currently in:
  - `useGlobalRealtime.ts` (`postgres_changes`)
  - `useWorkspacePresence.ts` (`presence` + `broadcast`)
- Implement equivalent semantics using chosen stack (Hasura/Electric/NATS/etc.)
- Build event contract tests for:
  - message insert/update/delete
  - reaction updates
  - notifications
  - workspace presence + typing

## Phase 5: Storage + residual Supabase features (3-7 days)

- Remove/replace Supabase storage schema coupling in migrations
- Keep/standardize R2 or migrate to MinIO/S3
- Validate presigned URL and ACL behavior

## Phase 6: Hardening + cutover (4-7 days)

- Load test key APIs and websocket paths
- Run dual-read/dual-write window if needed
- Execute cutover with rollback window
- Clean up unused Supabase envs and code paths

---

## 4) Time estimate (realistic)

Given this repo's current coupling level:

- **MVP migration (managed target first): 6-10 weeks**
- **Production-grade migration with robust parity: 8-14 weeks**
- **Additional self-hosting production hardening: +2-6 weeks**

### Effort drivers

- Heavy realtime logic in frontend hooks
- Backend patterns tied to Supabase client auth modes
- Auth claim compatibility with current RLS
- Migration/testing breadth across many app modules

---

## 5) Other viable paths (choose based on risk tolerance)

### Option A (lowest risk): Keep Supabase, self-host Supabase later

- Pros: highest compatibility, fastest path to self-host
- Cons: still Supabase stack; less vendor simplification
- If goal is mainly cost/control, this is very practical

### Option B (balanced): Neon + Drizzle + Auth.js + R2 + NATS

- Pros: modular stack, easier incremental migration, good dev velocity
- Cons: you own cross-service integration and auth/realtime correctness

### Option C (IAM-heavy): Neon + ZITADEL/Keycloak + MinIO + Hasura/Electric

- Pros: strong enterprise/security model, full self-host posture
- Cons: highest ops complexity

---

## 6) Self-hosted Docker target architecture (future)

If your future target is "just Docker containers", a practical base stack is:

- `postgres` (primary DB)
- `pgbouncer` (connection pooling)
- `minio` (object storage)
- `auth-service` (Auth.js app, or ZITADEL/Keycloak container)
- `realtime-service` (NATS or chosen realtime layer)
- `core-api` (FastAPI)
- `core-web` (served via Node/Nginx)
- Optional:
  - `redis/valkey` (rate limits + caching)
  - `mailpit` (local email testing)
  - `sentry-compatible` local error tracking

### Minimal docker-compose shape

At minimum for local parity:

1. `postgres`
2. `core-api`
3. `core-web`
4. `auth` service
5. `realtime` service (if you keep realtime features)
6. `object storage` (if file features required)

---

## 7) What you would need to do first (recommended next 7 days)

1. Decide target auth provider (this is the highest architectural decision)
2. Finalize realtime replacement strategy (event model and client SDK)
3. Create migration branch and compatibility test suite
4. Stand up Neon and run schema parity tests
5. Implement one vertical slice migration:
   - login -> fetch workspace -> send message -> receive realtime update

If that slice works end-to-end, full migration risk drops dramatically.

---

## 8) Practical recommendation for your exact ask

If your immediate goal is "move off Supabase but keep Postgres and future self-hosting":

- Start with **Neon + Drizzle** for data layer
- Use **Auth.js + Drizzle** (or ZITADEL if you want stronger IAM now)
- Keep **Cloudflare R2** initially (already integrated)
- Replace realtime with **NATS** or **Hasura/Electric** after auth stabilization
- Keep the move incremental, not all at once

This gives you vendor flexibility now and a clean path to "all Docker later."

---

## 9) Caveats and assumptions

- "Tristle" interpreted as **Drizzle ORM**.
- Timeline assumes a small engineering team and existing test discipline.
- If you need exact story-point level estimates, we should run a file-by-file migration backlog next.

