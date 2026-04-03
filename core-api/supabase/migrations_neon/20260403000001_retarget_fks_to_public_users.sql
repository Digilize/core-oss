-- =============================================================================
-- Phase 5: FK Retargeting — auth.users → public.users
-- =============================================================================
-- All FK references that previously pointed to Supabase's auth.users table
-- are retargeted to public.users, which is now the authoritative user table.
-- public.users is populated by the new-user hook in core-auth when a user
-- signs up via better-auth.
-- =============================================================================

-- Drop all FKs that reference auth.users

-- core_tables
ALTER TABLE "public"."users"               DROP CONSTRAINT IF EXISTS "users_id_fkey";
ALTER TABLE "public"."user_preferences"    DROP CONSTRAINT IF EXISTS "user_preferences_user_id_fkey";

-- workspaces
ALTER TABLE "public"."workspaces"           DROP CONSTRAINT IF EXISTS "workspaces_owner_id_fkey";
ALTER TABLE "public"."workspace_members"    DROP CONSTRAINT IF EXISTS "workspace_members_user_id_fkey";
ALTER TABLE "public"."workspace_app_members" DROP CONSTRAINT IF EXISTS "workspace_app_members_user_id_fkey";
ALTER TABLE "public"."workspace_app_members" DROP CONSTRAINT IF EXISTS "workspace_app_members_added_by_fkey";

-- notifications_and_invitations
ALTER TABLE "public"."notifications"                DROP CONSTRAINT IF EXISTS "notifications_actor_id_fkey";
ALTER TABLE "public"."notifications"                DROP CONSTRAINT IF EXISTS "notifications_user_id_fkey";
ALTER TABLE "public"."notification_subscriptions"   DROP CONSTRAINT IF EXISTS "notification_subscriptions_user_id_fkey";
ALTER TABLE "public"."notification_preferences"     DROP CONSTRAINT IF EXISTS "notification_preferences_user_id_fkey";
ALTER TABLE "public"."workspace_invitations"        DROP CONSTRAINT IF EXISTS "workspace_invitations_accepted_by_user_id_fkey";
ALTER TABLE "public"."workspace_invitations"        DROP CONSTRAINT IF EXISTS "workspace_invitations_invited_by_user_id_fkey";

-- projects
ALTER TABLE "public"."project_boards"           DROP CONSTRAINT IF EXISTS "project_boards_created_by_fkey";
ALTER TABLE "public"."project_issues"           DROP CONSTRAINT IF EXISTS "project_issues_created_by_fkey";
ALTER TABLE "public"."project_labels"           DROP CONSTRAINT IF EXISTS "project_labels_created_by_fkey";
ALTER TABLE "public"."project_issue_assignees"  DROP CONSTRAINT IF EXISTS "project_issue_assignees_user_id_fkey";
ALTER TABLE "public"."project_issue_comments"   DROP CONSTRAINT IF EXISTS "project_issue_comments_user_id_fkey";
ALTER TABLE "public"."project_comment_reactions" DROP CONSTRAINT IF EXISTS "project_comment_reactions_user_id_fkey";

-- sharing_permissions
ALTER TABLE "public"."permissions"      DROP CONSTRAINT IF EXISTS "permissions_granted_by_fkey";
ALTER TABLE "public"."permissions"      DROP CONSTRAINT IF EXISTS "permissions_grantee_id_fkey";
ALTER TABLE "public"."access_requests"  DROP CONSTRAINT IF EXISTS "access_requests_requester_id_fkey";
ALTER TABLE "public"."access_requests"  DROP CONSTRAINT IF EXISTS "access_requests_reviewed_by_fkey";

-- sites_and_builder
ALTER TABLE "public"."builder_projects" DROP CONSTRAINT IF EXISTS "builder_projects_user_id_fkey";

-- channels_and_messaging
ALTER TABLE "public"."channels"          DROP CONSTRAINT IF EXISTS "channels_created_by_fkey";
ALTER TABLE "public"."channel_members"   DROP CONSTRAINT IF EXISTS "channel_members_user_id_fkey";
ALTER TABLE "public"."channel_messages"  DROP CONSTRAINT IF EXISTS "channel_messages_user_id_fkey";
ALTER TABLE "public"."message_reactions" DROP CONSTRAINT IF EXISTS "message_reactions_user_id_fkey";
ALTER TABLE "public"."channel_read_status" DROP CONSTRAINT IF EXISTS "channel_read_status_user_id_fkey";

-- files_and_documents
ALTER TABLE "public"."files"             DROP CONSTRAINT IF EXISTS "files_user_id_fkey";
ALTER TABLE "public"."document_versions" DROP CONSTRAINT IF EXISTS "document_versions_created_by_fkey";

-- search_and_embeddings
ALTER TABLE "public"."entities"              DROP CONSTRAINT IF EXISTS "entities_user_id_fkey";
ALTER TABLE "public"."memory_facts"          DROP CONSTRAINT IF EXISTS "memory_facts_user_id_fkey";
ALTER TABLE "public"."memory_episodes"       DROP CONSTRAINT IF EXISTS "memory_episodes_user_id_fkey";
ALTER TABLE "public"."memory_relationships"  DROP CONSTRAINT IF EXISTS "memory_relationships_user_id_fkey";
ALTER TABLE "public"."user_memory"           DROP CONSTRAINT IF EXISTS "user_memory_user_id_fkey";

-- chat_system
ALTER TABLE "public"."conversations"    DROP CONSTRAINT IF EXISTS "conversations_user_id_fkey";
ALTER TABLE "public"."chat_attachments" DROP CONSTRAINT IF EXISTS "chat_attachments_user_id_fkey";

-- agents
ALTER TABLE "public"."agent_instances"     DROP CONSTRAINT IF EXISTS "agent_instances_created_by_fkey";
ALTER TABLE "public"."agent_conversations" DROP CONSTRAINT IF EXISTS "agent_conversations_created_by_fkey";


-- =============================================================================
-- Re-create all FKs pointing to public.users(id)
-- public.users is now standalone — no FK to auth.users
-- =============================================================================

-- user_preferences
ALTER TABLE "public"."user_preferences"
    ADD CONSTRAINT "user_preferences_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

-- workspaces
ALTER TABLE "public"."workspaces"
    ADD CONSTRAINT "workspaces_owner_id_fkey"
    FOREIGN KEY ("owner_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."workspace_members"
    ADD CONSTRAINT "workspace_members_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."workspace_app_members"
    ADD CONSTRAINT "workspace_app_members_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."workspace_app_members"
    ADD CONSTRAINT "workspace_app_members_added_by_fkey"
    FOREIGN KEY ("added_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;

-- notifications_and_invitations
ALTER TABLE "public"."notifications"
    ADD CONSTRAINT "notifications_actor_id_fkey"
    FOREIGN KEY ("actor_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;

ALTER TABLE "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."notification_subscriptions"
    ADD CONSTRAINT "notification_subscriptions_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."notification_preferences"
    ADD CONSTRAINT "notification_preferences_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."workspace_invitations"
    ADD CONSTRAINT "workspace_invitations_accepted_by_user_id_fkey"
    FOREIGN KEY ("accepted_by_user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;

ALTER TABLE "public"."workspace_invitations"
    ADD CONSTRAINT "workspace_invitations_invited_by_user_id_fkey"
    FOREIGN KEY ("invited_by_user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;

-- projects
ALTER TABLE "public"."project_boards"
    ADD CONSTRAINT "project_boards_created_by_fkey"
    FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;

ALTER TABLE "public"."project_issues"
    ADD CONSTRAINT "project_issues_created_by_fkey"
    FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."project_labels"
    ADD CONSTRAINT "project_labels_created_by_fkey"
    FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;

ALTER TABLE "public"."project_issue_assignees"
    ADD CONSTRAINT "project_issue_assignees_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."project_issue_comments"
    ADD CONSTRAINT "project_issue_comments_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."project_comment_reactions"
    ADD CONSTRAINT "project_comment_reactions_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

-- sharing_permissions
ALTER TABLE "public"."permissions"
    ADD CONSTRAINT "permissions_granted_by_fkey"
    FOREIGN KEY ("granted_by") REFERENCES "public"."users"("id");

ALTER TABLE "public"."permissions"
    ADD CONSTRAINT "permissions_grantee_id_fkey"
    FOREIGN KEY ("grantee_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."access_requests"
    ADD CONSTRAINT "access_requests_requester_id_fkey"
    FOREIGN KEY ("requester_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."access_requests"
    ADD CONSTRAINT "access_requests_reviewed_by_fkey"
    FOREIGN KEY ("reviewed_by") REFERENCES "public"."users"("id");

-- sites_and_builder
ALTER TABLE "public"."builder_projects"
    ADD CONSTRAINT "builder_projects_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

-- channels_and_messaging
ALTER TABLE "public"."channels"
    ADD CONSTRAINT "channels_created_by_fkey"
    FOREIGN KEY ("created_by") REFERENCES "public"."users"("id");

ALTER TABLE "public"."channel_members"
    ADD CONSTRAINT "channel_members_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."channel_messages"
    ADD CONSTRAINT "channel_messages_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");

ALTER TABLE "public"."message_reactions"
    ADD CONSTRAINT "message_reactions_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."channel_read_status"
    ADD CONSTRAINT "channel_read_status_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

-- files_and_documents
ALTER TABLE "public"."files"
    ADD CONSTRAINT "files_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."document_versions"
    ADD CONSTRAINT "document_versions_created_by_fkey"
    FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;

-- search_and_embeddings
ALTER TABLE "public"."entities"
    ADD CONSTRAINT "entities_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."memory_facts"
    ADD CONSTRAINT "memory_facts_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."memory_episodes"
    ADD CONSTRAINT "memory_episodes_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."memory_relationships"
    ADD CONSTRAINT "memory_relationships_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."user_memory"
    ADD CONSTRAINT "user_memory_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

-- chat_system
ALTER TABLE "public"."conversations"
    ADD CONSTRAINT "conversations_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE "public"."chat_attachments"
    ADD CONSTRAINT "chat_attachments_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

-- agents
ALTER TABLE "public"."agent_instances"
    ADD CONSTRAINT "agent_instances_created_by_fkey"
    FOREIGN KEY ("created_by") REFERENCES "public"."users"("id");

ALTER TABLE "public"."agent_conversations"
    ADD CONSTRAINT "agent_conversations_created_by_fkey"
    FOREIGN KEY ("created_by") REFERENCES "public"."users"("id");
