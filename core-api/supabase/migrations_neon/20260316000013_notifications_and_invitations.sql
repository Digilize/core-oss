-- Migration: Notifications, Notification Subscriptions, Notification Preferences, Workspace Invitations

----------------------------------------------------------------------------
-- Tables
----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "workspace_id" "uuid",
    "type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text",
    "resource_type" "text",
    "resource_id" "uuid",
    "actor_id" "uuid",
    "read" boolean DEFAULT false NOT NULL,
    "seen" boolean DEFAULT false NOT NULL,
    "archived" boolean DEFAULT false NOT NULL,
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);



CREATE TABLE IF NOT EXISTS "public"."notification_subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "resource_type" "text" NOT NULL,
    "resource_id" "uuid" NOT NULL,
    "reason" "text" DEFAULT 'manual'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);



CREATE TABLE IF NOT EXISTS "public"."notification_preferences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "workspace_id" "uuid",
    "category" "text" NOT NULL,
    "in_app" boolean DEFAULT true NOT NULL,
    "push" boolean DEFAULT true NOT NULL,
    "email_digest" boolean DEFAULT false NOT NULL,
    "muted_until" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);



CREATE TABLE IF NOT EXISTS "public"."workspace_invitations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "role" "public"."workspace_role" DEFAULT 'member'::"public"."workspace_role" NOT NULL,
    "invited_by_user_id" "uuid",
    "status" "public"."workspace_invitation_status" DEFAULT 'pending'::"public"."workspace_invitation_status" NOT NULL,
    "token" "text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "accepted_by_user_id" "uuid",
    "accepted_at" timestamp with time zone,
    "declined_at" timestamp with time zone,
    "revoked_at" timestamp with time zone,
    "last_email_sent_at" timestamp with time zone,
    "last_email_error" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "workspace_invitations_role_check" CHECK (("role" = ANY (ARRAY['member'::"public"."workspace_role", 'admin'::"public"."workspace_role"])))
);



----------------------------------------------------------------------------
-- Primary Keys & Unique Constraints
----------------------------------------------------------------------------

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."notification_subscriptions"
    ADD CONSTRAINT "notification_subscriptions_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."notification_subscriptions"
    ADD CONSTRAINT "notification_subscriptions_user_id_resource_type_resource_i_key" UNIQUE ("user_id", "resource_type", "resource_id");

ALTER TABLE ONLY "public"."notification_preferences"
    ADD CONSTRAINT "notification_preferences_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."notification_preferences"
    ADD CONSTRAINT "notification_preferences_user_id_workspace_id_category_key" UNIQUE ("user_id", "workspace_id", "category");

ALTER TABLE ONLY "public"."workspace_invitations"
    ADD CONSTRAINT "workspace_invitations_pkey" PRIMARY KEY ("id");


----------------------------------------------------------------------------
-- Foreign Keys
----------------------------------------------------------------------------

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."notification_subscriptions"
    ADD CONSTRAINT "notification_subscriptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."notification_preferences"
    ADD CONSTRAINT "notification_preferences_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."notification_preferences"
    ADD CONSTRAINT "notification_preferences_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."workspace_invitations"
    ADD CONSTRAINT "workspace_invitations_accepted_by_user_id_fkey" FOREIGN KEY ("accepted_by_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."workspace_invitations"
    ADD CONSTRAINT "workspace_invitations_invited_by_user_id_fkey" FOREIGN KEY ("invited_by_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."workspace_invitations"
    ADD CONSTRAINT "workspace_invitations_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;


----------------------------------------------------------------------------
-- Indexes
----------------------------------------------------------------------------

-- notifications indexes
CREATE INDEX "idx_notifications_created_at" ON "public"."notifications" USING "btree" ("created_at");
CREATE INDEX "idx_notifications_user_resource" ON "public"."notifications" USING "btree" ("user_id", "resource_type", "resource_id");
CREATE INDEX "idx_notifications_user_unread" ON "public"."notifications" USING "btree" ("user_id", "created_at" DESC) WHERE (("read" = false) AND ("archived" = false));
CREATE INDEX "idx_notifications_user_workspace" ON "public"."notifications" USING "btree" ("user_id", "workspace_id", "created_at" DESC) WHERE ("archived" = false);
CREATE UNIQUE INDEX "uq_notifications_workspace_invite_active" ON "public"."notifications" USING "btree" ("user_id", "resource_type", "resource_id") WHERE (("resource_type" = 'workspace_invitation'::"text") AND ("resource_id" IS NOT NULL) AND ("archived" = false));

-- notification_subscriptions indexes
CREATE INDEX "idx_notification_subs_resource" ON "public"."notification_subscriptions" USING "btree" ("resource_type", "resource_id");
CREATE INDEX "idx_notification_subs_user" ON "public"."notification_subscriptions" USING "btree" ("user_id");

-- notification_preferences indexes
CREATE INDEX "idx_notification_prefs_user" ON "public"."notification_preferences" USING "btree" ("user_id");

-- workspace_invitations indexes
CREATE INDEX "idx_workspace_invites_email_pending" ON "public"."workspace_invitations" USING "btree" ("lower"("email"), "expires_at") WHERE ("status" = 'pending'::"public"."workspace_invitation_status");
CREATE INDEX "idx_workspace_invites_workspace_status_created" ON "public"."workspace_invitations" USING "btree" ("workspace_id", "status", "created_at" DESC);
CREATE UNIQUE INDEX "uq_workspace_invites_pending" ON "public"."workspace_invitations" USING "btree" ("workspace_id", "lower"("email")) WHERE ("status" = 'pending'::"public"."workspace_invitation_status");
CREATE UNIQUE INDEX "uq_workspace_invites_token" ON "public"."workspace_invitations" USING "btree" ("token");


----------------------------------------------------------------------------
-- Row Level Security
----------------------------------------------------------------------------

ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."notification_subscriptions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."notification_preferences" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."workspace_invitations" ENABLE ROW LEVEL SECURITY;


----------------------------------------------------------------------------
-- Policies: notifications
----------------------------------------------------------------------------

CREATE POLICY "Service role can insert notifications" ON "public"."notifications" FOR INSERT WITH CHECK (true);

CREATE POLICY "Users can read own notifications" ON "public"."notifications" FOR SELECT USING (("auth"."uid"() = "user_id"));

CREATE POLICY "Users can update own notifications" ON "public"."notifications" FOR UPDATE USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));


----------------------------------------------------------------------------
-- Policies: notification_subscriptions
----------------------------------------------------------------------------

CREATE POLICY "Service role can manage subscriptions" ON "public"."notification_subscriptions" WITH CHECK (true);

CREATE POLICY "Users can read own subscriptions" ON "public"."notification_subscriptions" FOR SELECT USING (("auth"."uid"() = "user_id"));

CREATE POLICY "Users can manage own subscriptions" ON "public"."notification_subscriptions" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));


----------------------------------------------------------------------------
-- Policies: notification_preferences
----------------------------------------------------------------------------

CREATE POLICY "Users can manage own preferences" ON "public"."notification_preferences" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));


----------------------------------------------------------------------------
-- Policies: workspace_invitations
----------------------------------------------------------------------------

CREATE POLICY "Service role can manage workspace invitations" ON "public"."workspace_invitations" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));


----------------------------------------------------------------------------
-- Triggers
----------------------------------------------------------------------------

CREATE OR REPLACE TRIGGER "set_workspace_invitations_updated_at" BEFORE UPDATE ON "public"."workspace_invitations" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();


----------------------------------------------------------------------------
-- Grants: Tables
----------------------------------------------------------------------------




