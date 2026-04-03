-- Migration: Sharing & Permissions (permissions, access_requests)
-- Functions: has_resource_permission, has_direct_permission, has_direct_write_permission,
--            can_manage_shares, validate_share_link, resolve_share_link_grant

-- Disable function body validation so LANGUAGE sql functions referencing
-- the permissions table (defined later in this file) don't fail at CREATE time.
SET check_function_bodies = false;

----------------------------------------------------------------------------
-- Functions
----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION "public"."can_manage_shares"("p_user_id" "uuid", "p_resource_type" "text", "p_resource_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_workspace_id UUID;
BEGIN
    -- Check 1: Has admin permission via permissions table
    IF EXISTS (
        SELECT 1 FROM public.permissions
        WHERE resource_type = p_resource_type
        AND resource_id = p_resource_id
        AND grantee_type = 'user'
        AND grantee_id = p_user_id
        AND permission = 'admin'
        AND (expires_at IS NULL OR expires_at > now())
    ) THEN RETURN TRUE; END IF;

    -- Check 2: Is resource owner/creator
    CASE p_resource_type
        WHEN 'document', 'folder' THEN
            IF EXISTS (SELECT 1 FROM public.documents WHERE id = p_resource_id AND user_id = p_user_id) THEN RETURN TRUE; END IF;
            SELECT workspace_id INTO v_workspace_id FROM public.documents WHERE id = p_resource_id;
        WHEN 'file' THEN
            IF EXISTS (SELECT 1 FROM public.files WHERE id = p_resource_id AND user_id = p_user_id) THEN RETURN TRUE; END IF;
            SELECT workspace_id INTO v_workspace_id FROM public.files WHERE id = p_resource_id;
        WHEN 'project_board' THEN
            IF EXISTS (SELECT 1 FROM public.project_boards WHERE id = p_resource_id AND created_by = p_user_id) THEN RETURN TRUE; END IF;
            SELECT workspace_id INTO v_workspace_id FROM public.project_boards WHERE id = p_resource_id;
        WHEN 'channel' THEN
            IF EXISTS (SELECT 1 FROM public.channels WHERE id = p_resource_id AND created_by = p_user_id) THEN RETURN TRUE; END IF;
            SELECT wa.workspace_id INTO v_workspace_id FROM public.channels c JOIN public.workspace_apps wa ON wa.id = c.workspace_app_id WHERE c.id = p_resource_id;
        WHEN 'workspace_app' THEN
            SELECT workspace_id INTO v_workspace_id FROM public.workspace_apps WHERE id = p_resource_id;
        ELSE
            RETURN FALSE;
    END CASE;

    -- Check 3: Is workspace admin/owner
    IF v_workspace_id IS NOT NULL THEN
        RETURN public.is_workspace_admin(v_workspace_id, p_user_id);
    END IF;

    RETURN FALSE;
END;
$$;



CREATE OR REPLACE FUNCTION "public"."has_direct_permission"("p_user_id" "uuid", "p_resource_type" "text", "p_resource_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.permissions
        WHERE resource_type = p_resource_type
        AND resource_id = p_resource_id
        AND grantee_type = 'user'
        AND grantee_id = p_user_id
        AND (expires_at IS NULL OR expires_at > now())
    );
$$;



CREATE OR REPLACE FUNCTION "public"."has_direct_write_permission"("p_user_id" "uuid", "p_resource_type" "text", "p_resource_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.permissions
        WHERE resource_type = p_resource_type
        AND resource_id = p_resource_id
        AND grantee_type = 'user'
        AND grantee_id = p_user_id
        AND permission IN ('write', 'admin')
        AND (expires_at IS NULL OR expires_at > now())
    );
$$;



CREATE OR REPLACE FUNCTION "public"."has_resource_permission"("p_user_id" "uuid", "p_resource_type" "text", "p_resource_id" "uuid", "p_required_permission" "text" DEFAULT 'read'::"text", "p_link_token" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_allowed_permissions TEXT[];
    v_has_access BOOLEAN := FALSE;
BEGIN
    IF p_required_permission = 'read' THEN
        v_allowed_permissions := ARRAY['read', 'write', 'admin'];
    ELSIF p_required_permission = 'write' THEN
        v_allowed_permissions := ARRAY['write', 'admin'];
    ELSIF p_required_permission = 'admin' THEN
        v_allowed_permissions := ARRAY['admin'];
    ELSE
        RETURN FALSE;
    END IF;

    -- Check 1: Direct user permission
    IF p_user_id IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1 FROM public.permissions
            WHERE resource_type = p_resource_type
            AND resource_id = p_resource_id
            AND grantee_type = 'user'
            AND grantee_id = p_user_id
            AND permission = ANY(v_allowed_permissions)
            AND (expires_at IS NULL OR expires_at > now())
        ) INTO v_has_access;
        IF v_has_access THEN RETURN TRUE; END IF;
    END IF;

    -- Check 2: Link token
    IF p_link_token IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1 FROM public.permissions
            WHERE resource_type = p_resource_type
            AND resource_id = p_resource_id
            AND grantee_type = 'link'
            AND link_token = p_link_token
            AND permission = ANY(v_allowed_permissions)
            AND (expires_at IS NULL OR expires_at > now())
        ) INTO v_has_access;
        IF v_has_access THEN RETURN TRUE; END IF;
    END IF;

    -- Check 3: Public access (read only)
    IF p_required_permission = 'read' THEN
        SELECT EXISTS (
            SELECT 1 FROM public.permissions
            WHERE resource_type = p_resource_type
            AND resource_id = p_resource_id
            AND grantee_type = 'public'
            AND (expires_at IS NULL OR expires_at > now())
        ) INTO v_has_access;
        IF v_has_access THEN RETURN TRUE; END IF;
    END IF;

    -- Check 4: Folder ancestry (documents/folders only)
    IF p_resource_type IN ('document', 'folder') AND p_user_id IS NOT NULL THEN
        WITH RECURSIVE ancestors AS (
            SELECT id, parent_id FROM public.documents WHERE id = p_resource_id
            UNION ALL
            SELECT d.id, d.parent_id FROM public.documents d
            JOIN ancestors a ON d.id = a.parent_id
            WHERE a.parent_id IS NOT NULL
        )
        SELECT EXISTS (
            SELECT 1 FROM public.permissions p
            JOIN ancestors a ON p.resource_id = a.id
            WHERE p.resource_type IN ('document', 'folder')
            AND p.grantee_type = 'user'
            AND p.grantee_id = p_user_id
            AND p.permission = ANY(v_allowed_permissions)
            AND (p.expires_at IS NULL OR p.expires_at > now())
            AND a.id != p_resource_id
        ) INTO v_has_access;
        IF v_has_access THEN RETURN TRUE; END IF;
    END IF;

    RETURN FALSE;
END;
$$;



CREATE OR REPLACE FUNCTION "public"."validate_share_link"("p_link_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_link RECORD;
BEGIN
  -- 1) Token lookup has precedence to avoid namespace ambiguity.
  SELECT * INTO v_link
  FROM public.permissions
  WHERE link_token = p_link_token
    AND grantee_type = 'link';

  -- 2) Fallback to slug lookup (case-insensitive).
  IF NOT FOUND THEN
    SELECT * INTO v_link
    FROM public.permissions
    WHERE lower(link_slug) = lower(p_link_token)
      AND grantee_type = 'link';
  END IF;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Treat expired links as not found.
  IF v_link.expires_at IS NOT NULL AND v_link.expires_at < now() THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'resource_type', v_link.resource_type,
    'resource_id', v_link.resource_id,
    'workspace_id', v_link.workspace_id,
    'permission', v_link.permission,
    'granted_by', v_link.granted_by
  );
END;
$$;



CREATE OR REPLACE FUNCTION "public"."resolve_share_link_grant"("p_link_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_link RECORD;
  v_user_id UUID;
  v_effective_permission TEXT;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- 1) Token lookup has precedence to avoid namespace ambiguity.
  SELECT * INTO v_link
  FROM public.permissions
  WHERE link_token = p_link_token
    AND grantee_type = 'link';

  -- 2) Fallback to slug lookup (case-insensitive).
  IF NOT FOUND THEN
    SELECT * INTO v_link
    FROM public.permissions
    WHERE lower(link_slug) = lower(p_link_token)
      AND grantee_type = 'link';
  END IF;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Treat expired links as not found.
  IF v_link.expires_at IS NOT NULL AND v_link.expires_at < now() THEN
    RETURN NULL;
  END IF;

  -- If caller is the link creator, skip granting — just return info.
  IF v_user_id = v_link.granted_by THEN
    RETURN jsonb_build_object(
      'resource_type', v_link.resource_type,
      'resource_id', v_link.resource_id,
      'workspace_id', v_link.workspace_id,
      'permission', v_link.permission,
      'granted_by', v_link.granted_by
    );
  END IF;

  -- Grant or upgrade permission (never downgrade).
  INSERT INTO public.permissions (
    workspace_id, resource_type, resource_id,
    grantee_type, grantee_id, permission, granted_by
  ) VALUES (
    v_link.workspace_id, v_link.resource_type, v_link.resource_id,
    'user', v_user_id, v_link.permission, v_link.granted_by
  )
  ON CONFLICT (resource_type, resource_id, grantee_id)
  DO UPDATE SET
    permission = CASE
      WHEN public.permissions.expires_at IS NOT NULL AND public.permissions.expires_at <= now()
        THEN EXCLUDED.permission
      WHEN (CASE EXCLUDED.permission WHEN 'read' THEN 1 WHEN 'write' THEN 2 WHEN 'admin' THEN 3 ELSE 0 END) >
           (CASE public.permissions.permission WHEN 'read' THEN 1 WHEN 'write' THEN 2 WHEN 'admin' THEN 3 ELSE 0 END)
        THEN EXCLUDED.permission
      ELSE public.permissions.permission
    END,
    expires_at = CASE
      WHEN public.permissions.expires_at IS NOT NULL AND public.permissions.expires_at <= now() THEN NULL
      ELSE public.permissions.expires_at
    END
  RETURNING permission INTO v_effective_permission;

  RETURN jsonb_build_object(
    'resource_type', v_link.resource_type,
    'resource_id', v_link.resource_id,
    'workspace_id', v_link.workspace_id,
    'permission', v_effective_permission,
    'granted_by', v_link.granted_by
  );
END;
$$;



----------------------------------------------------------------------------
-- Tables
----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS "public"."permissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workspace_id" "uuid",
    "resource_type" "text" NOT NULL,
    "resource_id" "uuid" NOT NULL,
    "grantee_type" "text" NOT NULL,
    "grantee_id" "uuid",
    "permission" "text" NOT NULL,
    "link_token" "text",
    "granted_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone,
    "link_slug" "text",
    CONSTRAINT "permissions_link_slug_format" CHECK ((("link_slug" IS NULL) OR ("link_slug" ~ '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$'::"text"))),
    CONSTRAINT "permissions_link_slug_link_only" CHECK ((("link_slug" IS NULL) OR ("grantee_type" = 'link'::"text"))),
    CONSTRAINT "permissions_link_slug_not_hex_token" CHECK ((("link_slug" IS NULL) OR ("link_slug" !~ '^[0-9a-f]{32}$'::"text"))),
    CONSTRAINT "valid_grantee" CHECK (((("grantee_type" = 'user'::"text") AND ("grantee_id" IS NOT NULL)) OR (("grantee_type" = 'link'::"text") AND ("link_token" IS NOT NULL)) OR ("grantee_type" = 'public'::"text"))),
    CONSTRAINT "valid_grantee_type" CHECK (("grantee_type" = ANY (ARRAY['user'::"text", 'link'::"text", 'public'::"text"]))),
    CONSTRAINT "valid_permission" CHECK (("permission" = ANY (ARRAY['read'::"text", 'write'::"text", 'admin'::"text"]))),
    CONSTRAINT "valid_resource_type" CHECK (("resource_type" = ANY (ARRAY['workspace_app'::"text", 'folder'::"text", 'document'::"text", 'file'::"text", 'project_board'::"text", 'channel'::"text"])))
);



CREATE TABLE IF NOT EXISTS "public"."access_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "resource_type" "text" NOT NULL,
    "resource_id" "uuid" NOT NULL,
    "workspace_id" "uuid",
    "requester_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "message" "text",
    "reviewed_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    CONSTRAINT "valid_status" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'denied'::"text"])))
);



----------------------------------------------------------------------------
-- Primary Keys & Unique Constraints
----------------------------------------------------------------------------

ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_link_token_key" UNIQUE ("link_token");

ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "uq_permissions_resource_grantee" UNIQUE ("resource_type", "resource_id", "grantee_id");

ALTER TABLE ONLY "public"."access_requests"
    ADD CONSTRAINT "access_requests_pkey" PRIMARY KEY ("id");


----------------------------------------------------------------------------
-- Foreign Keys
----------------------------------------------------------------------------

ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_granted_by_fkey" FOREIGN KEY ("granted_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_grantee_id_fkey" FOREIGN KEY ("grantee_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."access_requests"
    ADD CONSTRAINT "access_requests_requester_id_fkey" FOREIGN KEY ("requester_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."access_requests"
    ADD CONSTRAINT "access_requests_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."access_requests"
    ADD CONSTRAINT "access_requests_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;


----------------------------------------------------------------------------
-- Indexes
----------------------------------------------------------------------------

-- permissions indexes
CREATE INDEX "idx_permissions_grantee" ON "public"."permissions" USING "btree" ("grantee_id") WHERE ("grantee_type" = 'user'::"text");
CREATE INDEX "idx_permissions_link" ON "public"."permissions" USING "btree" ("link_token") WHERE ("link_token" IS NOT NULL);
CREATE UNIQUE INDEX "idx_permissions_link_slug_lower_unique" ON "public"."permissions" USING "btree" ("lower"("link_slug")) WHERE ("link_slug" IS NOT NULL);
CREATE UNIQUE INDEX "idx_permissions_public_unique" ON "public"."permissions" USING "btree" ("resource_type", "resource_id") WHERE ("grantee_type" = 'public'::"text");
CREATE INDEX "idx_permissions_resource" ON "public"."permissions" USING "btree" ("resource_type", "resource_id");
CREATE UNIQUE INDEX "idx_permissions_user_unique" ON "public"."permissions" USING "btree" ("resource_type", "resource_id", "grantee_id") WHERE ("grantee_type" = 'user'::"text");
CREATE INDEX "idx_permissions_workspace_grantee" ON "public"."permissions" USING "btree" ("workspace_id", "grantee_id") WHERE ("grantee_type" = 'user'::"text");

-- access_requests indexes
CREATE UNIQUE INDEX "idx_access_requests_pending_unique" ON "public"."access_requests" USING "btree" ("resource_type", "resource_id", "requester_id") WHERE ("status" = 'pending'::"text");
CREATE INDEX "idx_access_requests_requester" ON "public"."access_requests" USING "btree" ("requester_id");
CREATE INDEX "idx_access_requests_resource" ON "public"."access_requests" USING "btree" ("resource_type", "resource_id", "status");


----------------------------------------------------------------------------
-- Row Level Security
----------------------------------------------------------------------------

ALTER TABLE "public"."permissions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."access_requests" ENABLE ROW LEVEL SECURITY;


----------------------------------------------------------------------------
-- Policies: permissions
----------------------------------------------------------------------------

CREATE POLICY "Users can view permissions they manage or own grants" ON "public"."permissions" FOR SELECT USING (("public"."can_manage_shares"("auth"."uid"(), "resource_type", "resource_id") OR (("grantee_type" = 'user'::"text") AND ("grantee_id" = "auth"."uid"()))));

CREATE POLICY "Share managers can create permissions" ON "public"."permissions" FOR INSERT WITH CHECK ("public"."can_manage_shares"("auth"."uid"(), "resource_type", "resource_id"));

CREATE POLICY "Share managers can update permissions" ON "public"."permissions" FOR UPDATE USING ("public"."can_manage_shares"("auth"."uid"(), "resource_type", "resource_id"));

CREATE POLICY "Share managers can delete permissions" ON "public"."permissions" FOR DELETE USING ("public"."can_manage_shares"("auth"."uid"(), "resource_type", "resource_id"));


----------------------------------------------------------------------------
-- Policies: access_requests
----------------------------------------------------------------------------

CREATE POLICY "Users can view own requests or requests they manage" ON "public"."access_requests" FOR SELECT USING ((("requester_id" = "auth"."uid"()) OR "public"."can_manage_shares"("auth"."uid"(), "resource_type", "resource_id")));

CREATE POLICY "Users can create access requests" ON "public"."access_requests" FOR INSERT WITH CHECK (("requester_id" = "auth"."uid"()));

CREATE POLICY "Share managers can update requests" ON "public"."access_requests" FOR UPDATE USING ("public"."can_manage_shares"("auth"."uid"(), "resource_type", "resource_id"));


----------------------------------------------------------------------------
-- Grants: Functions
----------------------------------------------------------------------------








----------------------------------------------------------------------------
-- Grants: Tables
----------------------------------------------------------------------------




----------------------------------------------------------------------------
-- Cross-domain policies that depend on sharing functions/tables
-- These are defined here instead of their home domain files because they
-- reference has_direct_permission / has_direct_write_permission / permissions
----------------------------------------------------------------------------

-- Workspace SELECT with sharing (replaces simple "Members can view workspace" from 00003)
DROP POLICY IF EXISTS "Members can view workspace" ON "public"."workspaces";
CREATE POLICY "Members and shared users can view workspace" ON "public"."workspaces" FOR SELECT USING (("public"."is_workspace_member"("id") OR (EXISTS ( SELECT 1
   FROM "public"."permissions"
  WHERE (("permissions"."workspace_id" = "workspaces"."id") AND ("permissions"."grantee_type" = 'user'::"text") AND ("permissions"."grantee_id" = "auth"."uid"()))))));

-- Files SELECT/UPDATE with sharing
CREATE POLICY "Users can view own or workspace or shared files" ON "public"."files" FOR SELECT USING ((("auth"."uid"() = "user_id") OR (("workspace_app_id" IS NOT NULL) AND "public"."can_access_workspace_app"("workspace_app_id")) OR "public"."has_direct_permission"("auth"."uid"(), 'file'::"text", "id") OR (EXISTS ( SELECT 1
   FROM "public"."documents" "d"
  WHERE (("d"."file_id" = "files"."id") AND ("public"."has_direct_permission"("auth"."uid"(), 'document'::"text", "d"."id") OR "public"."has_direct_permission"("auth"."uid"(), 'folder'::"text", "d"."id")))))));

CREATE POLICY "Users can update own or workspace or shared files" ON "public"."files" FOR UPDATE USING ((("auth"."uid"() = "user_id") OR (("workspace_app_id" IS NOT NULL) AND "public"."can_access_workspace_app"("workspace_app_id")) OR "public"."has_direct_write_permission"("auth"."uid"(), 'file'::"text", "id") OR (EXISTS ( SELECT 1
   FROM "public"."documents" "d"
  WHERE (("d"."file_id" = "files"."id") AND ("public"."has_direct_write_permission"("auth"."uid"(), 'document'::"text", "d"."id") OR "public"."has_direct_write_permission"("auth"."uid"(), 'folder'::"text", "d"."id")))))));

-- Documents SELECT/UPDATE with sharing
CREATE POLICY "Users can view own or workspace or shared documents" ON "public"."documents" FOR SELECT USING ((("auth"."uid"() = "user_id") OR (("workspace_app_id" IS NOT NULL) AND "public"."can_access_workspace_app"("workspace_app_id")) OR "public"."has_direct_permission"("auth"."uid"(), 'document'::"text", "id") OR "public"."has_direct_permission"("auth"."uid"(), 'folder'::"text", "id") OR "public"."has_direct_permission"("auth"."uid"(), 'file'::"text", "file_id")));

CREATE POLICY "Users can update own or workspace or shared documents" ON "public"."documents" FOR UPDATE USING ((("auth"."uid"() = "user_id") OR (("workspace_app_id" IS NOT NULL) AND "public"."can_access_workspace_app"("workspace_app_id")) OR "public"."has_direct_write_permission"("auth"."uid"(), 'document'::"text", "id") OR "public"."has_direct_write_permission"("auth"."uid"(), 'folder'::"text", "id") OR "public"."has_direct_write_permission"("auth"."uid"(), 'file'::"text", "file_id")));

-- Note attachments (all sharing-dependent)
CREATE POLICY "Users can view note attachments" ON "public"."note_attachments" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."documents" "d"
  WHERE (("d"."id" = "note_attachments"."document_id") AND (("d"."user_id" = "auth"."uid"()) OR (("d"."workspace_app_id" IS NOT NULL) AND "public"."can_access_workspace_app"("d"."workspace_app_id")) OR "public"."has_direct_permission"("auth"."uid"(), 'document'::"text", "d"."id") OR "public"."has_direct_permission"("auth"."uid"(), 'folder'::"text", "d"."id"))))));

CREATE POLICY "Users can insert note attachments" ON "public"."note_attachments" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."documents" "d"
  WHERE (("d"."id" = "note_attachments"."document_id") AND (("d"."user_id" = "auth"."uid"()) OR (("d"."workspace_app_id" IS NOT NULL) AND "public"."can_access_workspace_app"("d"."workspace_app_id")) OR "public"."has_direct_write_permission"("auth"."uid"(), 'document'::"text", "d"."id") OR "public"."has_direct_write_permission"("auth"."uid"(), 'folder'::"text", "d"."id"))))));

CREATE POLICY "Users can update note attachments" ON "public"."note_attachments" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."documents" "d"
  WHERE (("d"."id" = "note_attachments"."document_id") AND (("d"."user_id" = "auth"."uid"()) OR (("d"."workspace_app_id" IS NOT NULL) AND "public"."can_access_workspace_app"("d"."workspace_app_id")) OR "public"."has_direct_write_permission"("auth"."uid"(), 'document'::"text", "d"."id") OR "public"."has_direct_write_permission"("auth"."uid"(), 'folder'::"text", "d"."id"))))));

CREATE POLICY "Users can delete note attachments" ON "public"."note_attachments" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."documents" "d"
  WHERE (("d"."id" = "note_attachments"."document_id") AND (("d"."user_id" = "auth"."uid"()) OR (("d"."workspace_app_id" IS NOT NULL) AND "public"."can_access_workspace_app"("d"."workspace_app_id")) OR "public"."has_direct_write_permission"("auth"."uid"(), 'document'::"text", "d"."id") OR "public"."has_direct_write_permission"("auth"."uid"(), 'folder'::"text", "d"."id"))))));

-- Document versions (sharing-dependent SELECT/INSERT)
CREATE POLICY "Users can view document versions" ON "public"."document_versions" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."documents" "d"
  WHERE (("d"."id" = "document_versions"."document_id") AND (("d"."user_id" = "auth"."uid"()) OR (("d"."workspace_app_id" IS NOT NULL) AND "public"."can_access_workspace_app"("d"."workspace_app_id")) OR "public"."has_direct_permission"("auth"."uid"(), 'document'::"text", "d"."id") OR "public"."has_direct_permission"("auth"."uid"(), 'folder'::"text", "d"."id"))))));

CREATE POLICY "Users can create document versions" ON "public"."document_versions" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."documents" "d"
  WHERE (("d"."id" = "document_versions"."document_id") AND (("d"."user_id" = "auth"."uid"()) OR (("d"."workspace_app_id" IS NOT NULL) AND "public"."can_access_workspace_app"("d"."workspace_app_id")) OR "public"."has_direct_write_permission"("auth"."uid"(), 'document'::"text", "d"."id") OR "public"."has_direct_write_permission"("auth"."uid"(), 'folder'::"text", "d"."id"))))));
