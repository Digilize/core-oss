-- Migration: Projects (boards, states, issues, labels, comments, reactions, assignees)
-- Tables: project_boards, project_states, project_issues, project_labels,
--         project_issue_labels, project_issue_assignees, project_issue_comments,
--         project_comment_reactions

----------------------------------------------------------------------------
-- Functions
----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION "public"."allocate_project_issue_number"("p_board_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_number INT;
BEGIN
    UPDATE project_boards
    SET next_issue_number = next_issue_number + 1
    WHERE id = p_board_id
    RETURNING next_issue_number - 1 INTO v_number;

    IF v_number IS NULL THEN
        RAISE EXCEPTION 'Board not found or not accessible: %', p_board_id;
    END IF;

    RETURN v_number;
END;
$$;



CREATE OR REPLACE FUNCTION "public"."check_max_assignees"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    current_count INT;
BEGIN
    SELECT COUNT(*) INTO current_count
    FROM project_issue_assignees
    WHERE issue_id = NEW.issue_id;

    IF current_count >= 10 THEN
        RAISE EXCEPTION 'Maximum of 10 assignees per issue reached';
    END IF;

    RETURN NEW;
END;
$$;



CREATE OR REPLACE FUNCTION "public"."manage_project_issue_completion"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_is_done BOOLEAN;
BEGIN
    -- Only act when state_id changes
    IF OLD.state_id IS DISTINCT FROM NEW.state_id THEN
        SELECT is_done INTO v_is_done
        FROM project_states
        WHERE id = NEW.state_id;

        IF v_is_done = TRUE AND OLD.completed_at IS NULL THEN
            NEW.completed_at = NOW();
        ELSIF v_is_done = FALSE AND OLD.completed_at IS NOT NULL THEN
            NEW.completed_at = NULL;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;



CREATE OR REPLACE FUNCTION "public"."move_project_issue"("p_issue_id" "uuid", "p_target_state_id" "uuid", "p_position" integer) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_old_state_id UUID;
    v_old_position INT;
    v_is_done BOOLEAN;
    v_board_id UUID;
BEGIN
    -- Get current issue state
    SELECT state_id, position, board_id
    INTO v_old_state_id, v_old_position, v_board_id
    FROM project_issues
    WHERE id = p_issue_id;

    IF v_old_state_id IS NULL THEN
        RAISE EXCEPTION 'Issue not found or not accessible: %', p_issue_id;
    END IF;

    -- Verify target state belongs to the same board
    PERFORM 1 FROM project_states
    WHERE id = p_target_state_id AND board_id = v_board_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target state does not belong to the same board';
    END IF;

    -- Close gap in old state (shift positions down)
    IF v_old_state_id IS DISTINCT FROM p_target_state_id THEN
        UPDATE project_issues
        SET position = position - 1
        WHERE state_id = v_old_state_id
          AND position > v_old_position;
    END IF;

    -- Make room in target state (shift positions up)
    UPDATE project_issues
    SET position = position + 1
    WHERE state_id = p_target_state_id
      AND position >= p_position
      AND id <> p_issue_id;

    -- Check if target state is a "done" state
    SELECT is_done INTO v_is_done
    FROM project_states
    WHERE id = p_target_state_id;

    -- Move the issue
    UPDATE project_issues
    SET state_id = p_target_state_id,
        position = p_position,
        completed_at = CASE
            WHEN v_is_done = TRUE THEN COALESCE(completed_at, NOW())
            ELSE NULL
        END
    WHERE id = p_issue_id;
END;
$$;



CREATE OR REPLACE FUNCTION "public"."reorder_project_issues"("p_state_id" "uuid", "p_items" "jsonb") RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_item JSONB;
    v_updated_count INT := 0;
    v_expected_count INT := jsonb_array_length(COALESCE(p_items, '[]'::jsonb));
BEGIN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        UPDATE project_issues
        SET position = (v_item->>'position')::INT
        WHERE id = (v_item->>'id')::UUID
          AND state_id = p_state_id;

        IF FOUND THEN
            v_updated_count := v_updated_count + 1;
        END IF;
    END LOOP;

    IF v_updated_count <> v_expected_count THEN
        RAISE EXCEPTION 'Expected to update % issues, but updated %', v_expected_count, v_updated_count;
    END IF;

    RETURN v_updated_count;
END;
$$;



CREATE OR REPLACE FUNCTION "public"."reorder_project_states"("p_board_id" "uuid", "p_items" "jsonb") RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_item JSONB;
    v_updated_count INT := 0;
    v_expected_count INT := jsonb_array_length(COALESCE(p_items, '[]'::jsonb));
BEGIN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        UPDATE project_states
        SET position = (v_item->>'position')::INT
        WHERE id = (v_item->>'id')::UUID
          AND board_id = p_board_id;

        IF FOUND THEN
            v_updated_count := v_updated_count + 1;
        END IF;
    END LOOP;

    IF v_updated_count <> v_expected_count THEN
        RAISE EXCEPTION 'Expected to update % states, but updated %', v_expected_count, v_updated_count;
    END IF;

    RETURN v_updated_count;
END;
$$;



----------------------------------------------------------------------------
-- Tables
----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS "public"."project_boards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_app_id" "uuid" NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "key" "text",
    "icon" "text",
    "color" "text",
    "position" integer DEFAULT 0 NOT NULL,
    "next_issue_number" integer DEFAULT 1 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);



CREATE TABLE IF NOT EXISTS "public"."project_states" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_app_id" "uuid" NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "board_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "color" "text",
    "position" integer DEFAULT 0 NOT NULL,
    "is_done" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);



CREATE TABLE IF NOT EXISTS "public"."project_issues" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_app_id" "uuid" NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "board_id" "uuid" NOT NULL,
    "state_id" "uuid" NOT NULL,
    "number" integer NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "priority" integer DEFAULT 0 NOT NULL,
    "due_at" timestamp with time zone,
    "position" integer DEFAULT 0 NOT NULL,
    "created_by" "uuid" NOT NULL,
    "completed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "image_r2_keys" "text"[] DEFAULT '{}'::"text"[],
    CONSTRAINT "project_issues_priority_check" CHECK ((("priority" >= 0) AND ("priority" <= 4)))
);


COMMENT ON COLUMN "public"."project_issues"."image_r2_keys" IS 'Array of R2 object keys for issue images (proxy URLs generated on fetch)';


CREATE TABLE IF NOT EXISTS "public"."project_labels" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_app_id" "uuid" NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "board_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "color" "text" DEFAULT '#6B7280'::"text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);



CREATE TABLE IF NOT EXISTS "public"."project_issue_labels" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_app_id" "uuid" NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "issue_id" "uuid" NOT NULL,
    "label_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);



CREATE TABLE IF NOT EXISTS "public"."project_issue_assignees" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_app_id" "uuid" NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "issue_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);



CREATE TABLE IF NOT EXISTS "public"."project_issue_comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_app_id" "uuid" NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "issue_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "content" "text",
    "blocks" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "is_edited" boolean DEFAULT false,
    "edited_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."project_issue_comments" REPLICA IDENTITY FULL;


COMMENT ON TABLE "public"."project_issue_comments" IS 'GitHub-style flat comments on project issues';
COMMENT ON COLUMN "public"."project_issue_comments"."content" IS 'Plain text extracted from blocks for full-text search';
COMMENT ON COLUMN "public"."project_issue_comments"."blocks" IS 'Array of content blocks. Types: text, mention, code, quote';


CREATE TABLE IF NOT EXISTS "public"."project_comment_reactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_app_id" "uuid" NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "comment_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "emoji" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."project_comment_reactions" REPLICA IDENTITY FULL;


COMMENT ON TABLE "public"."project_comment_reactions" IS 'Emoji reactions on issue comments';


----------------------------------------------------------------------------
-- Primary Keys & Unique Constraints
----------------------------------------------------------------------------

ALTER TABLE ONLY "public"."project_boards"
    ADD CONSTRAINT "project_boards_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."project_states"
    ADD CONSTRAINT "project_states_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."project_issues"
    ADD CONSTRAINT "project_issues_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."project_labels"
    ADD CONSTRAINT "project_labels_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."project_issue_labels"
    ADD CONSTRAINT "project_issue_labels_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."project_issue_assignees"
    ADD CONSTRAINT "project_issue_assignees_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."project_issue_comments"
    ADD CONSTRAINT "project_issue_comments_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."project_comment_reactions"
    ADD CONSTRAINT "project_comment_reactions_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."project_comment_reactions"
    ADD CONSTRAINT "project_comment_reactions_comment_id_user_id_emoji_key" UNIQUE ("comment_id", "user_id", "emoji");


----------------------------------------------------------------------------
-- Foreign Keys
----------------------------------------------------------------------------

ALTER TABLE ONLY "public"."project_boards"
    ADD CONSTRAINT "project_boards_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."project_boards"
    ADD CONSTRAINT "project_boards_workspace_app_id_fkey" FOREIGN KEY ("workspace_app_id") REFERENCES "public"."workspace_apps"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_boards"
    ADD CONSTRAINT "project_boards_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_states"
    ADD CONSTRAINT "project_states_board_id_fkey" FOREIGN KEY ("board_id") REFERENCES "public"."project_boards"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_states"
    ADD CONSTRAINT "project_states_workspace_app_id_fkey" FOREIGN KEY ("workspace_app_id") REFERENCES "public"."workspace_apps"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_states"
    ADD CONSTRAINT "project_states_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issues"
    ADD CONSTRAINT "project_issues_board_id_fkey" FOREIGN KEY ("board_id") REFERENCES "public"."project_boards"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issues"
    ADD CONSTRAINT "project_issues_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issues"
    ADD CONSTRAINT "project_issues_state_id_fkey" FOREIGN KEY ("state_id") REFERENCES "public"."project_states"("id") ON DELETE RESTRICT;

ALTER TABLE ONLY "public"."project_issues"
    ADD CONSTRAINT "project_issues_workspace_app_id_fkey" FOREIGN KEY ("workspace_app_id") REFERENCES "public"."workspace_apps"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issues"
    ADD CONSTRAINT "project_issues_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_labels"
    ADD CONSTRAINT "project_labels_board_id_fkey" FOREIGN KEY ("board_id") REFERENCES "public"."project_boards"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_labels"
    ADD CONSTRAINT "project_labels_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."project_labels"
    ADD CONSTRAINT "project_labels_workspace_app_id_fkey" FOREIGN KEY ("workspace_app_id") REFERENCES "public"."workspace_apps"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_labels"
    ADD CONSTRAINT "project_labels_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issue_labels"
    ADD CONSTRAINT "project_issue_labels_issue_id_fkey" FOREIGN KEY ("issue_id") REFERENCES "public"."project_issues"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issue_labels"
    ADD CONSTRAINT "project_issue_labels_label_id_fkey" FOREIGN KEY ("label_id") REFERENCES "public"."project_labels"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issue_labels"
    ADD CONSTRAINT "project_issue_labels_workspace_app_id_fkey" FOREIGN KEY ("workspace_app_id") REFERENCES "public"."workspace_apps"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issue_labels"
    ADD CONSTRAINT "project_issue_labels_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issue_assignees"
    ADD CONSTRAINT "project_issue_assignees_issue_id_fkey" FOREIGN KEY ("issue_id") REFERENCES "public"."project_issues"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issue_assignees"
    ADD CONSTRAINT "project_issue_assignees_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issue_assignees"
    ADD CONSTRAINT "project_issue_assignees_workspace_app_id_fkey" FOREIGN KEY ("workspace_app_id") REFERENCES "public"."workspace_apps"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issue_assignees"
    ADD CONSTRAINT "project_issue_assignees_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issue_comments"
    ADD CONSTRAINT "project_issue_comments_issue_id_fkey" FOREIGN KEY ("issue_id") REFERENCES "public"."project_issues"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issue_comments"
    ADD CONSTRAINT "project_issue_comments_public_users_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

COMMENT ON CONSTRAINT "project_issue_comments_public_users_fkey" ON "public"."project_issue_comments" IS 'FK to public.users enables PostgREST user:users(...) embeds';

ALTER TABLE ONLY "public"."project_issue_comments"
    ADD CONSTRAINT "project_issue_comments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issue_comments"
    ADD CONSTRAINT "project_issue_comments_workspace_app_id_fkey" FOREIGN KEY ("workspace_app_id") REFERENCES "public"."workspace_apps"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_issue_comments"
    ADD CONSTRAINT "project_issue_comments_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_comment_reactions"
    ADD CONSTRAINT "project_comment_reactions_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "public"."project_issue_comments"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_comment_reactions"
    ADD CONSTRAINT "project_comment_reactions_public_users_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

COMMENT ON CONSTRAINT "project_comment_reactions_public_users_fkey" ON "public"."project_comment_reactions" IS 'FK to public.users enables PostgREST user:users(...) embeds';

ALTER TABLE ONLY "public"."project_comment_reactions"
    ADD CONSTRAINT "project_comment_reactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_comment_reactions"
    ADD CONSTRAINT "project_comment_reactions_workspace_app_id_fkey" FOREIGN KEY ("workspace_app_id") REFERENCES "public"."workspace_apps"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."project_comment_reactions"
    ADD CONSTRAINT "project_comment_reactions_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;


----------------------------------------------------------------------------
-- Indexes
----------------------------------------------------------------------------

-- project_boards indexes
CREATE INDEX "idx_project_boards_position" ON "public"."project_boards" USING "btree" ("workspace_app_id", "position");
CREATE UNIQUE INDEX "idx_project_boards_unique_key" ON "public"."project_boards" USING "btree" ("workspace_app_id", "key") WHERE ("key" IS NOT NULL);
CREATE INDEX "idx_project_boards_workspace_app_id" ON "public"."project_boards" USING "btree" ("workspace_app_id");
CREATE INDEX "idx_project_boards_workspace_id" ON "public"."project_boards" USING "btree" ("workspace_id");

-- project_states indexes
CREATE INDEX "idx_project_states_board_id" ON "public"."project_states" USING "btree" ("board_id");
CREATE INDEX "idx_project_states_position" ON "public"."project_states" USING "btree" ("board_id", "position");
CREATE UNIQUE INDEX "idx_project_states_unique_name" ON "public"."project_states" USING "btree" ("board_id", "name");
CREATE INDEX "idx_project_states_workspace_app_id" ON "public"."project_states" USING "btree" ("workspace_app_id");

-- project_issues indexes
CREATE INDEX "idx_project_issues_board_id" ON "public"."project_issues" USING "btree" ("board_id");
CREATE UNIQUE INDEX "idx_project_issues_board_number" ON "public"."project_issues" USING "btree" ("board_id", "number");
CREATE INDEX "idx_project_issues_due_at" ON "public"."project_issues" USING "btree" ("workspace_id", "due_at") WHERE ("due_at" IS NOT NULL);
CREATE INDEX "idx_project_issues_state_id" ON "public"."project_issues" USING "btree" ("state_id");
CREATE INDEX "idx_project_issues_state_position" ON "public"."project_issues" USING "btree" ("state_id", "position");
CREATE INDEX "idx_project_issues_workspace_app_id" ON "public"."project_issues" USING "btree" ("workspace_app_id");

-- project_labels indexes
CREATE INDEX "idx_project_labels_board_id" ON "public"."project_labels" USING "btree" ("board_id");
CREATE UNIQUE INDEX "idx_project_labels_board_name" ON "public"."project_labels" USING "btree" ("board_id", "name");
CREATE INDEX "idx_project_labels_workspace_app_id" ON "public"."project_labels" USING "btree" ("workspace_app_id");

-- project_issue_labels indexes
CREATE INDEX "idx_project_issue_labels_issue_id" ON "public"."project_issue_labels" USING "btree" ("issue_id");
CREATE INDEX "idx_project_issue_labels_label_id" ON "public"."project_issue_labels" USING "btree" ("label_id");
CREATE UNIQUE INDEX "idx_project_issue_labels_unique" ON "public"."project_issue_labels" USING "btree" ("issue_id", "label_id");
CREATE INDEX "idx_project_issue_labels_workspace_app_id" ON "public"."project_issue_labels" USING "btree" ("workspace_app_id");

-- project_issue_assignees indexes
CREATE INDEX "idx_project_issue_assignees_issue_id" ON "public"."project_issue_assignees" USING "btree" ("issue_id");
CREATE UNIQUE INDEX "idx_project_issue_assignees_unique" ON "public"."project_issue_assignees" USING "btree" ("issue_id", "user_id");
CREATE INDEX "idx_project_issue_assignees_user_id" ON "public"."project_issue_assignees" USING "btree" ("user_id");
CREATE INDEX "idx_project_issue_assignees_workspace_app_id" ON "public"."project_issue_assignees" USING "btree" ("workspace_app_id");

-- project_issue_comments indexes
CREATE INDEX "idx_project_issue_comments_content_search" ON "public"."project_issue_comments" USING "gin" ("to_tsvector"('"english"'::"regconfig", COALESCE("content", ''::"text")));
CREATE INDEX "idx_project_issue_comments_created_at" ON "public"."project_issue_comments" USING "btree" ("created_at" DESC);
CREATE INDEX "idx_project_issue_comments_issue_created" ON "public"."project_issue_comments" USING "btree" ("issue_id", "created_at");
CREATE INDEX "idx_project_issue_comments_issue_id" ON "public"."project_issue_comments" USING "btree" ("issue_id");
CREATE INDEX "idx_project_issue_comments_user_id" ON "public"."project_issue_comments" USING "btree" ("user_id");
CREATE INDEX "idx_project_issue_comments_workspace_app_id" ON "public"."project_issue_comments" USING "btree" ("workspace_app_id");

-- project_comment_reactions indexes
CREATE INDEX "idx_project_comment_reactions_comment_id" ON "public"."project_comment_reactions" USING "btree" ("comment_id");


----------------------------------------------------------------------------
-- Row Level Security
----------------------------------------------------------------------------

ALTER TABLE "public"."project_boards" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."project_states" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."project_issues" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."project_labels" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."project_issue_labels" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."project_issue_assignees" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."project_issue_comments" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."project_comment_reactions" ENABLE ROW LEVEL SECURITY;


----------------------------------------------------------------------------
-- Policies: project_boards
----------------------------------------------------------------------------

CREATE POLICY "Members can view boards in accessible workspace apps" ON "public"."project_boards" FOR SELECT USING ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Members can create boards in accessible workspace apps" ON "public"."project_boards" FOR INSERT WITH CHECK (("public"."can_access_workspace_app"("workspace_app_id") AND (("created_by" IS NULL) OR ("created_by" = "auth"."uid"()))));

CREATE POLICY "Members can update boards in accessible workspace apps" ON "public"."project_boards" FOR UPDATE USING ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Creator or admin can delete boards" ON "public"."project_boards" FOR DELETE USING ((("created_by" = "auth"."uid"()) OR "public"."is_workspace_admin"("workspace_id")));


----------------------------------------------------------------------------
-- Policies: project_states
----------------------------------------------------------------------------

CREATE POLICY "Members can view states in accessible workspace apps" ON "public"."project_states" FOR SELECT USING ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Members can create states in accessible workspace apps" ON "public"."project_states" FOR INSERT WITH CHECK ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Members can update states in accessible workspace apps" ON "public"."project_states" FOR UPDATE USING ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Admin can delete states" ON "public"."project_states" FOR DELETE USING ("public"."is_workspace_admin"("workspace_id"));


----------------------------------------------------------------------------
-- Policies: project_issues
----------------------------------------------------------------------------

CREATE POLICY "Members can view issues in accessible workspace apps" ON "public"."project_issues" FOR SELECT USING ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Members can create issues in accessible workspace apps" ON "public"."project_issues" FOR INSERT WITH CHECK (("public"."can_access_workspace_app"("workspace_app_id") AND ("created_by" = "auth"."uid"())));

CREATE POLICY "Members can update issues in accessible workspace apps" ON "public"."project_issues" FOR UPDATE USING ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Creator or admin can delete issues" ON "public"."project_issues" FOR DELETE USING ((("created_by" = "auth"."uid"()) OR "public"."is_workspace_admin"("workspace_id")));


----------------------------------------------------------------------------
-- Policies: project_labels
----------------------------------------------------------------------------

CREATE POLICY "Members can view labels in accessible workspace apps" ON "public"."project_labels" FOR SELECT USING ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Members can create labels in accessible workspace apps" ON "public"."project_labels" FOR INSERT WITH CHECK ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Members can update labels in accessible workspace apps" ON "public"."project_labels" FOR UPDATE USING ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Members can delete labels in accessible workspace apps" ON "public"."project_labels" FOR DELETE USING ("public"."can_access_workspace_app"("workspace_app_id"));


----------------------------------------------------------------------------
-- Policies: project_issue_labels
----------------------------------------------------------------------------

CREATE POLICY "Members can view issue labels in accessible workspace apps" ON "public"."project_issue_labels" FOR SELECT USING ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Members can add issue labels in accessible workspace apps" ON "public"."project_issue_labels" FOR INSERT WITH CHECK ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Members can remove issue labels in accessible workspace apps" ON "public"."project_issue_labels" FOR DELETE USING ("public"."can_access_workspace_app"("workspace_app_id"));


----------------------------------------------------------------------------
-- Policies: project_issue_assignees
----------------------------------------------------------------------------

CREATE POLICY "Members can view assignees in accessible workspace apps" ON "public"."project_issue_assignees" FOR SELECT USING ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Members can add assignees in accessible workspace apps" ON "public"."project_issue_assignees" FOR INSERT WITH CHECK ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Members can remove assignees in accessible workspace apps" ON "public"."project_issue_assignees" FOR DELETE USING ("public"."can_access_workspace_app"("workspace_app_id"));


----------------------------------------------------------------------------
-- Policies: project_issue_comments
----------------------------------------------------------------------------

CREATE POLICY "Members can view comments in accessible workspace apps" ON "public"."project_issue_comments" FOR SELECT USING ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Members can create comments in accessible workspace apps" ON "public"."project_issue_comments" FOR INSERT WITH CHECK (("public"."can_access_workspace_app"("workspace_app_id") AND ("user_id" = "auth"."uid"())));

CREATE POLICY "Users can edit their own comments" ON "public"."project_issue_comments" FOR UPDATE USING (("user_id" = "auth"."uid"()));

CREATE POLICY "Author or admin can delete comments" ON "public"."project_issue_comments" FOR DELETE USING ((("user_id" = "auth"."uid"()) OR "public"."is_workspace_admin"("workspace_id")));


----------------------------------------------------------------------------
-- Policies: project_comment_reactions
----------------------------------------------------------------------------

CREATE POLICY "Members can view comment reactions" ON "public"."project_comment_reactions" FOR SELECT USING ("public"."can_access_workspace_app"("workspace_app_id"));

CREATE POLICY "Members can add comment reactions" ON "public"."project_comment_reactions" FOR INSERT WITH CHECK (("public"."can_access_workspace_app"("workspace_app_id") AND ("user_id" = "auth"."uid"())));

CREATE POLICY "Users can remove their own comment reactions" ON "public"."project_comment_reactions" FOR DELETE USING (("user_id" = "auth"."uid"()));


----------------------------------------------------------------------------
-- Triggers
----------------------------------------------------------------------------

CREATE OR REPLACE TRIGGER "update_project_boards_updated_at" BEFORE UPDATE ON "public"."project_boards" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();

CREATE OR REPLACE TRIGGER "update_project_states_updated_at" BEFORE UPDATE ON "public"."project_states" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();

CREATE OR REPLACE TRIGGER "update_project_issues_updated_at" BEFORE UPDATE ON "public"."project_issues" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();

CREATE OR REPLACE TRIGGER "trigger_manage_project_issue_completion" BEFORE UPDATE ON "public"."project_issues" FOR EACH ROW EXECUTE FUNCTION "public"."manage_project_issue_completion"();

CREATE OR REPLACE TRIGGER "update_project_labels_updated_at" BEFORE UPDATE ON "public"."project_labels" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();

CREATE OR REPLACE TRIGGER "trigger_check_max_assignees" BEFORE INSERT ON "public"."project_issue_assignees" FOR EACH ROW EXECUTE FUNCTION "public"."check_max_assignees"();


----------------------------------------------------------------------------
-- Grants: Functions
----------------------------------------------------------------------------








----------------------------------------------------------------------------
-- Grants: Tables
----------------------------------------------------------------------------








