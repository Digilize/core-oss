-- Migration: Builder (builder_projects, builder_conversations, builder_versions,
--            builder_messages, builder_deployments)
-- NOTE: No `sites` table exists in the baseline dump.

----------------------------------------------------------------------------
-- Tables
----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS "public"."builder_projects" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text" DEFAULT ''::"text",
    "slug" "text" NOT NULL,
    "platform" "text" DEFAULT 'react_native'::"text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "current_version_id" "uuid",
    "settings" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "builder_projects_platform_check" CHECK (("platform" = ANY (ARRAY['web'::"text", 'ios'::"text", 'react_native'::"text"]))),
    CONSTRAINT "builder_projects_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'deployed'::"text", 'archived'::"text"])))
);



CREATE TABLE IF NOT EXISTS "public"."builder_conversations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);



CREATE TABLE IF NOT EXISTS "public"."builder_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "version_number" integer DEFAULT 1 NOT NULL,
    "conversation_id" "uuid",
    "file_tree" "jsonb" DEFAULT '{}'::"jsonb",
    "prompt" "text" DEFAULT ''::"text",
    "status" "text" DEFAULT 'generating'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "builder_versions_status_check" CHECK (("status" = ANY (ARRAY['generating'::"text", 'ready'::"text", 'error'::"text"])))
);



CREATE TABLE IF NOT EXISTS "public"."builder_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "conversation_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "content" "text" DEFAULT ''::"text",
    "content_parts" "jsonb" DEFAULT '[]'::"jsonb",
    "version_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "builder_messages_role_check" CHECK (("role" = ANY (ARRAY['user'::"text", 'assistant'::"text"])))
);



CREATE TABLE IF NOT EXISTS "public"."builder_deployments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "version_id" "uuid" NOT NULL,
    "url" "text" NOT NULL,
    "status" "text" DEFAULT 'deploying'::"text" NOT NULL,
    "deployed_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "builder_deployments_status_check" CHECK (("status" = ANY (ARRAY['deploying'::"text", 'live'::"text", 'failed'::"text"])))
);



----------------------------------------------------------------------------
-- Primary Keys & Unique Constraints
----------------------------------------------------------------------------

ALTER TABLE ONLY "public"."builder_projects"
    ADD CONSTRAINT "builder_projects_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."builder_projects"
    ADD CONSTRAINT "builder_projects_slug_key" UNIQUE ("slug");

ALTER TABLE ONLY "public"."builder_conversations"
    ADD CONSTRAINT "builder_conversations_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."builder_versions"
    ADD CONSTRAINT "builder_versions_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."builder_messages"
    ADD CONSTRAINT "builder_messages_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."builder_deployments"
    ADD CONSTRAINT "builder_deployments_pkey" PRIMARY KEY ("id");


----------------------------------------------------------------------------
-- Foreign Keys
----------------------------------------------------------------------------

ALTER TABLE ONLY "public"."builder_projects"
    ADD CONSTRAINT "builder_projects_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."builder_projects"
    ADD CONSTRAINT "fk_builder_projects_current_version" FOREIGN KEY ("current_version_id") REFERENCES "public"."builder_versions"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."builder_conversations"
    ADD CONSTRAINT "builder_conversations_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."builder_projects"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."builder_versions"
    ADD CONSTRAINT "builder_versions_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."builder_projects"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."builder_versions"
    ADD CONSTRAINT "builder_versions_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."builder_conversations"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."builder_messages"
    ADD CONSTRAINT "builder_messages_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."builder_conversations"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."builder_messages"
    ADD CONSTRAINT "builder_messages_version_id_fkey" FOREIGN KEY ("version_id") REFERENCES "public"."builder_versions"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."builder_deployments"
    ADD CONSTRAINT "builder_deployments_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."builder_projects"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."builder_deployments"
    ADD CONSTRAINT "builder_deployments_version_id_fkey" FOREIGN KEY ("version_id") REFERENCES "public"."builder_versions"("id") ON DELETE CASCADE;


----------------------------------------------------------------------------
-- Indexes
----------------------------------------------------------------------------

CREATE INDEX "idx_builder_projects_user_id" ON "public"."builder_projects" USING "btree" ("user_id");
CREATE INDEX "idx_builder_projects_slug" ON "public"."builder_projects" USING "btree" ("slug");
CREATE INDEX "idx_builder_conversations_project_id" ON "public"."builder_conversations" USING "btree" ("project_id");
CREATE INDEX "idx_builder_versions_project_id" ON "public"."builder_versions" USING "btree" ("project_id");
CREATE UNIQUE INDEX "idx_builder_versions_project_version" ON "public"."builder_versions" USING "btree" ("project_id", "version_number");
CREATE INDEX "idx_builder_messages_conversation_id" ON "public"."builder_messages" USING "btree" ("conversation_id");
CREATE INDEX "idx_builder_messages_created_at" ON "public"."builder_messages" USING "btree" ("conversation_id", "created_at");
CREATE INDEX "idx_builder_deployments_project_id" ON "public"."builder_deployments" USING "btree" ("project_id");


----------------------------------------------------------------------------
-- Row Level Security
----------------------------------------------------------------------------

ALTER TABLE "public"."builder_projects" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."builder_conversations" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."builder_versions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."builder_messages" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."builder_deployments" ENABLE ROW LEVEL SECURITY;


----------------------------------------------------------------------------
-- Policies: builder_projects
----------------------------------------------------------------------------

CREATE POLICY "builder_projects_select" ON "public"."builder_projects" FOR SELECT USING (("auth"."uid"() = "user_id"));

CREATE POLICY "builder_projects_insert" ON "public"."builder_projects" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));

CREATE POLICY "builder_projects_update" ON "public"."builder_projects" FOR UPDATE USING (("auth"."uid"() = "user_id"));

CREATE POLICY "builder_projects_delete" ON "public"."builder_projects" FOR DELETE USING (("auth"."uid"() = "user_id"));


----------------------------------------------------------------------------
-- Policies: builder_conversations
----------------------------------------------------------------------------

CREATE POLICY "builder_conversations_select" ON "public"."builder_conversations" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."builder_projects"
  WHERE (("builder_projects"."id" = "builder_conversations"."project_id") AND ("builder_projects"."user_id" = "auth"."uid"())))));

CREATE POLICY "builder_conversations_insert" ON "public"."builder_conversations" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."builder_projects"
  WHERE (("builder_projects"."id" = "builder_conversations"."project_id") AND ("builder_projects"."user_id" = "auth"."uid"())))));

CREATE POLICY "builder_conversations_delete" ON "public"."builder_conversations" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."builder_projects"
  WHERE (("builder_projects"."id" = "builder_conversations"."project_id") AND ("builder_projects"."user_id" = "auth"."uid"())))));


----------------------------------------------------------------------------
-- Policies: builder_versions
----------------------------------------------------------------------------

CREATE POLICY "builder_versions_select" ON "public"."builder_versions" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."builder_projects"
  WHERE (("builder_projects"."id" = "builder_versions"."project_id") AND ("builder_projects"."user_id" = "auth"."uid"())))));

CREATE POLICY "builder_versions_insert" ON "public"."builder_versions" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."builder_projects"
  WHERE (("builder_projects"."id" = "builder_versions"."project_id") AND ("builder_projects"."user_id" = "auth"."uid"())))));

CREATE POLICY "builder_versions_delete" ON "public"."builder_versions" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."builder_projects"
  WHERE (("builder_projects"."id" = "builder_versions"."project_id") AND ("builder_projects"."user_id" = "auth"."uid"())))));


----------------------------------------------------------------------------
-- Policies: builder_messages
----------------------------------------------------------------------------

CREATE POLICY "builder_messages_select" ON "public"."builder_messages" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM ("public"."builder_conversations" "bc"
     JOIN "public"."builder_projects" "bp" ON (("bp"."id" = "bc"."project_id")))
  WHERE (("bc"."id" = "builder_messages"."conversation_id") AND ("bp"."user_id" = "auth"."uid"())))));

CREATE POLICY "builder_messages_insert" ON "public"."builder_messages" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM ("public"."builder_conversations" "bc"
     JOIN "public"."builder_projects" "bp" ON (("bp"."id" = "bc"."project_id")))
  WHERE (("bc"."id" = "builder_messages"."conversation_id") AND ("bp"."user_id" = "auth"."uid"())))));


----------------------------------------------------------------------------
-- Policies: builder_deployments
----------------------------------------------------------------------------

CREATE POLICY "builder_deployments_select" ON "public"."builder_deployments" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."builder_projects"
  WHERE (("builder_projects"."id" = "builder_deployments"."project_id") AND ("builder_projects"."user_id" = "auth"."uid"())))));

CREATE POLICY "builder_deployments_insert" ON "public"."builder_deployments" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."builder_projects"
  WHERE (("builder_projects"."id" = "builder_deployments"."project_id") AND ("builder_projects"."user_id" = "auth"."uid"())))));

CREATE POLICY "builder_deployments_update" ON "public"."builder_deployments" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."builder_projects"
  WHERE (("builder_projects"."id" = "builder_deployments"."project_id") AND ("builder_projects"."user_id" = "auth"."uid"())))));


----------------------------------------------------------------------------
-- Triggers
----------------------------------------------------------------------------

CREATE OR REPLACE TRIGGER "set_builder_projects_updated_at" BEFORE UPDATE ON "public"."builder_projects" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();


----------------------------------------------------------------------------
-- Grants: Tables
----------------------------------------------------------------------------





