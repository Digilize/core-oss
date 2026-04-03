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

-- Supabase compatibility roles referenced by policies.
-- Neon does not create these automatically.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        CREATE ROLE service_role NOLOGIN;
    END IF;
END
$$;

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

-- Minimal role shim used by a few Supabase-style policies.
-- Defaults to 'authenticated' when no explicit role is set.
CREATE OR REPLACE FUNCTION auth.role()
    RETURNS text
    LANGUAGE sql
    STABLE
    AS $$
    SELECT COALESCE(NULLIF(current_setting('app.current_user_role', true), ''), 'authenticated')
$$;

-- =============================================================================
-- Extensions needed by app migrations
-- =============================================================================

-- uuid_generate_v4() used in several migrations
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- pgvector for embeddings (enable via Neon console first if needed)
-- CREATE EXTENSION IF NOT EXISTS vector;
