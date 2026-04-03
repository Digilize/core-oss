-- ============================================================================
-- Migration: Channels and Messaging
-- Description: channels, channel_members, channel_messages, message_reactions,
--              channel_read_status tables with functions, indexes, RLS policies,
--              triggers, and grants
-- ============================================================================

-- ==========================================================
-- FUNCTIONS
-- ==========================================================

-- can_access_channel: Check if a user can access a channel
CREATE OR REPLACE FUNCTION "public"."can_access_channel"("p_channel_id" "uuid", "p_user_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_is_private BOOLEAN;
    v_is_dm BOOLEAN;
    v_dm_participants UUID[];
    v_workspace_app_id UUID;
BEGIN
    -- Get channel info
    SELECT is_private, is_dm, dm_participants, workspace_app_id
    INTO v_is_private, v_is_dm, v_dm_participants, v_workspace_app_id
    FROM public.channels WHERE id = p_channel_id;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- First check: user must be able to access the workspace app
    IF NOT public.can_access_workspace_app(v_workspace_app_id, p_user_id) THEN
        RETURN FALSE;
    END IF;

    -- DM: check if user is a participant
    IF v_is_dm THEN
        RETURN p_user_id = ANY(v_dm_participants);
    END IF;

    -- Public channel: workspace member can access
    IF NOT v_is_private THEN
        RETURN TRUE;
    END IF;

    -- Private channel: check membership
    RETURN EXISTS (
        SELECT 1 FROM public.channel_members
        WHERE channel_id = p_channel_id AND user_id = p_user_id
    );
END;
$$;


-- get_or_create_dm: Finds existing DM between participants or creates a new one
CREATE OR REPLACE FUNCTION "public"."get_or_create_dm"("p_workspace_app_id" "uuid", "p_participant_ids" "uuid"[]) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_channel_id UUID;
    v_sorted_participants UUID[];
BEGIN
    -- Sort participants for consistent lookup
    SELECT array_agg(id ORDER BY id) INTO v_sorted_participants
    FROM unnest(p_participant_ids) AS id;

    -- Check if DM already exists
    SELECT id INTO v_channel_id
    FROM public.channels
    WHERE workspace_app_id = p_workspace_app_id
    AND is_dm = TRUE
    AND dm_participants @> v_sorted_participants
    AND dm_participants <@ v_sorted_participants
    LIMIT 1;

    -- If not found, create it
    IF v_channel_id IS NULL THEN
        INSERT INTO public.channels (
            workspace_app_id,
            name,
            is_dm,
            dm_participants,
            is_private,
            created_by
        ) VALUES (
            p_workspace_app_id,
            NULL,  -- DMs don't have names
            TRUE,
            v_sorted_participants,
            TRUE,  -- DMs are always private
            auth.uid()
        )
        RETURNING id INTO v_channel_id;

        -- Add all participants as channel members
        INSERT INTO public.channel_members (channel_id, user_id, role)
        SELECT v_channel_id, unnest(v_sorted_participants), 'member'
        ON CONFLICT (channel_id, user_id) DO NOTHING;
    END IF;

    RETURN v_channel_id;
END;
$$;


COMMENT ON FUNCTION "public"."get_or_create_dm"("p_workspace_app_id" "uuid", "p_participant_ids" "uuid"[]) IS 'Finds existing DM between participants or creates a new one';

-- get_user_dms: Returns all DM channels for the current user in a workspace
CREATE OR REPLACE FUNCTION "public"."get_user_dms"("p_workspace_app_id" "uuid") RETURNS TABLE("channel_id" "uuid", "dm_participants" "uuid"[], "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.id as channel_id,
        c.dm_participants,
        c.created_at,
        c.updated_at
    FROM public.channels c
    WHERE c.workspace_app_id = p_workspace_app_id
    AND c.is_dm = TRUE
    AND auth.uid() = ANY(c.dm_participants);
END;
$$;


COMMENT ON FUNCTION "public"."get_user_dms"("p_workspace_app_id" "uuid") IS 'Returns all DM channels for the current user in a workspace';

-- get_channel_members_with_profiles
CREATE OR REPLACE FUNCTION "public"."get_channel_members_with_profiles"("p_channel_id" "uuid") RETURNS TABLE("user_id" "uuid", "role" "text", "joined_at" timestamp with time zone, "name" "text", "avatar_url" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_is_private BOOLEAN;
    v_workspace_id UUID;
    v_workspace_app_id UUID;
    v_app_is_public BOOLEAN;
BEGIN
    -- Atomic access check + channel info fetch to avoid TOCTOU
    SELECT
        c.is_private,
        c.workspace_app_id,
        wa.workspace_id,
        wa.is_public
    INTO
        v_is_private,
        v_workspace_app_id,
        v_workspace_id,
        v_app_is_public
    FROM
        channels c
    JOIN
        workspace_apps wa ON wa.id = c.workspace_app_id
    WHERE
        c.id = p_channel_id
        AND can_access_channel(p_channel_id, auth.uid());

    IF NOT FOUND THEN
        -- Either channel does not exist or caller lacks access
        RAISE EXCEPTION 'Channel not found or access denied';
    END IF;

    IF v_is_private THEN
        -- Private channel (and DMs): explicit channel_members
        RETURN QUERY
        SELECT cm.user_id, cm.role, cm.joined_at, u.name, u.avatar_url
        FROM channel_members cm
        JOIN users u ON u.id = cm.user_id
        WHERE cm.channel_id = p_channel_id
        ORDER BY cm.joined_at;
    ELSE
        -- Public channel: visibility depends on the app
        IF v_app_is_public THEN
            -- App is public to workspace: all workspace members
            RETURN QUERY
            SELECT wm.user_id, wm.role::TEXT, wm.joined_at, u.name, u.avatar_url
            FROM workspace_members wm
            JOIN users u ON u.id = wm.user_id
            WHERE wm.workspace_id = v_workspace_id
            ORDER BY wm.joined_at;
        ELSE
            -- App is private: only app members
            RETURN QUERY
            SELECT wam.user_id, 'member'::TEXT, wam.added_at, u.name, u.avatar_url
            FROM workspace_app_members wam
            JOIN users u ON u.id = wam.user_id
            WHERE wam.workspace_app_id = v_workspace_app_id
            ORDER BY wam.added_at;
        END IF;
    END IF;
END;
$$;


-- get_channel_unread_count
CREATE OR REPLACE FUNCTION "public"."get_channel_unread_count"("p_channel_id" "uuid", "p_user_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_last_read TIMESTAMPTZ;
    v_count INTEGER;
BEGIN
    -- Get user's last read timestamp for this channel
    SELECT last_read_at INTO v_last_read
    FROM public.channel_read_status
    WHERE channel_id = p_channel_id AND user_id = p_user_id;

    -- If never read, count all messages (but cap at reasonable number)
    IF v_last_read IS NULL THEN
        v_last_read := '1970-01-01'::TIMESTAMPTZ;
    END IF;

    -- Count messages after last read (excluding user's own messages)
    SELECT COUNT(*) INTO v_count
    FROM public.channel_messages
    WHERE channel_id = p_channel_id
    AND created_at > v_last_read
    AND user_id != p_user_id
    AND thread_parent_id IS NULL;  -- Only count top-level messages

    RETURN v_count;
END;
$$;


COMMENT ON FUNCTION "public"."get_channel_unread_count"("p_channel_id" "uuid", "p_user_id" "uuid") IS 'Returns count of unread messages for a user in a channel';

-- get_workspace_unread_counts
CREATE OR REPLACE FUNCTION "public"."get_workspace_unread_counts"("p_workspace_app_id" "uuid") RETURNS TABLE("channel_id" "uuid", "unread_count" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.id as channel_id,
        public.get_channel_unread_count(c.id, auth.uid()) as unread_count
    FROM public.channels c
    WHERE c.workspace_app_id = p_workspace_app_id
    AND public.can_access_channel(c.id, auth.uid());
END;
$$;


COMMENT ON FUNCTION "public"."get_workspace_unread_counts"("p_workspace_app_id" "uuid") IS 'Returns unread counts for all accessible channels in a workspace app';

-- mark_channel_read
CREATE OR REPLACE FUNCTION "public"."mark_channel_read"("p_channel_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    INSERT INTO public.channel_read_status (channel_id, user_id, last_read_at)
    VALUES (p_channel_id, auth.uid(), NOW())
    ON CONFLICT (channel_id, user_id)
    DO UPDATE SET last_read_at = NOW();
END;
$$;


COMMENT ON FUNCTION "public"."mark_channel_read"("p_channel_id" "uuid") IS 'Marks a channel as read for the current user';

-- auto_add_channel_creator: Auto-add creator as owner of private channels
CREATE OR REPLACE FUNCTION "public"."auto_add_channel_creator"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  BEGIN
      IF NEW.is_private THEN
          INSERT INTO public.channel_members (channel_id, user_id, role)
          VALUES (NEW.id, NEW.created_by, 'owner')
          ON CONFLICT (channel_id, user_id) DO NOTHING;
      END IF;
      RETURN NEW;
  END;
  $$;


-- auto_add_dm_members: Auto-add DM participants as channel members
CREATE OR REPLACE FUNCTION "public"."auto_add_dm_members"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.is_dm AND NEW.dm_participants IS NOT NULL THEN
        INSERT INTO public.channel_members (channel_id, user_id, role)
        SELECT NEW.id, unnest(NEW.dm_participants), 'member'
        ON CONFLICT (channel_id, user_id) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;


-- update_channel_timestamp: Update channel updated_at on new message
CREATE OR REPLACE FUNCTION "public"."update_channel_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE public.channels
    SET updated_at = NOW()
    WHERE id = NEW.channel_id;
    RETURN NEW;
END;
$$;


-- update_thread_reply_count: Update reply count on thread parent
CREATE OR REPLACE FUNCTION "public"."update_thread_reply_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  BEGIN
      IF TG_OP = 'INSERT' AND NEW.thread_parent_id IS NOT NULL THEN
          UPDATE public.channel_messages
          SET reply_count = reply_count + 1
          WHERE id = NEW.thread_parent_id;
      ELSIF TG_OP = 'DELETE' AND OLD.thread_parent_id IS NOT NULL THEN
          UPDATE public.channel_messages
          SET reply_count = GREATEST(0, reply_count - 1)
          WHERE id = OLD.thread_parent_id;
      END IF;
      RETURN COALESCE(NEW, OLD);
  END;
  $$;


-- ==========================================================
-- TABLES
-- ==========================================================

-- channels
CREATE TABLE IF NOT EXISTS "public"."channels" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_app_id" "uuid" NOT NULL,
    "name" "text",
    "description" "text",
    "is_private" boolean DEFAULT false,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_dm" boolean DEFAULT false,
    "dm_participants" "uuid"[],
    CONSTRAINT "check_dm_has_participants" CHECK (((("is_dm" = false) AND ("name" IS NOT NULL)) OR (("is_dm" = true) AND ("dm_participants" IS NOT NULL) AND ("array_length"("dm_participants", 1) >= 1))))
);

ALTER TABLE ONLY "public"."channels" REPLICA IDENTITY FULL;


COMMENT ON TABLE "public"."channels" IS 'Slack-like channels within workspace messaging apps';

COMMENT ON COLUMN "public"."channels"."is_dm" IS 'Whether this is a direct message conversation between specific users';

COMMENT ON COLUMN "public"."channels"."dm_participants" IS 'Array of user IDs in the DM (sorted for consistent lookups)';

-- channel_members
CREATE TABLE IF NOT EXISTS "public"."channel_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "channel_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'member'::"text",
    "joined_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "channel_members_role_check" CHECK (("role" = ANY (ARRAY['owner'::"text", 'moderator'::"text", 'member'::"text"])))
);


COMMENT ON TABLE "public"."channel_members" IS 'Members of private channels';

-- channel_messages
CREATE TABLE IF NOT EXISTS "public"."channel_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "channel_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "content" "text",
    "blocks" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "is_edited" boolean DEFAULT false,
    "edited_at" timestamp with time zone,
    "thread_parent_id" "uuid",
    "reply_count" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "agent_id" "uuid",
    "embedding" "public"."vector"(1536)
);

ALTER TABLE ONLY "public"."channel_messages" REPLICA IDENTITY FULL;


COMMENT ON TABLE "public"."channel_messages" IS 'Messages in channels with block-based content';

COMMENT ON COLUMN "public"."channel_messages"."content" IS 'Plain text extracted from blocks for full-text search';

COMMENT ON COLUMN "public"."channel_messages"."blocks" IS 'Array of content blocks. Types: text, mention, file, link_preview, code, quote, embed';

COMMENT ON COLUMN "public"."channel_messages"."agent_id" IS 'Set when message is from an AI agent (user_id will be NULL)';

-- message_reactions
CREATE TABLE IF NOT EXISTS "public"."message_reactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "message_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "emoji" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."message_reactions" REPLICA IDENTITY FULL;


COMMENT ON TABLE "public"."message_reactions" IS 'Emoji reactions on messages';

-- channel_read_status
CREATE TABLE IF NOT EXISTS "public"."channel_read_status" (
    "channel_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "last_read_at" timestamp with time zone DEFAULT "now"()
);


COMMENT ON TABLE "public"."channel_read_status" IS 'Tracks when each user last read each channel for unread indicators';

-- ==========================================================
-- PRIMARY KEYS & UNIQUE CONSTRAINTS
-- ==========================================================

ALTER TABLE ONLY "public"."channels"
    ADD CONSTRAINT "channels_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."channels"
    ADD CONSTRAINT "channels_workspace_app_id_name_key" UNIQUE ("workspace_app_id", "name");

ALTER TABLE ONLY "public"."channel_members"
    ADD CONSTRAINT "channel_members_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."channel_members"
    ADD CONSTRAINT "channel_members_channel_id_user_id_key" UNIQUE ("channel_id", "user_id");

ALTER TABLE ONLY "public"."channel_messages"
    ADD CONSTRAINT "channel_messages_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."message_reactions"
    ADD CONSTRAINT "message_reactions_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."message_reactions"
    ADD CONSTRAINT "message_reactions_message_id_user_id_emoji_key" UNIQUE ("message_id", "user_id", "emoji");

ALTER TABLE ONLY "public"."channel_read_status"
    ADD CONSTRAINT "channel_read_status_pkey" PRIMARY KEY ("channel_id", "user_id");

-- ==========================================================
-- FOREIGN KEYS
-- ==========================================================

-- channels FKs
ALTER TABLE ONLY "public"."channels"
    ADD CONSTRAINT "channels_workspace_app_id_fkey" FOREIGN KEY ("workspace_app_id") REFERENCES "public"."workspace_apps"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."channels"
    ADD CONSTRAINT "channels_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."channels"
    ADD CONSTRAINT "channels_created_by_public_users_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE CASCADE;

-- channel_members FKs
ALTER TABLE ONLY "public"."channel_members"
    ADD CONSTRAINT "channel_members_channel_id_fkey" FOREIGN KEY ("channel_id") REFERENCES "public"."channels"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."channel_members"
    ADD CONSTRAINT "channel_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."channel_members"
    ADD CONSTRAINT "channel_members_user_id_public_users_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

-- channel_messages FKs
ALTER TABLE ONLY "public"."channel_messages"
    ADD CONSTRAINT "channel_messages_channel_id_fkey" FOREIGN KEY ("channel_id") REFERENCES "public"."channels"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."channel_messages"
    ADD CONSTRAINT "channel_messages_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."channel_messages"
    ADD CONSTRAINT "channel_messages_user_id_public_users_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."channel_messages"
    ADD CONSTRAINT "channel_messages_thread_parent_id_fkey" FOREIGN KEY ("thread_parent_id") REFERENCES "public"."channel_messages"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."channel_messages"
    ADD CONSTRAINT "channel_messages_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."agent_instances"("id") ON DELETE SET NULL;

-- message_reactions FKs
ALTER TABLE ONLY "public"."message_reactions"
    ADD CONSTRAINT "message_reactions_message_id_fkey" FOREIGN KEY ("message_id") REFERENCES "public"."channel_messages"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."message_reactions"
    ADD CONSTRAINT "message_reactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."message_reactions"
    ADD CONSTRAINT "message_reactions_user_id_public_users_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

-- channel_read_status FKs
ALTER TABLE ONLY "public"."channel_read_status"
    ADD CONSTRAINT "channel_read_status_channel_id_fkey" FOREIGN KEY ("channel_id") REFERENCES "public"."channels"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."channel_read_status"
    ADD CONSTRAINT "channel_read_status_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

-- ==========================================================
-- INDEXES
-- ==========================================================

-- channels indexes
CREATE INDEX "idx_channels_workspace_app_id" ON "public"."channels" USING "btree" ("workspace_app_id");

CREATE INDEX "idx_channels_created_by" ON "public"."channels" USING "btree" ("created_by");

CREATE INDEX "idx_channels_dm_participants" ON "public"."channels" USING "gin" ("dm_participants") WHERE ("is_dm" = true);

CREATE INDEX "idx_channels_is_dm" ON "public"."channels" USING "btree" ("workspace_app_id", "is_dm");

-- channel_members indexes
CREATE INDEX "idx_channel_members_channel_id" ON "public"."channel_members" USING "btree" ("channel_id");

CREATE INDEX "idx_channel_members_user_id" ON "public"."channel_members" USING "btree" ("user_id");

-- channel_messages indexes
CREATE INDEX "idx_channel_messages_agent_id" ON "public"."channel_messages" USING "btree" ("agent_id") WHERE ("agent_id" IS NOT NULL);

CREATE INDEX "idx_channel_messages_blocks" ON "public"."channel_messages" USING "gin" ("blocks");

CREATE INDEX "idx_channel_messages_channel_id" ON "public"."channel_messages" USING "btree" ("channel_id");

CREATE INDEX "idx_channel_messages_content_search" ON "public"."channel_messages" USING "gin" ("to_tsvector"('"english"'::"regconfig", COALESCE("content", ''::"text")));

CREATE INDEX "idx_channel_messages_created_at" ON "public"."channel_messages" USING "btree" ("created_at" DESC);

CREATE INDEX "idx_channel_messages_embedding" ON "public"."channel_messages" USING "hnsw" ("embedding" "public"."vector_cosine_ops") WITH ("m"='16', "ef_construction"='64');

CREATE INDEX "idx_channel_messages_thread_parent_id" ON "public"."channel_messages" USING "btree" ("thread_parent_id");

CREATE INDEX "idx_channel_messages_user_id" ON "public"."channel_messages" USING "btree" ("user_id");

-- channel_read_status indexes
CREATE INDEX "idx_channel_read_status_channel_last_read" ON "public"."channel_read_status" USING "btree" ("channel_id", "last_read_at");

CREATE INDEX "idx_channel_read_status_user_id" ON "public"."channel_read_status" USING "btree" ("user_id");

-- message_reactions indexes
CREATE INDEX "idx_message_reactions_message_id" ON "public"."message_reactions" USING "btree" ("message_id");

-- ==========================================================
-- ROW LEVEL SECURITY
-- ==========================================================

ALTER TABLE "public"."channels" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."channel_members" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."channel_messages" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."message_reactions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."channel_read_status" ENABLE ROW LEVEL SECURITY;

-- ==========================================================
-- POLICIES: channels
-- ==========================================================

CREATE POLICY "Users can view accessible channels" ON "public"."channels" FOR SELECT USING (("public"."can_access_workspace_app"("workspace_app_id", "auth"."uid"()) AND ((("is_dm" = false) AND ("is_private" = false)) OR (("is_private" = true) AND ("is_dm" = false) AND (("created_by" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."channel_members"
  WHERE (("channel_members"."channel_id" = "channels"."id") AND ("channel_members"."user_id" = "auth"."uid"())))))) OR (("is_dm" = true) AND ("auth"."uid"() = ANY ("dm_participants"))))));

CREATE POLICY "Workspace members can create channels" ON "public"."channels" FOR INSERT WITH CHECK (("public"."can_access_workspace_app"("workspace_app_id", "auth"."uid"()) AND ("created_by" = "auth"."uid"())));

CREATE POLICY "Channel creators can update channels" ON "public"."channels" FOR UPDATE USING ((("created_by" = "auth"."uid"()) OR "public"."is_workspace_admin"(( SELECT "workspace_apps"."workspace_id"
   FROM "public"."workspace_apps"
  WHERE ("workspace_apps"."id" = "channels"."workspace_app_id")), "auth"."uid"())));

CREATE POLICY "Channel creators can delete channels" ON "public"."channels" FOR DELETE USING ((("created_by" = "auth"."uid"()) OR "public"."is_workspace_admin"(( SELECT "workspace_apps"."workspace_id"
   FROM "public"."workspace_apps"
  WHERE ("workspace_apps"."id" = "channels"."workspace_app_id")), "auth"."uid"())));

-- ==========================================================
-- POLICIES: channel_members
-- ==========================================================

CREATE POLICY "Channel members can view members" ON "public"."channel_members" FOR SELECT USING ("public"."can_access_channel"("channel_id", "auth"."uid"()));

CREATE POLICY "Channel owners can add members" ON "public"."channel_members" FOR INSERT WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."channel_members" "cm"
  WHERE (("cm"."channel_id" = "channel_members"."channel_id") AND ("cm"."user_id" = "auth"."uid"()) AND ("cm"."role" = ANY (ARRAY['owner'::"text", 'moderator'::"text"]))))) OR (EXISTS ( SELECT 1
   FROM "public"."channels" "c"
  WHERE (("c"."id" = "channel_members"."channel_id") AND ("c"."created_by" = "auth"."uid"()))))));

CREATE POLICY "Channel owners can remove members" ON "public"."channel_members" FOR DELETE USING ((("user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."channel_members" "cm"
  WHERE (("cm"."channel_id" = "channel_members"."channel_id") AND ("cm"."user_id" = "auth"."uid"()) AND ("cm"."role" = ANY (ARRAY['owner'::"text", 'moderator'::"text"])))))));

-- ==========================================================
-- POLICIES: channel_messages
-- ==========================================================

CREATE POLICY "Users can view messages in accessible channels" ON "public"."channel_messages" FOR SELECT USING ("public"."can_access_channel"("channel_id", "auth"."uid"()));

CREATE POLICY "Users can post to accessible channels" ON "public"."channel_messages" FOR INSERT WITH CHECK (("public"."can_access_channel"("channel_id", "auth"."uid"()) AND ("user_id" = "auth"."uid"())));

CREATE POLICY "Users can edit their own messages" ON "public"."channel_messages" FOR UPDATE USING (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can delete their own messages" ON "public"."channel_messages" FOR DELETE USING ((("user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."channel_members" "cm"
  WHERE (("cm"."channel_id" = "channel_messages"."channel_id") AND ("cm"."user_id" = "auth"."uid"()) AND ("cm"."role" = ANY (ARRAY['owner'::"text", 'moderator'::"text"])))))));

-- ==========================================================
-- POLICIES: message_reactions
-- ==========================================================

CREATE POLICY "Users can view reactions" ON "public"."message_reactions" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."channel_messages" "m"
  WHERE (("m"."id" = "message_reactions"."message_id") AND "public"."can_access_channel"("m"."channel_id", "auth"."uid"())))));

CREATE POLICY "Users can add reactions" ON "public"."message_reactions" FOR INSERT WITH CHECK ((("user_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."channel_messages" "m"
  WHERE (("m"."id" = "message_reactions"."message_id") AND "public"."can_access_channel"("m"."channel_id", "auth"."uid"()))))));

CREATE POLICY "Users can remove their own reactions" ON "public"."message_reactions" FOR DELETE USING (("user_id" = "auth"."uid"()));

-- ==========================================================
-- POLICIES: channel_read_status
-- ==========================================================

CREATE POLICY "Users can view their own read status" ON "public"."channel_read_status" FOR SELECT USING (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can update their own read status" ON "public"."channel_read_status" FOR INSERT WITH CHECK (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can modify their own read status" ON "public"."channel_read_status" FOR UPDATE USING (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can delete their own read status" ON "public"."channel_read_status" FOR DELETE USING (("user_id" = "auth"."uid"()));

-- ==========================================================
-- TRIGGERS
-- ==========================================================

CREATE OR REPLACE TRIGGER "trigger_update_thread_reply_count" AFTER INSERT OR DELETE ON "public"."channel_messages" FOR EACH ROW EXECUTE FUNCTION "public"."update_thread_reply_count"();

CREATE OR REPLACE TRIGGER "trigger_update_channel_timestamp" AFTER INSERT ON "public"."channel_messages" FOR EACH ROW EXECUTE FUNCTION "public"."update_channel_timestamp"();

CREATE OR REPLACE TRIGGER "trigger_auto_add_channel_creator" AFTER INSERT ON "public"."channels" FOR EACH ROW EXECUTE FUNCTION "public"."auto_add_channel_creator"();

CREATE OR REPLACE TRIGGER "trigger_auto_add_dm_members" AFTER INSERT ON "public"."channels" FOR EACH ROW WHEN (("new"."is_dm" = true)) EXECUTE FUNCTION "public"."auto_add_dm_members"();

-- ==========================================================
-- GRANTS: functions
-- ==========================================================












-- ==========================================================
-- GRANTS: tables
-- ==========================================================





