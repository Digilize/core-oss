-- Migration: Email System
-- Creates the emails table, email-related functions (normalize_subject,
-- normalize_email_labels, normalize_labels_canonical, get_email_threads,
-- get_email_threads_unified, get_email_counts_by_account), indexes, RLS
-- policies, trigger, and grants.

-- =============================================================================
-- Functions (must exist before table due to GENERATED columns)
-- =============================================================================

CREATE OR REPLACE FUNCTION "public"."normalize_subject"("subject" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
  BEGIN
      -- Remove common reply/forward prefixes and normalize whitespace
      RETURN TRIM(REGEXP_REPLACE(
          REGEXP_REPLACE(
              COALESCE(subject, ''),
              '^(Re:|Fwd:|RE:|FW:|Fw:)\s*',
              '',
              'gi'
          ),
          '\s+',
          ' ',
          'g'
      ));
  END;
  $$;


COMMENT ON FUNCTION "public"."normalize_subject"("subject" "text") IS 'Normalizes email subjects by removing Re:/Fwd: prefixes for thread grouping';


CREATE OR REPLACE FUNCTION "public"."normalize_email_labels"("provider" "text", "native_labels" "text"[]) RETURNS "text"[]
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
    result TEXT[] := '{}';
    label TEXT;
BEGIN
    IF native_labels IS NULL THEN
        RETURN result;
    END IF;

    FOREACH label IN ARRAY native_labels
    LOOP
        -- Gmail label normalization
        IF provider = 'google' THEN
            CASE UPPER(label)
                WHEN 'INBOX' THEN result := array_append(result, 'inbox');
                WHEN 'SENT' THEN result := array_append(result, 'sent');
                WHEN 'DRAFT' THEN result := array_append(result, 'draft');
                WHEN 'SPAM' THEN result := array_append(result, 'spam');
                WHEN 'TRASH' THEN result := array_append(result, 'trash');
                WHEN 'STARRED' THEN result := array_append(result, 'starred');
                WHEN 'IMPORTANT' THEN result := array_append(result, 'important');
                WHEN 'UNREAD' THEN result := array_append(result, 'unread');
                ELSE NULL; -- Skip unknown/custom labels for now
            END CASE;
        -- Microsoft/Outlook label normalization
        ELSIF provider = 'microsoft' THEN
            CASE label
                WHEN 'Inbox' THEN result := array_append(result, 'inbox');
                WHEN 'SentItems' THEN result := array_append(result, 'sent');
                WHEN 'Drafts' THEN result := array_append(result, 'draft');
                WHEN 'JunkEmail' THEN result := array_append(result, 'spam');
                WHEN 'DeletedItems' THEN result := array_append(result, 'trash');
                WHEN 'Archive' THEN result := array_append(result, 'archive');
                ELSE NULL; -- Skip unknown/custom folders
            END CASE;
        END IF;
    END LOOP;

    -- Remove duplicates and return
    RETURN ARRAY(SELECT DISTINCT unnest(result) ORDER BY 1);
END;
$$;


COMMENT ON FUNCTION "public"."normalize_email_labels"("provider" "text", "native_labels" "text"[]) IS 'DEPRECATED: Use normalize_labels_canonical(labels) instead. This function is kept for backwards compatibility.';


CREATE OR REPLACE FUNCTION "public"."normalize_labels_canonical"("labels" "text"[]) RETURNS "text"[]
    LANGUAGE "plpgsql" IMMUTABLE PARALLEL SAFE
    AS $$
DECLARE
    result TEXT[] := '{}';
    label TEXT;
    normalized TEXT;
BEGIN
    IF labels IS NULL OR array_length(labels, 1) IS NULL THEN
        RETURN result;
    END IF;

    FOREACH label IN ARRAY labels
    LOOP
        -- Map to canonical lowercase names
        -- Handles Gmail (uppercase), Outlook (mixed case), and IMAP labels
        normalized := CASE UPPER(COALESCE(label, ''))
            -- === SYSTEM LABELS (Inbox, Sent, Draft, etc.) ===
            WHEN 'INBOX' THEN 'inbox'

            -- Sent variants
            WHEN 'SENT' THEN 'sent'
            WHEN 'SENTITEMS' THEN 'sent'          -- Outlook
            WHEN 'SENT ITEMS' THEN 'sent'         -- Outlook display name
            WHEN 'SENT MESSAGES' THEN 'sent'      -- Apple Mail

            -- Draft variants
            WHEN 'DRAFT' THEN 'draft'
            WHEN 'DRAFTS' THEN 'draft'            -- Outlook/IMAP

            -- Spam variants
            WHEN 'SPAM' THEN 'spam'
            WHEN 'JUNKEMAIL' THEN 'spam'          -- Outlook
            WHEN 'JUNK EMAIL' THEN 'spam'         -- Outlook display name
            WHEN 'JUNK' THEN 'spam'               -- IMAP

            -- Trash variants
            WHEN 'TRASH' THEN 'trash'
            WHEN 'DELETEDITEMS' THEN 'trash'      -- Outlook
            WHEN 'DELETED ITEMS' THEN 'trash'     -- Outlook display name

            -- Archive variants
            WHEN 'ARCHIVE' THEN 'archive'
            WHEN 'ALL MAIL' THEN 'archive'        -- Gmail's archive

            -- === STATUS LABELS (Read, Starred, Important) ===
            WHEN 'UNREAD' THEN 'unread'

            -- Starred variants
            WHEN 'STARRED' THEN 'starred'
            WHEN 'FLAGGED' THEN 'starred'         -- Outlook/IMAP

            WHEN 'IMPORTANT' THEN 'important'

            -- === GMAIL CATEGORIES ===
            WHEN 'CATEGORY_PERSONAL' THEN 'personal'
            WHEN 'CATEGORY_SOCIAL' THEN 'social'
            WHEN 'CATEGORY_PROMOTIONS' THEN 'promotions'
            WHEN 'CATEGORY_UPDATES' THEN 'updates'
            WHEN 'CATEGORY_FORUMS' THEN 'forums'

            -- === OUTLOOK FOLDERS (well-known folder IDs) ===
            -- These are Outlook folder IDs that might appear in labels
            WHEN 'OUTBOX' THEN 'outbox'
            WHEN 'CLUTTER' THEN 'clutter'

            -- === SKIP INTERNAL LABELS ===
            -- Gmail internal labels we don't want to expose
            WHEN 'CATEGORY_PRIMARY' THEN NULL     -- Skip (redundant with inbox)
            WHEN 'CHAT' THEN NULL                 -- Skip chat messages
            WHEN 'OPENED' THEN NULL               -- Skip tracking labels

            -- === DEFAULT: Keep as lowercase ===
            -- Custom labels (user folders, Outlook categories) pass through
            ELSE LOWER(label)
        END;

        -- Only add non-null, non-empty normalized labels
        IF normalized IS NOT NULL AND normalized != '' THEN
            result := array_append(result, normalized);
        END IF;
    END LOOP;

    -- Remove duplicates and sort for consistency
    RETURN ARRAY(SELECT DISTINCT unnest(result) ORDER BY 1);
END;
$$;


COMMENT ON FUNCTION "public"."normalize_labels_canonical"("labels" "text"[]) IS 'Converts any provider labels to canonical format (inbox, sent, draft, spam, trash, unread, starred, important, archive). Provider-agnostic - works with Gmail, Outlook, and IMAP labels.';


-- =============================================================================
-- Table: emails
-- =============================================================================

CREATE TABLE IF NOT EXISTS "public"."emails" (
    "id" "uuid" DEFAULT "public"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "ext_connection_id" "uuid",
    "external_id" "text" NOT NULL,
    "thread_id" "text",
    "subject" "text",
    "from" "text",
    "to" "text"[],
    "cc" "text"[],
    "bcc" "text"[],
    "body" "text",
    "snippet" "text",
    "labels" "text"[],
    "is_read" boolean DEFAULT false,
    "is_draft" boolean DEFAULT false,
    "is_trashed" boolean DEFAULT false,
    "is_starred" boolean DEFAULT false,
    "received_at" timestamp with time zone,
    "sent_at" timestamp with time zone,
    "has_attachments" boolean DEFAULT false,
    "attachments" "jsonb" DEFAULT '[]'::"jsonb",
    "synced_at" timestamp with time zone,
    "raw_item" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ai_analyzed" boolean DEFAULT false,
    "ai_summary" "text",
    "ai_important" boolean,
    "provider_ids" "jsonb" DEFAULT '{}'::"jsonb",
    "normalized_labels" "text"[] GENERATED ALWAYS AS ("public"."normalize_labels_canonical"("labels")) STORED,
    "search_vector" "tsvector" GENERATED ALWAYS AS (((("setweight"("to_tsvector"('"english"'::"regconfig", COALESCE("subject", ''::"text")), 'A'::"char") || "setweight"("to_tsvector"('"english"'::"regconfig", COALESCE("from", ''::"text")), 'B'::"char")) || "setweight"("to_tsvector"('"english"'::"regconfig", COALESCE("snippet", ''::"text")), 'C'::"char")) || "setweight"("to_tsvector"('"english"'::"regconfig", COALESCE("left"("body", 5000), ''::"text")), 'D'::"char"))) STORED,
    "gmail_draft_id" "text",
    "embedding" "public"."vector"(1536),
    "composite_thread_id" "text" GENERATED ALWAYS AS ((("thread_id" || '|||'::"text") || "public"."normalize_subject"(COALESCE("subject", '(No Subject)'::"text")))) STORED
);


COMMENT ON COLUMN "public"."emails"."ai_analyzed" IS 'Whether AI analysis has been performed';
COMMENT ON COLUMN "public"."emails"."ai_summary" IS 'AI-generated summary of the email';
COMMENT ON COLUMN "public"."emails"."ai_important" IS 'AI-determined importance flag';
COMMENT ON COLUMN "public"."emails"."provider_ids" IS 'Provider-specific identifiers for sync-back. Gmail: {"label_ids": [...]}. Outlook: {"folder_id": "...", "folder_name": "...", "category_ids": [...]}';
COMMENT ON COLUMN "public"."emails"."normalized_labels" IS 'Auto-computed canonical labels from labels column. Values: inbox, sent, draft, spam, trash, unread, starred, important, archive, plus custom labels as lowercase. Updated automatically via generated column.';
COMMENT ON COLUMN "public"."emails"."composite_thread_id" IS 'Materialized thread grouping key: thread_id || "|||" || normalized subject. Used by threaded inbox and unread counts.';

-- =============================================================================
-- Query Functions
-- =============================================================================

CREATE OR REPLACE FUNCTION "public"."get_email_counts_by_account"("p_user_id" "uuid", "p_account_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS TABLE("account_id" "uuid", "provider_email" "text", "provider" "text", "inbox_unread_count" bigint, "drafts_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    WITH email_counts AS (
        SELECT
            e.ext_connection_id AS account_id,
            COUNT(DISTINCT CASE
                WHEN 'inbox' = ANY(e.normalized_labels)
                 AND e.is_read = false
                THEN e.composite_thread_id
            END)::bigint AS inbox_unread_count,
            COUNT(*) FILTER (
                WHERE 'draft' = ANY(e.normalized_labels)
            )::bigint AS drafts_count
        FROM emails e
        WHERE e.user_id = p_user_id
          AND e.is_trashed = false
          AND (p_account_ids IS NULL OR e.ext_connection_id = ANY(p_account_ids))
        GROUP BY e.ext_connection_id
    )
    SELECT
        ec.id AS account_id,
        ec.provider_email,
        ec.provider,
        COALESCE(c.inbox_unread_count, 0)::bigint AS inbox_unread_count,
        COALESCE(c.drafts_count, 0)::bigint AS drafts_count
    FROM ext_connections ec
    LEFT JOIN email_counts c ON c.account_id = ec.id
    WHERE ec.user_id = p_user_id
      AND ec.is_active = true
      AND (p_account_ids IS NULL OR ec.id = ANY(p_account_ids))
    ORDER BY ec.account_order;
END;
$$;


COMMENT ON FUNCTION "public"."get_email_counts_by_account"("p_user_id" "uuid", "p_account_ids" "uuid"[]) IS 'Returns inbox unread thread count and drafts count for active accounts, using materialized composite_thread_id for efficient thread-level unread counting.';


CREATE OR REPLACE FUNCTION "public"."get_email_threads"("p_user_id" "uuid", "p_max_results" integer DEFAULT 50, "p_label_filter" "text" DEFAULT NULL::"text", "p_offset" integer DEFAULT 0, "p_ext_connection_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("thread_id" "text", "latest_external_id" "text", "subject" "text", "sender" "text", "snippet" "text", "labels" "text"[], "is_unread" boolean, "is_starred" boolean, "received_at" timestamp with time zone, "has_attachments" boolean, "message_count" bigint, "participant_count" bigint, "ai_summary" "text", "ai_important" boolean, "ai_analyzed" boolean, "ext_connection_id" "uuid")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    WITH normalized_emails AS (
        SELECT
            e.*,
            normalize_subject(COALESCE(e.subject, '')) as norm_subject,
            e.thread_id || '|||' || normalize_subject(COALESCE(e.subject, '(No Subject)')) as composite_thread_id
        FROM emails e
        WHERE e.user_id = p_user_id
          AND e.is_trashed = false
          AND (p_label_filter IS NULL OR p_label_filter = ANY(e.labels))
          AND (p_ext_connection_id IS NULL OR e.ext_connection_id = p_ext_connection_id)
    ),
    -- Get ALL emails for these threads (regardless of label filter) to check user engagement
    all_thread_emails AS (
        SELECT DISTINCT
            ne.composite_thread_id,
            'SENT' = ANY(ae.labels) as is_sent_email
        FROM normalized_emails ne
        JOIN emails ae ON ae.thread_id = ne.thread_id
                       AND ae.user_id = p_user_id
                       AND ae.is_trashed = false
    ),
    -- Check if user has engaged in each thread
    thread_engagement AS (
        SELECT
            composite_thread_id,
            BOOL_OR(is_sent_email) as user_has_engaged
        FROM all_thread_emails
        GROUP BY composite_thread_id
    ),
    thread_aggregates AS (
        SELECT
            e.composite_thread_id,
            e.thread_id as original_thread_id,
            COUNT(DISTINCT e.id) as msg_count,
            MAX(e.received_at) as latest_date,
            BOOL_OR(NOT e.is_read) as has_unread,
            BOOL_OR(e.is_starred) as has_starred,
            BOOL_OR(e.has_attachments) as has_attach,
            COUNT(DISTINCT e.from) as unique_senders,
            ARRAY_AGG(DISTINCT label ORDER BY label) FILTER (WHERE label IS NOT NULL) as all_labels,
            -- Get the ext_connection_id (all emails in a thread should have the same one)
            (array_agg(e.ext_connection_id))[1] as thread_ext_connection_id
        FROM normalized_emails e
        LEFT JOIN LATERAL unnest(e.labels) as label ON true
        GROUP BY e.composite_thread_id, e.thread_id
    ),
    latest_in_thread AS (
        SELECT DISTINCT ON (e.composite_thread_id)
            e.composite_thread_id,
            e.thread_id,
            e.external_id,
            e.subject,
            e.from as sender,
            e.snippet,
            e.received_at,
            e.ai_summary,
            e.ai_important,
            e.ai_analyzed
        FROM normalized_emails e
        ORDER BY e.composite_thread_id, e.received_at DESC
    )
    SELECT
        t.original_thread_id as thread_id,
        l.external_id as latest_external_id,
        l.subject,
        l.sender,
        l.snippet,
        t.all_labels as labels,
        t.has_unread as is_unread,
        t.has_starred as is_starred,
        l.received_at,
        t.has_attach as has_attachments,
        t.msg_count as message_count,
        t.unique_senders as participant_count,
        l.ai_summary,
        -- HARD RULE: If user has engaged (sent/replied) in this thread, always mark as important
        CASE
            WHEN COALESCE(te.user_has_engaged, false) THEN true
            ELSE COALESCE(l.ai_important, false)
        END as ai_important,
        l.ai_analyzed,
        t.thread_ext_connection_id as ext_connection_id
    FROM thread_aggregates t
    JOIN latest_in_thread l ON l.composite_thread_id = t.composite_thread_id
    LEFT JOIN thread_engagement te ON te.composite_thread_id = t.composite_thread_id
    ORDER BY l.received_at DESC
    LIMIT p_max_results
    OFFSET p_offset;
END;
$$;


COMMENT ON FUNCTION "public"."get_email_threads"("p_user_id" "uuid", "p_max_results" integer, "p_label_filter" "text", "p_offset" integer, "p_ext_connection_id" "uuid") IS 'Returns email threads with aggregated metadata, pagination, and multi-account filtering support. Threads where the user has engaged (sent/replied) are automatically marked as important.';


CREATE OR REPLACE FUNCTION "public"."get_email_threads_unified"("p_user_id" "uuid", "p_max_results" integer DEFAULT 50, "p_label_filter" "text" DEFAULT NULL::"text", "p_offset" integer DEFAULT 0, "p_ext_connection_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS TABLE("thread_id" "text", "latest_external_id" "text", "subject" "text", "sender" "text", "snippet" "text", "labels" "text"[], "normalized_labels" "text"[], "is_unread" boolean, "is_starred" boolean, "received_at" timestamp with time zone, "has_attachments" boolean, "message_count" bigint, "participant_count" bigint, "ai_summary" "text", "ai_important" boolean, "ai_analyzed" boolean, "ext_connection_id" "uuid", "account_email" "text", "account_provider" "text", "account_avatar" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    WITH filtered_emails AS (
        SELECT
            e.id, e.composite_thread_id, e.thread_id, e.external_id,
            e.subject, e.from, e.snippet, e.received_at,
            e.is_read, e.is_starred, e.has_attachments,
            e.labels, e.normalized_labels, e.ext_connection_id,
            e.ai_summary, e.ai_important, e.ai_analyzed
        FROM emails e
        WHERE e.user_id = p_user_id
          AND (
              (p_label_filter = 'trash' AND e.is_trashed = true)
              OR (p_label_filter IS DISTINCT FROM 'trash' AND e.is_trashed = false)
          )
          AND (p_label_filter IS NULL OR p_label_filter = ANY(e.normalized_labels))
          AND (p_ext_connection_ids IS NULL OR e.ext_connection_id = ANY(p_ext_connection_ids))
    ),
    thread_engagement AS (
        SELECT
            fe.composite_thread_id,
            BOOL_OR('sent' = ANY(COALESCE(ae.normalized_labels, '{}'))) AS user_has_engaged
        FROM (SELECT DISTINCT f.composite_thread_id, f.thread_id FROM filtered_emails f) fe
        JOIN emails ae ON ae.thread_id = fe.thread_id
                       AND ae.user_id = p_user_id
                       AND (
                           (p_label_filter = 'trash' AND ae.is_trashed = true)
                           OR (p_label_filter IS DISTINCT FROM 'trash' AND ae.is_trashed = false)
                       )
        GROUP BY fe.composite_thread_id
    ),
    thread_aggregates AS (
        SELECT
            e.composite_thread_id,
            e.thread_id AS original_thread_id,
            COUNT(*)::bigint AS msg_count,
            MAX(e.received_at) AS latest_date,
            BOOL_OR(NOT e.is_read) AS has_unread,
            BOOL_OR(e.is_starred) AS has_starred,
            BOOL_OR(e.has_attachments) AS has_attach,
            COUNT(DISTINCT e.from)::bigint AS unique_senders,
            (array_agg(e.ext_connection_id ORDER BY e.received_at DESC NULLS LAST))[1] AS thread_ext_connection_id
        FROM filtered_emails e
        GROUP BY e.composite_thread_id, e.thread_id
    ),
    thread_labels AS (
        SELECT
            e.composite_thread_id,
            e.thread_id AS original_thread_id,
            ARRAY_AGG(DISTINCT label ORDER BY label) FILTER (WHERE label IS NOT NULL) AS all_labels
        FROM filtered_emails e
        LEFT JOIN LATERAL unnest(e.labels) AS label ON true
        GROUP BY e.composite_thread_id, e.thread_id
    ),
    thread_normalized_labels AS (
        SELECT
            e.composite_thread_id,
            e.thread_id AS original_thread_id,
            ARRAY_AGG(DISTINCT nlabel ORDER BY nlabel) FILTER (WHERE nlabel IS NOT NULL) AS all_normalized_labels
        FROM filtered_emails e
        LEFT JOIN LATERAL unnest(COALESCE(e.normalized_labels, '{}')) AS nlabel ON true
        GROUP BY e.composite_thread_id, e.thread_id
    ),
    latest_in_thread AS (
        SELECT DISTINCT ON (e.composite_thread_id)
            e.composite_thread_id,
            e.thread_id,
            e.external_id,
            e.subject,
            e.from AS sender,
            e.snippet,
            e.received_at,
            e.ai_summary,
            e.ai_important,
            e.ai_analyzed
        FROM filtered_emails e
        ORDER BY e.composite_thread_id, e.received_at DESC
    )
    SELECT
        t.original_thread_id AS thread_id,
        l.external_id AS latest_external_id,
        l.subject,
        l.sender,
        l.snippet,
        tl.all_labels AS labels,
        tnl.all_normalized_labels AS normalized_labels,
        t.has_unread AS is_unread,
        t.has_starred AS is_starred,
        l.received_at,
        t.has_attach AS has_attachments,
        t.msg_count AS message_count,
        t.unique_senders AS participant_count,
        l.ai_summary,
        CASE
            WHEN COALESCE(te.user_has_engaged, false) THEN true
            ELSE COALESCE(l.ai_important, false)
        END AS ai_important,
        l.ai_analyzed,
        t.thread_ext_connection_id AS ext_connection_id,
        ec.provider_email AS account_email,
        ec.provider AS account_provider,
        ec.metadata->>'picture' AS account_avatar
    FROM thread_aggregates t
    JOIN latest_in_thread l ON l.composite_thread_id = t.composite_thread_id
    LEFT JOIN thread_engagement te ON te.composite_thread_id = t.composite_thread_id
    LEFT JOIN thread_labels tl
        ON tl.composite_thread_id = t.composite_thread_id
       AND tl.original_thread_id = t.original_thread_id
    LEFT JOIN thread_normalized_labels tnl
        ON tnl.composite_thread_id = t.composite_thread_id
       AND tnl.original_thread_id = t.original_thread_id
    LEFT JOIN ext_connections ec ON ec.id = t.thread_ext_connection_id
    ORDER BY l.received_at DESC
    LIMIT p_max_results
    OFFSET p_offset;
END;
$$;


COMMENT ON FUNCTION "public"."get_email_threads_unified"("p_user_id" "uuid", "p_max_results" integer, "p_label_filter" "text", "p_offset" integer, "p_ext_connection_ids" "uuid"[]) IS 'Returns email threads for unified multi-account view. Optimized to use materialized composite_thread_id and single-pass engagement aggregation.';

-- =============================================================================
-- Primary Key and Unique Constraints
-- =============================================================================

ALTER TABLE ONLY "public"."emails"
    ADD CONSTRAINT "emails_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."emails"
    ADD CONSTRAINT "emails_user_id_external_id_key" UNIQUE ("user_id", "external_id");

-- =============================================================================
-- Foreign Keys
-- =============================================================================

ALTER TABLE ONLY "public"."emails"
    ADD CONSTRAINT "emails_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."emails"
    ADD CONSTRAINT "emails_ext_connection_id_fkey" FOREIGN KEY ("ext_connection_id") REFERENCES "public"."ext_connections"("id") ON DELETE CASCADE;

-- =============================================================================
-- Indexes
-- =============================================================================

CREATE INDEX "idx_emails_ai_analyzed" ON "public"."emails" USING "btree" ("ai_analyzed") WHERE ("ai_analyzed" = false);
CREATE INDEX "idx_emails_ai_important" ON "public"."emails" USING "btree" ("ai_important") WHERE ("ai_important" IS NOT NULL);
CREATE INDEX "idx_emails_embedding" ON "public"."emails" USING "hnsw" ("embedding" "public"."vector_cosine_ops") WITH ("m"='16', "ef_construction"='64');
CREATE INDEX "idx_emails_ext_connection_id" ON "public"."emails" USING "btree" ("ext_connection_id");
CREATE INDEX "idx_emails_external_id" ON "public"."emails" USING "btree" ("external_id");
CREATE INDEX "idx_emails_is_draft" ON "public"."emails" USING "btree" ("is_draft");
CREATE INDEX "idx_emails_is_read" ON "public"."emails" USING "btree" ("is_read");
CREATE INDEX "idx_emails_is_trashed" ON "public"."emails" USING "btree" ("is_trashed");
CREATE INDEX "idx_emails_labels" ON "public"."emails" USING "gin" ("labels");
CREATE INDEX "idx_emails_normalized_labels" ON "public"."emails" USING "gin" ("normalized_labels");
CREATE INDEX "idx_emails_provider_ids" ON "public"."emails" USING "gin" ("provider_ids");
CREATE INDEX "idx_emails_received_at" ON "public"."emails" USING "btree" ("received_at" DESC);
CREATE INDEX "idx_emails_search" ON "public"."emails" USING "gin" ("search_vector");
CREATE INDEX "idx_emails_thread_id" ON "public"."emails" USING "btree" ("thread_id");
CREATE INDEX "idx_emails_thread_received" ON "public"."emails" USING "btree" ("thread_id", "received_at" DESC);
CREATE INDEX "idx_emails_user_gmail_draft_id" ON "public"."emails" USING "btree" ("user_id", "gmail_draft_id") WHERE ("gmail_draft_id" IS NOT NULL);
CREATE INDEX "idx_emails_user_id" ON "public"."emails" USING "btree" ("user_id");
CREATE INDEX "idx_emails_user_thread" ON "public"."emails" USING "btree" ("user_id", "thread_id");
CREATE INDEX "idx_emails_user_trashed_composite_received" ON "public"."emails" USING "btree" ("user_id", "is_trashed", "composite_thread_id", "received_at" DESC);
CREATE INDEX "idx_emails_user_trashed_ext_connection" ON "public"."emails" USING "btree" ("user_id", "is_trashed", "ext_connection_id");

-- =============================================================================
-- Row Level Security
-- =============================================================================

ALTER TABLE "public"."emails" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own emails" ON "public"."emails" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));
CREATE POLICY "Users can insert own emails" ON "public"."emails" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));
CREATE POLICY "Users can update own emails" ON "public"."emails" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));
CREATE POLICY "Users can delete own emails" ON "public"."emails" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));

-- =============================================================================
-- Trigger
-- =============================================================================

CREATE OR REPLACE TRIGGER "update_emails_updated_at" BEFORE UPDATE ON "public"."emails" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();

-- =============================================================================
-- Grants
-- =============================================================================







