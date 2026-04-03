-- Migration: Auth Schema Shim for Neon DB
--
-- Replaces Supabase's proprietary auth schema with a minimal compatibility
-- shim so all existing RLS policies (which call auth.uid()) continue to work
-- unchanged on Neon DB.
--
-- The key trick: auth.uid() is redefined to read from the per-connection
-- Postgres setting 'app.current_user_id', which the FastAPI middleware sets
-- on every authenticated request via:
--   SET LOCAL "app.current_user_id" = '<user_uuid>';
--
-- This means no RLS policies need to be touched — they all "just work".
--
-- Run this FIRST before all other migrations.

-- =============================================================================
-- Auth schema + minimal users table (satisfies FK constraints)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS auth;

-- Minimal auth.users table to satisfy FK references from app tables.
-- Will be retargeted to public.users once better-auth is live.
CREATE TABLE IF NOT EXISTS auth.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email text NOT NULL UNIQUE,
    created_at timestamptz DEFAULT now() NOT NULL
);

-- =============================================================================
-- auth.uid() — the critical shim
-- =============================================================================

-- All existing RLS policies call auth.uid() to get the current user's UUID.
-- This redefinition makes them read from a per-connection session variable
-- that the FastAPI asyncpg middleware sets on every request.
--
-- set_config('app.current_user_id', '<uuid>', true) is called with is_local=true
-- which scopes the setting to the current transaction and auto-clears when
-- the connection returns to the pool — safe for connection pooling.

CREATE OR REPLACE FUNCTION auth.uid()
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $$
    SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid
$$;

-- =============================================================================
-- Extensions needed by app migrations
-- =============================================================================

-- uuid_generate_v4() used in several migrations
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- pgvector for embeddings (enable via Neon console first if needed)
-- CREATE EXTENSION IF NOT EXISTS vector;
