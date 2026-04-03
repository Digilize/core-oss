-- Migration: Extensions and Types
-- Enables required extensions, creates custom enum types, and defines
-- the generic update_updated_at_column() trigger function used by many tables.

-- =============================================================================
-- Extensions
-- =============================================================================

-- pgvector: prod has this in the public schema.
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;

-- =============================================================================
-- Custom Enum Types
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'mini_app_type' AND n.nspname = 'public'
    ) THEN
        CREATE TYPE "public"."mini_app_type" AS ENUM (
            'files',
            'messages',
            'dashboard',
            'projects',
            'chat',
            'email',
            'calendar',
            'agents'
        );
    END IF;
END
$$;




DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'workspace_invitation_status' AND n.nspname = 'public'
    ) THEN
        CREATE TYPE "public"."workspace_invitation_status" AS ENUM (
            'pending',
            'accepted',
            'declined',
            'revoked',
            'expired'
        );
    END IF;
END
$$;




DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'workspace_role' AND n.nspname = 'public'
    ) THEN
        CREATE TYPE "public"."workspace_role" AS ENUM (
            'owner',
            'admin',
            'member'
        );
    END IF;
END
$$;



-- =============================================================================
-- Generic Trigger Function
-- =============================================================================

CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;



-- =============================================================================
-- GRANTs
-- =============================================================================

