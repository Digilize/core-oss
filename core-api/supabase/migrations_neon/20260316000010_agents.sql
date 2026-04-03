-- ============================================================================
-- Migration: Agents
-- Description: agent_templates, agent_instances, agent_tasks, agent_task_steps,
--              agent_conversations tables with functions, indexes, RLS policies,
--              triggers, and grants
-- ============================================================================

-- Disable function body validation so LANGUAGE sql functions referencing
-- tables defined later in this file don't fail during CREATE FUNCTION.
SET check_function_bodies = false;

-- ==========================================================
-- FUNCTIONS
-- ==========================================================

-- can_access_agent_storage: Check if user can access agent storage via workspace membership
CREATE OR REPLACE FUNCTION "public"."can_access_agent_storage"("object_name" "text") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM agent_instances ai
    JOIN workspace_members wm ON ai.workspace_id = wm.workspace_id
    WHERE ai.id::text = split_part(object_name, '/', 1)
    AND wm.user_id = auth.uid()
  );
$$;


-- update_agent_templates_updated_at
CREATE OR REPLACE FUNCTION "public"."update_agent_templates_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


-- update_agent_instances_updated_at
CREATE OR REPLACE FUNCTION "public"."update_agent_instances_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


-- update_agent_conversations_updated_at
CREATE OR REPLACE FUNCTION "public"."update_agent_conversations_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


-- update_conversation_on_task_change
CREATE OR REPLACE FUNCTION "public"."update_conversation_on_task_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.conversation_id IS NOT NULL THEN
        UPDATE public.agent_conversations
        SET updated_at = NOW()
        WHERE id = NEW.conversation_id;
    END IF;
    RETURN NEW;
END;
$$;


-- ==========================================================
-- TABLES
-- ==========================================================

-- agent_templates
CREATE TABLE IF NOT EXISTS "public"."agent_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "category" "text" DEFAULT 'general'::"text" NOT NULL,
    "icon_url" "text",
    "default_system_prompt" "text" NOT NULL,
    "default_enabled_tools" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "default_config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "e2b_template_id" "text",
    "is_public" boolean DEFAULT true NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


COMMENT ON TABLE "public"."agent_templates" IS 'Pre-built agent archetypes available in the Template Store';

-- agent_instances
CREATE TABLE IF NOT EXISTS "public"."agent_instances" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "avatar_url" "text",
    "status" "text" DEFAULT 'idle'::"text" NOT NULL,
    "system_prompt" "text" NOT NULL,
    "enabled_tools" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "sandbox_id" "text",
    "sandbox_status" "text" DEFAULT 'off'::"text" NOT NULL,
    "sandbox_created_at" timestamp with time zone,
    "template_id" "uuid",
    "e2b_sandbox_id" "text",
    "e2b_status" "text" DEFAULT 'off'::"text" NOT NULL,
    "last_active_at" timestamp with time zone,
    CONSTRAINT "agent_instances_e2b_status_check" CHECK (("e2b_status" = ANY (ARRAY['off'::"text", 'starting'::"text", 'running'::"text", 'idle'::"text", 'paused'::"text", 'error'::"text"]))),
    CONSTRAINT "agent_instances_sandbox_status_check" CHECK (("sandbox_status" = ANY (ARRAY['off'::"text", 'starting'::"text", 'running'::"text", 'error'::"text"]))),
    CONSTRAINT "agent_instances_status_check" CHECK (("status" = ANY (ARRAY['idle'::"text", 'working'::"text", 'error'::"text"])))
);


COMMENT ON TABLE "public"."agent_instances" IS 'AI agent instances deployed within workspaces';

COMMENT ON COLUMN "public"."agent_instances"."sandbox_id" IS 'Current E2B sandbox ID (null if no sandbox running)';

COMMENT ON COLUMN "public"."agent_instances"."sandbox_status" IS 'Current sandbox lifecycle state';

COMMENT ON COLUMN "public"."agent_instances"."template_id" IS 'Template this agent was created from (if any)';

COMMENT ON COLUMN "public"."agent_instances"."e2b_sandbox_id" IS 'E2B sandbox ID when running';

COMMENT ON COLUMN "public"."agent_instances"."e2b_status" IS 'Sandbox lifecycle: off, starting, running, idle, paused, error';

-- agent_tasks
CREATE TABLE IF NOT EXISTS "public"."agent_tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "trigger" "text" DEFAULT 'user_message'::"text" NOT NULL,
    "trigger_ref" "text",
    "status" "text" DEFAULT 'queued'::"text" NOT NULL,
    "input" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "output" "jsonb",
    "steps" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "token_usage" integer DEFAULT 0,
    "error" "text",
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sandbox_id" "text",
    "model" "text",
    "conversation_id" "uuid",
    CONSTRAINT "agent_tasks_status_check" CHECK (("status" = ANY (ARRAY['queued'::"text", 'running'::"text", 'completed'::"text", 'failed'::"text"])))
);


COMMENT ON TABLE "public"."agent_tasks" IS 'Task queue and execution log for AI agents';

COMMENT ON COLUMN "public"."agent_tasks"."conversation_id" IS 'Links task to a conversation for multi-turn history';

-- agent_task_steps
CREATE TABLE IF NOT EXISTS "public"."agent_task_steps" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "turn" integer NOT NULL,
    "step_type" "text" NOT NULL,
    "tool_name" "text",
    "tool_args" "jsonb",
    "tool_result" "jsonb",
    "content" "text",
    "token_usage" integer DEFAULT 0,
    "duration_ms" integer,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "agent_task_steps_step_type_check" CHECK (("step_type" = ANY (ARRAY['thinking'::"text", 'tool_call'::"text", 'tool_result'::"text", 'message'::"text", 'error'::"text"])))
);


COMMENT ON TABLE "public"."agent_task_steps" IS 'Real-time execution steps for agent task observability';

-- agent_conversations
CREATE TABLE IF NOT EXISTS "public"."agent_conversations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "title" "text" DEFAULT 'New Conversation'::"text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


COMMENT ON TABLE "public"."agent_conversations" IS 'Persistent conversation threads for AI agents';

-- ==========================================================
-- PRIMARY KEYS & UNIQUE CONSTRAINTS
-- ==========================================================

ALTER TABLE ONLY "public"."agent_templates"
    ADD CONSTRAINT "agent_templates_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."agent_templates"
    ADD CONSTRAINT "agent_templates_slug_key" UNIQUE ("slug");

ALTER TABLE ONLY "public"."agent_instances"
    ADD CONSTRAINT "agent_instances_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."agent_tasks"
    ADD CONSTRAINT "agent_tasks_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."agent_task_steps"
    ADD CONSTRAINT "agent_task_steps_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."agent_conversations"
    ADD CONSTRAINT "agent_conversations_pkey" PRIMARY KEY ("id");

-- ==========================================================
-- FOREIGN KEYS
-- ==========================================================

-- agent_instances FKs
ALTER TABLE ONLY "public"."agent_instances"
    ADD CONSTRAINT "agent_instances_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."agent_templates"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."agent_instances"
    ADD CONSTRAINT "agent_instances_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."agent_instances"
    ADD CONSTRAINT "agent_instances_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");

-- agent_conversations FKs
ALTER TABLE ONLY "public"."agent_conversations"
    ADD CONSTRAINT "agent_conversations_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."agent_instances"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."agent_conversations"
    ADD CONSTRAINT "agent_conversations_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."agent_conversations"
    ADD CONSTRAINT "agent_conversations_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");

-- agent_tasks FKs
ALTER TABLE ONLY "public"."agent_tasks"
    ADD CONSTRAINT "agent_tasks_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."agent_instances"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."agent_tasks"
    ADD CONSTRAINT "agent_tasks_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."agent_tasks"
    ADD CONSTRAINT "agent_tasks_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."agent_conversations"("id") ON DELETE SET NULL;

-- agent_task_steps FKs
ALTER TABLE ONLY "public"."agent_task_steps"
    ADD CONSTRAINT "agent_task_steps_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."agent_tasks"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."agent_task_steps"
    ADD CONSTRAINT "agent_task_steps_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."agent_instances"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."agent_task_steps"
    ADD CONSTRAINT "agent_task_steps_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

-- ==========================================================
-- INDEXES
-- ==========================================================

-- agent_conversations indexes
CREATE INDEX "idx_agent_conversations_agent_id" ON "public"."agent_conversations" USING "btree" ("agent_id");

CREATE INDEX "idx_agent_conversations_updated_at" ON "public"."agent_conversations" USING "btree" ("updated_at" DESC);

CREATE INDEX "idx_agent_conversations_workspace_id" ON "public"."agent_conversations" USING "btree" ("workspace_id");

-- agent_instances indexes
CREATE INDEX "idx_agent_instances_e2b_status" ON "public"."agent_instances" USING "btree" ("e2b_status") WHERE ("e2b_status" = ANY (ARRAY['running'::"text", 'idle'::"text", 'starting'::"text"]));

CREATE INDEX "idx_agent_instances_status" ON "public"."agent_instances" USING "btree" ("status");

CREATE INDEX "idx_agent_instances_workspace_id" ON "public"."agent_instances" USING "btree" ("workspace_id");

-- agent_task_steps indexes
CREATE INDEX "idx_agent_task_steps_created_at" ON "public"."agent_task_steps" USING "btree" ("created_at");

CREATE INDEX "idx_agent_task_steps_task_id" ON "public"."agent_task_steps" USING "btree" ("task_id");

-- agent_tasks indexes
CREATE INDEX "idx_agent_tasks_agent_id" ON "public"."agent_tasks" USING "btree" ("agent_id");

CREATE INDEX "idx_agent_tasks_conversation_id" ON "public"."agent_tasks" USING "btree" ("conversation_id") WHERE ("conversation_id" IS NOT NULL);

CREATE INDEX "idx_agent_tasks_created_at" ON "public"."agent_tasks" USING "btree" ("created_at" DESC);

CREATE INDEX "idx_agent_tasks_status" ON "public"."agent_tasks" USING "btree" ("status") WHERE ("status" = ANY (ARRAY['queued'::"text", 'running'::"text"]));

CREATE INDEX "idx_agent_tasks_workspace_id" ON "public"."agent_tasks" USING "btree" ("workspace_id");

-- agent_templates indexes
CREATE INDEX "idx_agent_templates_category" ON "public"."agent_templates" USING "btree" ("category");

CREATE INDEX "idx_agent_templates_position" ON "public"."agent_templates" USING "btree" ("position");

CREATE INDEX "idx_agent_templates_slug" ON "public"."agent_templates" USING "btree" ("slug");

-- ==========================================================
-- ROW LEVEL SECURITY
-- ==========================================================

ALTER TABLE "public"."agent_templates" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."agent_instances" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."agent_tasks" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."agent_task_steps" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."agent_conversations" ENABLE ROW LEVEL SECURITY;

-- ==========================================================
-- POLICIES: agent_templates
-- ==========================================================

CREATE POLICY "Authenticated users can view public templates" ON "public"."agent_templates" FOR SELECT USING (("is_public" = true));

-- ==========================================================
-- POLICIES: agent_instances
-- ==========================================================

CREATE POLICY "Users can view agents in their workspaces" ON "public"."agent_instances" FOR SELECT USING (("workspace_id" IN ( SELECT "wm"."workspace_id"
   FROM "public"."workspace_members" "wm"
  WHERE ("wm"."user_id" = "auth"."uid"()))));

CREATE POLICY "Workspace admins can insert agents" ON "public"."agent_instances" FOR INSERT WITH CHECK (("workspace_id" IN ( SELECT "wm"."workspace_id"
   FROM "public"."workspace_members" "wm"
  WHERE (("wm"."user_id" = "auth"."uid"()) AND ("wm"."role" = ANY (ARRAY['owner'::"public"."workspace_role", 'admin'::"public"."workspace_role"]))))));

CREATE POLICY "Workspace admins can update agents" ON "public"."agent_instances" FOR UPDATE USING (("workspace_id" IN ( SELECT "wm"."workspace_id"
   FROM "public"."workspace_members" "wm"
  WHERE (("wm"."user_id" = "auth"."uid"()) AND ("wm"."role" = ANY (ARRAY['owner'::"public"."workspace_role", 'admin'::"public"."workspace_role"]))))));

CREATE POLICY "Workspace admins can delete agents" ON "public"."agent_instances" FOR DELETE USING (("workspace_id" IN ( SELECT "wm"."workspace_id"
   FROM "public"."workspace_members" "wm"
  WHERE (("wm"."user_id" = "auth"."uid"()) AND ("wm"."role" = ANY (ARRAY['owner'::"public"."workspace_role", 'admin'::"public"."workspace_role"]))))));

-- ==========================================================
-- POLICIES: agent_tasks
-- ==========================================================

CREATE POLICY "Users can view tasks in their workspaces" ON "public"."agent_tasks" FOR SELECT USING (("workspace_id" IN ( SELECT "wm"."workspace_id"
   FROM "public"."workspace_members" "wm"
  WHERE ("wm"."user_id" = "auth"."uid"()))));

CREATE POLICY "Users can create tasks in their workspaces" ON "public"."agent_tasks" FOR INSERT WITH CHECK (("workspace_id" IN ( SELECT "wm"."workspace_id"
   FROM "public"."workspace_members" "wm"
  WHERE ("wm"."user_id" = "auth"."uid"()))));

-- ==========================================================
-- POLICIES: agent_task_steps
-- ==========================================================

CREATE POLICY "Users can view steps in their workspaces" ON "public"."agent_task_steps" FOR SELECT USING (("workspace_id" IN ( SELECT "wm"."workspace_id"
   FROM "public"."workspace_members" "wm"
  WHERE ("wm"."user_id" = "auth"."uid"()))));

-- ==========================================================
-- POLICIES: agent_conversations
-- ==========================================================

CREATE POLICY "Users can view conversations in their workspaces" ON "public"."agent_conversations" FOR SELECT USING (("workspace_id" IN ( SELECT "wm"."workspace_id"
   FROM "public"."workspace_members" "wm"
  WHERE ("wm"."user_id" = "auth"."uid"()))));

CREATE POLICY "Users can create conversations in their workspaces" ON "public"."agent_conversations" FOR INSERT WITH CHECK ((("workspace_id" IN ( SELECT "wm"."workspace_id"
   FROM "public"."workspace_members" "wm"
  WHERE ("wm"."user_id" = "auth"."uid"()))) AND ("created_by" = "auth"."uid"())));

CREATE POLICY "Users can update conversations in their workspaces" ON "public"."agent_conversations" FOR UPDATE USING (("workspace_id" IN ( SELECT "wm"."workspace_id"
   FROM "public"."workspace_members" "wm"
  WHERE ("wm"."user_id" = "auth"."uid"()))));

CREATE POLICY "Users can delete their own conversations" ON "public"."agent_conversations" FOR DELETE USING (("created_by" = "auth"."uid"()));

-- ==========================================================
-- TRIGGERS
-- ==========================================================

CREATE OR REPLACE TRIGGER "trigger_agent_instances_updated_at" BEFORE UPDATE ON "public"."agent_instances" FOR EACH ROW EXECUTE FUNCTION "public"."update_agent_instances_updated_at"();

CREATE OR REPLACE TRIGGER "trigger_agent_conversations_updated_at" BEFORE UPDATE ON "public"."agent_conversations" FOR EACH ROW EXECUTE FUNCTION "public"."update_agent_conversations_updated_at"();

CREATE OR REPLACE TRIGGER "trigger_update_conversation_on_task" AFTER INSERT OR UPDATE ON "public"."agent_tasks" FOR EACH ROW EXECUTE FUNCTION "public"."update_conversation_on_task_change"();

-- ==========================================================
-- GRANTS: functions
-- ==========================================================






-- ==========================================================
-- GRANTS: tables
-- ==========================================================





