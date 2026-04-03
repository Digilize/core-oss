-- Migration: Calendar System
-- Creates the calendar_events table, indexes, RLS policies, trigger, and grants.

-- =============================================================================
-- Table: calendar_events
-- =============================================================================

CREATE TABLE IF NOT EXISTS "public"."calendar_events" (
    "id" "uuid" DEFAULT "public"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "ext_connection_id" "uuid",
    "external_id" "text",
    "title" "text" NOT NULL,
    "description" "text",
    "location" "text",
    "start_time" timestamp with time zone NOT NULL,
    "end_time" timestamp with time zone NOT NULL,
    "is_all_day" boolean DEFAULT false,
    "status" "text" DEFAULT 'confirmed'::"text",
    "synced_at" timestamp with time zone,
    "raw_item" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "attendees" "jsonb" DEFAULT '[]'::"jsonb",
    "organizer_email" "text",
    "is_organizer" boolean DEFAULT false,
    "recurrence" "jsonb",
    "recurring_event_id" "text",
    "html_link" "text",
    "search_vector" "tsvector" GENERATED ALWAYS AS ((("setweight"("to_tsvector"('"english"'::"regconfig", COALESCE("title", ''::"text")), 'A'::"char") || "setweight"("to_tsvector"('"english"'::"regconfig", COALESCE("description", ''::"text")), 'B'::"char")) || "setweight"("to_tsvector"('"english"'::"regconfig", COALESCE("location", ''::"text")), 'C'::"char"))) STORED,
    "meeting_link" "text",
    "embedding" "public"."vector"(1536)
);


COMMENT ON COLUMN "public"."calendar_events"."meeting_link" IS 'Video conference link (Google Meet, Zoom, etc.) extracted from conferenceData or hangoutLink';

-- =============================================================================
-- Primary Key and Unique Constraints
-- =============================================================================

ALTER TABLE ONLY "public"."calendar_events"
    ADD CONSTRAINT "calendar_events_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."calendar_events"
    ADD CONSTRAINT "calendar_events_user_id_external_id_key" UNIQUE ("user_id", "external_id");

-- =============================================================================
-- Foreign Keys
-- =============================================================================

ALTER TABLE ONLY "public"."calendar_events"
    ADD CONSTRAINT "calendar_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."calendar_events"
    ADD CONSTRAINT "calendar_events_ext_connection_id_fkey" FOREIGN KEY ("ext_connection_id") REFERENCES "public"."ext_connections"("id") ON DELETE SET NULL;

-- =============================================================================
-- Indexes
-- =============================================================================

CREATE INDEX "idx_calendar_events_embedding" ON "public"."calendar_events" USING "hnsw" ("embedding" "public"."vector_cosine_ops") WITH ("m"='16', "ef_construction"='64');
CREATE INDEX "idx_calendar_events_end_time" ON "public"."calendar_events" USING "btree" ("end_time");
CREATE INDEX "idx_calendar_events_external_id" ON "public"."calendar_events" USING "btree" ("external_id");
CREATE INDEX "idx_calendar_events_recurring_event_id" ON "public"."calendar_events" USING "btree" ("recurring_event_id") WHERE ("recurring_event_id" IS NOT NULL);
CREATE INDEX "idx_calendar_events_start_time" ON "public"."calendar_events" USING "btree" ("start_time");
CREATE INDEX "idx_calendar_events_user_id" ON "public"."calendar_events" USING "btree" ("user_id");
CREATE INDEX "idx_calendar_search" ON "public"."calendar_events" USING "gin" ("search_vector");

-- =============================================================================
-- Row Level Security
-- =============================================================================

ALTER TABLE "public"."calendar_events" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own events" ON "public"."calendar_events" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));
CREATE POLICY "Users can insert own events" ON "public"."calendar_events" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));
CREATE POLICY "Users can update own events" ON "public"."calendar_events" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));
CREATE POLICY "Users can delete own events" ON "public"."calendar_events" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));

-- =============================================================================
-- Trigger
-- =============================================================================

CREATE OR REPLACE TRIGGER "update_calendar_events_updated_at" BEFORE UPDATE ON "public"."calendar_events" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();

-- =============================================================================
-- Grants
-- =============================================================================

