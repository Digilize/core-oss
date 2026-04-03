-- Migration: Files and Documents
-- Creates the files, documents, note_attachments, and document_versions tables,
-- related functions (confirm_file_upload, reorder_documents,
-- insert_document_version_snapshot, update_documents_updated_at,
-- update_files_updated_at), indexes, RLS policies, triggers, and grants.

-- =============================================================================
-- Functions
-- =============================================================================

CREATE OR REPLACE FUNCTION "public"."update_documents_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;



CREATE OR REPLACE FUNCTION "public"."update_files_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;



CREATE OR REPLACE FUNCTION "public"."confirm_file_upload"("p_file_id" "uuid", "p_create_document" boolean DEFAULT false, "p_parent_id" "uuid" DEFAULT NULL::"uuid", "p_tags" "text"[] DEFAULT '{}'::"text"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_file RECORD;
  v_document RECORD;
  v_result JSONB;
BEGIN
  -- Update file status and return the row in one step.
  -- WHERE enforces ownership via auth.uid() — no separate fetch needed.
  UPDATE public.files
  SET status = 'uploaded'
  WHERE id = p_file_id
    AND user_id = auth.uid()
    AND status = 'uploading'
  RETURNING * INTO v_file;

  IF v_file IS NULL THEN
    -- Disambiguate: does the file exist at all?
    PERFORM 1 FROM public.files
    WHERE id = p_file_id AND user_id = auth.uid();

    IF NOT FOUND THEN
      RAISE EXCEPTION 'File not found';
    ELSE
      RAISE EXCEPTION 'File already confirmed';
    END IF;
  END IF;

  v_result := jsonb_build_object(
    'file', to_jsonb(v_file)
  );

  -- Optionally create a document entry for the file
  IF p_create_document THEN
    IF v_file.workspace_app_id IS NULL OR v_file.workspace_id IS NULL THEN
      RAISE EXCEPTION 'Workspace context required to create document';
    END IF;

    -- Verify caller has access to the workspace app (mirrors RLS INSERT policy)
    IF NOT public.can_access_workspace_app(v_file.workspace_app_id, auth.uid()) THEN
      RAISE EXCEPTION 'Access denied to workspace app';
    END IF;

    INSERT INTO public.documents (
      user_id,
      workspace_app_id,
      workspace_id,
      title,
      type,
      file_id,
      parent_id,
      content,
      tags
    ) VALUES (
      auth.uid(),
      v_file.workspace_app_id,
      v_file.workspace_id,
      v_file.filename,
      'file',
      p_file_id,
      p_parent_id,
      '',
      p_tags
    )
    RETURNING * INTO v_document;

    v_result := v_result || jsonb_build_object(
      'document', to_jsonb(v_document)
    );
  END IF;

  RETURN v_result;
END;
$$;



CREATE OR REPLACE FUNCTION "public"."reorder_documents"("p_document_positions" "jsonb") RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_item JSONB;
    v_updated_count INT := 0;
BEGIN
    -- Validate user is authenticated
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Loop through each position update
    -- RLS handles authorization (owner or workspace member)
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_document_positions)
    LOOP
        UPDATE documents
        SET position = (v_item->>'position')::INT
        WHERE id = (v_item->>'id')::UUID;

        IF FOUND THEN
            v_updated_count := v_updated_count + 1;
        END IF;
    END LOOP;

    RETURN v_updated_count;
END;
$$;



CREATE OR REPLACE FUNCTION "public"."insert_document_version_snapshot"("p_document_id" "uuid", "p_title" "text", "p_content" "text", "p_created_by" "uuid", "p_force" boolean DEFAULT false, "p_min_interval_minutes" integer DEFAULT 10) RETURNS TABLE("id" "uuid", "version_number" integer)
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_next_version INTEGER;
    v_latest_created TIMESTAMPTZ;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Serialize version allocation per document to prevent concurrent collisions.
    PERFORM pg_advisory_xact_lock(hashtext(p_document_id::TEXT));

    -- Unless forced, check the minimum interval since the last snapshot.
    IF NOT p_force THEN
        SELECT dv.created_at
          INTO v_latest_created
          FROM document_versions dv
         WHERE dv.document_id = p_document_id
         ORDER BY dv.version_number DESC
         LIMIT 1;

        IF v_latest_created IS NOT NULL
           AND (now() - v_latest_created) < make_interval(mins := p_min_interval_minutes) THEN
            -- Interval not met — return empty result set (no row inserted).
            RETURN;
        END IF;
    END IF;

    SELECT COALESCE(MAX(dv.version_number), 0) + 1
      INTO v_next_version
      FROM document_versions dv
     WHERE dv.document_id = p_document_id;

    INSERT INTO document_versions (
        document_id,
        title,
        content,
        version_number,
        created_by
    )
    VALUES (
        p_document_id,
        p_title,
        p_content,
        v_next_version,
        p_created_by
    )
    RETURNING document_versions.id, document_versions.version_number
      INTO id, version_number;

    RETURN NEXT;
END;
$$;


-- =============================================================================
-- Table: files
-- =============================================================================

CREATE TABLE IF NOT EXISTS "public"."files" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "filename" "text" NOT NULL,
    "file_type" "text" NOT NULL,
    "file_size" bigint NOT NULL,
    "r2_key" "text" NOT NULL,
    "uploaded_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "status" "text" DEFAULT 'uploaded'::"text" NOT NULL,
    "workspace_app_id" "uuid",
    "workspace_id" "uuid" NOT NULL
);


-- =============================================================================
-- Table: documents
-- =============================================================================

CREATE TABLE IF NOT EXISTS "public"."documents" (
    "id" "uuid" DEFAULT "public"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" DEFAULT 'Untitled'::"text" NOT NULL,
    "content" "text" DEFAULT ''::"text",
    "icon" "text",
    "cover_image" "text",
    "parent_id" "uuid",
    "is_archived" boolean DEFAULT false,
    "is_favorite" boolean DEFAULT false,
    "position" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_folder" boolean DEFAULT false,
    "last_opened_at" timestamp with time zone,
    "file_id" "uuid",
    "search_vector" "tsvector" GENERATED ALWAYS AS (("setweight"("to_tsvector"('"english"'::"regconfig", COALESCE("title", ''::"text")), 'A'::"char") || "setweight"("to_tsvector"('"english"'::"regconfig", COALESCE("left"("content", 10000), ''::"text")), 'B'::"char"))) STORED,
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "type" "text" DEFAULT 'note'::"text",
    "workspace_app_id" "uuid" NOT NULL,
    "workspace_id" "uuid" NOT NULL,
    "embedding" "public"."vector"(1536),
    CONSTRAINT "documents_type_check" CHECK (("type" = ANY (ARRAY['folder'::"text", 'note'::"text", 'file'::"text"])))
);

ALTER TABLE ONLY "public"."documents" REPLICA IDENTITY FULL;


COMMENT ON TABLE "public"."documents" IS 'Stores user documents with Notion-style hierarchical structure and markdown content';
COMMENT ON COLUMN "public"."documents"."is_folder" IS 'True if this is a folder, false if it is a document';
COMMENT ON COLUMN "public"."documents"."last_opened_at" IS 'Timestamp of when document was last opened for quick access/recents';
COMMENT ON COLUMN "public"."documents"."tags" IS 'Array of tag strings for categorization and filtering';

-- =============================================================================
-- Table: note_attachments
-- =============================================================================

CREATE TABLE IF NOT EXISTS "public"."note_attachments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "document_id" "uuid" NOT NULL,
    "file_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "position" integer DEFAULT 0,
    "inline_position" integer,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "note_attachments_type_check" CHECK (("type" = ANY (ARRAY['image'::"text", 'video'::"text", 'file'::"text"])))
);


-- =============================================================================
-- Table: document_versions
-- =============================================================================

CREATE TABLE IF NOT EXISTS "public"."document_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "document_id" "uuid" NOT NULL,
    "title" "text",
    "content" "text",
    "version_number" integer DEFAULT 1 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


-- =============================================================================
-- Primary Keys and Unique Constraints
-- =============================================================================

ALTER TABLE ONLY "public"."files"
    ADD CONSTRAINT "files_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."files"
    ADD CONSTRAINT "files_r2_key_key" UNIQUE ("r2_key");

ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."note_attachments"
    ADD CONSTRAINT "note_attachments_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."document_versions"
    ADD CONSTRAINT "document_versions_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."document_versions"
    ADD CONSTRAINT "uq_document_versions_doc_version" UNIQUE ("document_id", "version_number");

-- =============================================================================
-- Foreign Keys
-- =============================================================================

ALTER TABLE ONLY "public"."files"
    ADD CONSTRAINT "files_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."files"
    ADD CONSTRAINT "files_workspace_app_id_fkey" FOREIGN KEY ("workspace_app_id") REFERENCES "public"."workspace_apps"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."files"
    ADD CONSTRAINT "files_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_file_id_fkey" FOREIGN KEY ("file_id") REFERENCES "public"."files"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."documents"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_workspace_app_id_fkey" FOREIGN KEY ("workspace_app_id") REFERENCES "public"."workspace_apps"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_workspace_id_fkey" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."note_attachments"
    ADD CONSTRAINT "note_attachments_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."note_attachments"
    ADD CONSTRAINT "note_attachments_file_id_fkey" FOREIGN KEY ("file_id") REFERENCES "public"."files"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."document_versions"
    ADD CONSTRAINT "document_versions_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."document_versions"
    ADD CONSTRAINT "document_versions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;

-- =============================================================================
-- Indexes
-- =============================================================================

-- Files indexes
CREATE INDEX "idx_files_file_type" ON "public"."files" USING "btree" ("file_type");
CREATE INDEX "idx_files_r2_key" ON "public"."files" USING "btree" ("r2_key");
CREATE INDEX "idx_files_uploaded_at" ON "public"."files" USING "btree" ("uploaded_at" DESC);
CREATE INDEX "idx_files_user_id" ON "public"."files" USING "btree" ("user_id");
CREATE INDEX "idx_files_workspace_app_id" ON "public"."files" USING "btree" ("workspace_app_id");
CREATE INDEX "idx_files_workspace_id" ON "public"."files" USING "btree" ("workspace_id");

-- Documents indexes
CREATE INDEX "idx_documents_archived" ON "public"."documents" USING "btree" ("is_archived") WHERE ("is_archived" = false);
CREATE INDEX "idx_documents_embedding" ON "public"."documents" USING "hnsw" ("embedding" "public"."vector_cosine_ops") WITH ("m"='16', "ef_construction"='64');
CREATE INDEX "idx_documents_favorite" ON "public"."documents" USING "btree" ("is_favorite") WHERE ("is_favorite" = true);
CREATE INDEX "idx_documents_file_id" ON "public"."documents" USING "btree" ("file_id");
CREATE INDEX "idx_documents_is_folder" ON "public"."documents" USING "btree" ("user_id", "is_folder") WHERE ("is_folder" = true);
CREATE INDEX "idx_documents_last_opened" ON "public"."documents" USING "btree" ("user_id", "last_opened_at" DESC NULLS LAST);
CREATE INDEX "idx_documents_parent_id" ON "public"."documents" USING "btree" ("parent_id");
CREATE INDEX "idx_documents_search" ON "public"."documents" USING "gin" ("search_vector");
CREATE INDEX "idx_documents_tags" ON "public"."documents" USING "gin" ("tags");
CREATE INDEX "idx_documents_type" ON "public"."documents" USING "btree" ("type");
CREATE INDEX "idx_documents_updated_at" ON "public"."documents" USING "btree" ("user_id", "updated_at" DESC);
CREATE INDEX "idx_documents_user_id" ON "public"."documents" USING "btree" ("user_id");
CREATE INDEX "idx_documents_user_parent" ON "public"."documents" USING "btree" ("user_id", "parent_id");
CREATE INDEX "idx_documents_workspace_app_id" ON "public"."documents" USING "btree" ("workspace_app_id");
CREATE INDEX "idx_documents_workspace_id" ON "public"."documents" USING "btree" ("workspace_id");

-- Note attachments indexes
CREATE INDEX "idx_note_attachments_document" ON "public"."note_attachments" USING "btree" ("document_id");
CREATE INDEX "idx_note_attachments_file" ON "public"."note_attachments" USING "btree" ("file_id");

-- Document versions indexes
CREATE INDEX "idx_document_versions_doc_version_desc" ON "public"."document_versions" USING "btree" ("document_id", "version_number" DESC);
CREATE INDEX "idx_document_versions_document_id_created" ON "public"."document_versions" USING "btree" ("document_id", "created_at" DESC);

-- =============================================================================
-- Row Level Security
-- =============================================================================

ALTER TABLE "public"."files" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."documents" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."note_attachments" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."document_versions" ENABLE ROW LEVEL SECURITY;

-- Files policies (non-sharing only; sharing-dependent policies in 00014_sharing_permissions.sql)
CREATE POLICY "Users can upload files in accessible workspaces" ON "public"."files" FOR INSERT WITH CHECK ((("auth"."uid"() = "user_id") AND (("workspace_app_id" IS NULL) OR "public"."can_access_workspace_app"("workspace_app_id"))));

CREATE POLICY "Owner or admin can delete files" ON "public"."files" FOR DELETE USING ((("auth"."uid"() = "user_id") OR (("workspace_id" IS NOT NULL) AND "public"."is_workspace_admin"("workspace_id"))));

-- Documents policies (non-sharing only; sharing-dependent policies in 00014_sharing_permissions.sql)
CREATE POLICY "Users can create documents in accessible workspaces" ON "public"."documents" FOR INSERT WITH CHECK ((("auth"."uid"() = "user_id") AND (("workspace_app_id" IS NULL) OR "public"."can_access_workspace_app"("workspace_app_id"))));

CREATE POLICY "Owner or admin can delete documents" ON "public"."documents" FOR DELETE USING ((("auth"."uid"() = "user_id") OR (("workspace_id" IS NOT NULL) AND "public"."is_workspace_admin"("workspace_id"))));

-- Note attachments and document versions policies are all sharing-dependent
-- and are created in 00014_sharing_permissions.sql

-- Document versions delete (non-sharing)
CREATE POLICY "Users can delete document versions" ON "public"."document_versions" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."documents" "d"
  WHERE (("d"."id" = "document_versions"."document_id") AND (("d"."user_id" = "auth"."uid"()) OR "public"."is_workspace_admin"("d"."workspace_id"))))));

-- =============================================================================
-- Triggers
-- =============================================================================

CREATE OR REPLACE TRIGGER "documents_updated_at_trigger" BEFORE UPDATE ON "public"."documents" FOR EACH ROW EXECUTE FUNCTION "public"."update_documents_updated_at"();
CREATE OR REPLACE TRIGGER "files_updated_at_trigger" BEFORE UPDATE ON "public"."files" FOR EACH ROW EXECUTE FUNCTION "public"."update_files_updated_at"();

-- =============================================================================
-- Grants
-- =============================================================================









