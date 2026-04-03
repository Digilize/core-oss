# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Core** is an open-source all-in-one productivity platform (Email, Calendar, Chat, Messages, Files, Projects) built as a monorepo with three packages:
- `core-api` — Python 3.12 / FastAPI backend
- `core-web` — React 19 / Vite 7 / TypeScript frontend
- `core-image-proxy` — Cloudflare Worker for image resizing/CDN

## Commands

### Backend (core-api)

```bash
cd core-api
make start          # Start dev server with auto-reload
make test           # Run pytest suite
make check          # Run lint + typecheck together
make lint           # Ruff linter
make format         # Ruff formatter
make typecheck      # Mypy type checker
make test-openapi   # Validate OpenAPI schema

# Run individual tests
uv run pytest tests/test_api.py -v
uv run pytest tests/chat/ -v
uv run pytest -k "email" -v
uv run pytest tests/test_api.py::TestClass::test_method -v
```

Package manager is `uv` (Astral). `asyncio_mode = auto` in pytest.ini — all tests are async-friendly.

### Frontend (core-web)

```bash
cd core-web
npm run dev         # Vite dev server with HMR
npm run build       # TypeScript check + Vite production build
npm run lint        # ESLint
npx tsc -b          # TypeScript type check only
```

### Image Proxy (core-image-proxy)

```bash
cd core-image-proxy
npm run dev         # Local Cloudflare Worker dev
npm run deploy      # Deploy to Cloudflare
```

## Architecture

### Backend Layer Separation

```
HTTP Request
    ↓
api/routers/       — HTTP handling, request validation, response codes
    ↓
api/services/      — Business logic, domain operations
    ↓
lib/               — Shared clients (Supabase, R2, Resend, QStash, etc.)
    ↓
External Services  — Supabase, Cloudflare R2, Google/Microsoft OAuth, AI providers
```

- Dependency injection via FastAPI `Depends()` — auth/user context flows through `api/dependencies.py`
- `api/config.py` uses Pydantic `BaseSettings` (all config is environment-driven)
- Rate limiting via `slowapi`; falls back to in-memory if Redis is unavailable
- Chat responses stream as NDJSON events

### AI Chat System

The chat system in `api/services/chat/` and `lib/tools/` supports multiple AI providers (OpenAI, Anthropic, Groq) with a unified tool-calling interface:
- `lib/tools/registry.py` — tool definitions
- `lib/tools/adapters/` — normalizes tool schemas for OpenAI, Claude, and MCP formats
- `lib/tools/definitions/` — individual tool implementations (email search, web search, document search, calendar, etc.)
- Messages use a typed **Content Parts Schema** (see `docs/CONTENT_PARTS_SCHEMA.md`) — structured `content_parts` JSON column alongside raw `content`

### Frontend Layer Separation

```
React Components (src/components/)  — 34 feature modules
    ↓
Custom Hooks (src/hooks/)
    ↓
Zustand Stores (src/stores/)       — 19 stores for global state
    ↓
API Client (src/api/)
    ↓
Backend (core-api)
```

- Supabase Realtime powers live messaging in `src/lib/`
- Sentry (`src/lib/`) and PostHog for error tracking and analytics

### Database (Supabase/PostgreSQL)

Migrations are in `core-api/supabase/migrations/`, organized by domain. Key design features:
- **Row-Level Security (RLS)** enforces multi-tenant workspace isolation at the database layer
- **Realtime subscriptions** for team messaging channels
- **GIN indexes** on JSON columns for search performance
- Custom RPC functions for efficient operations: `calculate_habit_streak()`, `reorder_todos()`, `batch_get_habit_streaks()`

## Required vs Optional Services

Only **Supabase** is required. Everything else degrades gracefully:

| Service | What it enables |
|---------|----------------|
| Supabase | Auth, database, realtime (required) |
| OpenAI / Anthropic / Groq | AI chat (at least one needed for `/api/chat`) |
| Google OAuth | Gmail + Google Calendar sync |
| Microsoft OAuth | Outlook + M365 Calendar sync |
| Cloudflare R2 | File uploads |
| Resend | Workspace invitation emails |
| Redis (Upstash) | Distributed rate limiting |
| QStash | Background job queue |
| Exa | Web search in AI chat |

## Environment Setup

Copy `.env.example` to `.env` in both `core-api/` and `core-web/` before running locally. The minimum for the backend is `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, and `SUPABASE_JWT_SECRET`.

## CI Pipeline

`.github/workflows/ci.yml` runs: API lint → API typecheck → API tests → OpenAPI schema validation → Web build + typecheck. Secret scanning via gitleaks runs separately. Pre-commit hooks also run gitleaks on every commit (`pip install pre-commit && pre-commit install`).
