"""Message management service for workspace messaging."""

from typing import Dict, Any, List, Optional, Tuple
import json
import logging
import asyncpg

from lib.db import get_admin_db_conn
from lib.r2_client import get_r2_client
from lib.image_proxy import generate_file_url, is_image_type
from api.config import settings

logger = logging.getLogger(__name__)


def extract_plain_text(blocks: List[Dict[str, Any]]) -> str:
    """
    Extract plain text content from blocks for search indexing.

    Args:
        blocks: Array of content blocks

    Returns:
        Plain text string
    """
    text_parts = []

    for block in blocks:
        block_type = block.get("type")
        data = block.get("data", {})

        if block_type == "text":
            text_parts.append(data.get("content", ""))
        elif block_type == "mention":
            text_parts.append(f"@{data.get('display_name', '')}")
        elif block_type == "code":
            text_parts.append(data.get("content", ""))
        elif block_type == "quote":
            text_parts.append(data.get("preview", ""))
        elif block_type == "shared_message":
            text_parts.append(data.get("original_content", ""))

    return " ".join(text_parts).strip()


def _row_to_dict(row) -> dict:
    """Convert asyncpg Record to dict, stringifying datetime values."""
    d = dict(row)
    for k, v in d.items():
        if hasattr(v, 'isoformat'):
            d[k] = v.isoformat()
    return d


async def get_messages(
    channel_id: str,
    conn: asyncpg.Connection,
    limit: int = 50,
    offset: int = 0,
    before_id: Optional[str] = None,
    thread_parent_id: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """
    Get messages from a channel.

    Args:
        channel_id: The channel ID
        conn: asyncpg connection (RLS user set)
        limit: Max number of messages to return
        offset: Offset for pagination
        before_id: Get messages before this message ID (for infinite scroll)
        thread_parent_id: If set, get thread replies for this message

    Returns:
        List of messages with user info
    """
    try:
        # Build the base query joining user, agent and reactions
        # We fetch the raw messages first then do sub-selects for related data
        params: List[Any] = [channel_id]
        conditions = ["cm.channel_id = $1"]
        param_idx = 2

        if thread_parent_id:
            conditions.append(f"cm.thread_parent_id = ${param_idx}")
            params.append(thread_parent_id)
            param_idx += 1
        else:
            conditions.append("cm.thread_parent_id IS NULL")

        if before_id:
            before_row = await conn.fetchrow(
                "SELECT created_at FROM channel_messages WHERE id = $1",
                before_id,
            )
            if before_row:
                before_ts = before_row["created_at"]
                conditions.append(
                    f"(cm.created_at < ${param_idx} OR (cm.created_at = ${param_idx} AND cm.id < ${param_idx + 1}))"
                )
                params.extend([before_ts, before_id])
                param_idx += 2

        where_clause = " AND ".join(conditions)
        sql = f"""
            SELECT
                cm.*,
                json_build_object('id', u.id, 'email', u.email, 'name', u.name, 'avatar_url', u.avatar_url) AS "user",
                CASE WHEN ai.id IS NOT NULL THEN
                    json_build_object('id', ai.id, 'name', ai.name, 'avatar_url', ai.avatar_url)
                ELSE NULL END AS agent,
                COALESCE(
                    json_agg(mr.*) FILTER (WHERE mr.id IS NOT NULL),
                    '[]'::json
                ) AS reactions
            FROM channel_messages cm
            LEFT JOIN users u ON u.id = cm.user_id
            LEFT JOIN agent_instances ai ON ai.id = cm.agent_id
            LEFT JOIN message_reactions mr ON mr.message_id = cm.id
            WHERE {where_clause}
            GROUP BY cm.id, u.id, u.email, u.name, u.avatar_url, ai.id, ai.name, ai.avatar_url
            ORDER BY cm.created_at DESC, cm.id DESC
            LIMIT ${param_idx} OFFSET ${param_idx + 1}
        """
        params.extend([limit, offset])

        rows = await conn.fetch(sql, *params)
        messages = []
        for row in rows:
            d = _row_to_dict(row)
            # Decode JSON columns returned as strings by json_build_object
            for col in ("user", "agent", "reactions"):
                if isinstance(d.get(col), str):
                    try:
                        d[col] = json.loads(d[col])
                    except Exception:
                        pass
            messages.append(d)

        # Reverse to get chronological order
        messages.reverse()

        # Enrich file blocks with presigned URLs
        await _enrich_messages_with_file_urls(messages, conn)

        logger.info(f"Retrieved {len(messages)} messages from channel {channel_id}")
        return messages

    except Exception as e:
        logger.error(f"Error getting messages: {e}")
        raise


async def get_message(
    message_id: str,
    conn: asyncpg.Connection,
) -> Optional[Dict[str, Any]]:
    """
    Get a single message by ID.

    Args:
        message_id: The message ID
        conn: asyncpg connection (RLS user set)

    Returns:
        Message data or None if not found
    """
    try:
        sql = """
            SELECT
                cm.*,
                json_build_object('id', u.id, 'email', u.email, 'name', u.name, 'avatar_url', u.avatar_url) AS "user",
                CASE WHEN ai.id IS NOT NULL THEN
                    json_build_object('id', ai.id, 'name', ai.name, 'avatar_url', ai.avatar_url)
                ELSE NULL END AS agent,
                COALESCE(
                    json_agg(mr.*) FILTER (WHERE mr.id IS NOT NULL),
                    '[]'::json
                ) AS reactions
            FROM channel_messages cm
            LEFT JOIN users u ON u.id = cm.user_id
            LEFT JOIN agent_instances ai ON ai.id = cm.agent_id
            LEFT JOIN message_reactions mr ON mr.message_id = cm.id
            WHERE cm.id = $1
            GROUP BY cm.id, u.id, u.email, u.name, u.avatar_url, ai.id, ai.name, ai.avatar_url
            LIMIT 1
        """
        row = await conn.fetchrow(sql, message_id)
        if row:
            d = _row_to_dict(row)
            for col in ("user", "agent", "reactions"):
                if isinstance(d.get(col), str):
                    try:
                        d[col] = json.loads(d[col])
                    except Exception:
                        pass
            await _enrich_messages_with_file_urls([d], conn)
            return d
        return None

    except Exception as e:
        logger.error(f"Error getting message {message_id}: {e}")
        raise


async def create_message(
    channel_id: str,
    user_id: str,
    conn: asyncpg.Connection,
    blocks: List[Dict[str, Any]],
    thread_parent_id: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Create a new message.

    Args:
        channel_id: The channel ID
        user_id: User sending the message
        conn: asyncpg connection (RLS user set)
        blocks: Content blocks array
        thread_parent_id: If replying in a thread, the parent message ID

    Returns:
        Created message data
    """
    # Extract plain text for search
    content = extract_plain_text(blocks)

    try:
        if thread_parent_id:
            row = await conn.fetchrow(
                """
                INSERT INTO channel_messages (channel_id, user_id, content, blocks, thread_parent_id)
                VALUES ($1, $2, $3, $4, $5)
                RETURNING id
                """,
                channel_id,
                user_id,
                content,
                json.dumps(blocks),
                thread_parent_id,
            )
        else:
            row = await conn.fetchrow(
                """
                INSERT INTO channel_messages (channel_id, user_id, content, blocks)
                VALUES ($1, $2, $3, $4)
                RETURNING id
                """,
                channel_id,
                user_id,
                content,
                json.dumps(blocks),
            )

        if row:
            message_id = row["id"]

            # Fetch with user info
            full_message = await get_message(str(message_id), conn)
            logger.info(f"Created message {message_id} in channel {channel_id}")

            # Embed for semantic search (fire-and-forget)
            from lib.embed_hooks import embed_message
            embed_message(str(message_id), content)

            return full_message or {"id": str(message_id), "channel_id": channel_id}

        raise Exception("Failed to create message")

    except Exception as e:
        logger.error(f"Error creating message: {e}")
        raise


async def update_message(
    message_id: str,
    conn: asyncpg.Connection,
    blocks: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """
    Update a message.

    Args:
        message_id: The message ID
        conn: asyncpg connection (RLS user set)
        blocks: New content blocks array

    Returns:
        Updated message data
    """
    # Extract plain text for search
    content = extract_plain_text(blocks)

    try:
        row = await conn.fetchrow(
            """
            UPDATE channel_messages
            SET content = $1, blocks = $2, is_edited = TRUE, edited_at = NOW()
            WHERE id = $3
            RETURNING id
            """,
            content,
            json.dumps(blocks),
            message_id,
        )

        if row:
            # Fetch with user info (like create_message does)
            full_message = await get_message(message_id, conn)
            logger.info(f"Updated message {message_id}")

            # Re-embed for semantic search (fire-and-forget)
            from lib.embed_hooks import embed_message
            embed_message(message_id, content)

            return full_message or {"id": message_id}

        raise Exception("Message not found or no permission")

    except Exception as e:
        logger.error(f"Error updating message {message_id}: {e}")
        raise


async def delete_message(
    message_id: str,
    conn: asyncpg.Connection,
) -> bool:
    """
    Delete a message.

    Args:
        message_id: The message ID
        conn: asyncpg connection (RLS user set)

    Returns:
        True if successful
    """
    try:
        await conn.execute(
            "DELETE FROM channel_messages WHERE id = $1",
            message_id,
        )

        logger.info(f"Deleted message {message_id}")
        return True

    except Exception as e:
        logger.error(f"Error deleting message {message_id}: {e}")
        raise


async def add_reaction(
    message_id: str,
    user_id: str,
    conn: asyncpg.Connection,
    emoji: str,
) -> Dict[str, Any]:
    """
    Add a reaction to a message.

    Args:
        message_id: The message ID
        user_id: User adding the reaction
        conn: asyncpg connection (RLS user set)
        emoji: Emoji character/code

    Returns:
        Created reaction data
    """
    try:
        row = await conn.fetchrow(
            """
            INSERT INTO message_reactions (message_id, user_id, emoji)
            VALUES ($1, $2, $3)
            ON CONFLICT DO NOTHING
            RETURNING *
            """,
            message_id,
            user_id,
            emoji,
        )

        if row:
            logger.info(f"Added reaction {emoji} to message {message_id}")
            return _row_to_dict(row)

        # Duplicate — reaction already exists
        logger.info(f"Reaction {emoji} already exists on message {message_id}")
        return {"message_id": message_id, "user_id": user_id, "emoji": emoji}

    except Exception as e:
        logger.error(f"Error adding reaction: {e}")
        raise


async def remove_reaction(
    message_id: str,
    user_id: str,
    conn: asyncpg.Connection,
    emoji: str,
) -> bool:
    """
    Remove a reaction from a message.

    Args:
        message_id: The message ID
        user_id: User removing the reaction
        conn: asyncpg connection (RLS user set)
        emoji: Emoji character/code

    Returns:
        True if successful
    """
    try:
        await conn.execute(
            "DELETE FROM message_reactions WHERE message_id = $1 AND user_id = $2 AND emoji = $3",
            message_id,
            user_id,
            emoji,
        )

        logger.info(f"Removed reaction {emoji} from message {message_id}")
        return True

    except Exception as e:
        logger.error(f"Error removing reaction: {e}")
        raise


async def get_thread_replies(
    parent_message_id: str,
    conn: asyncpg.Connection,
    limit: int = 50,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """
    Get replies to a thread.

    Args:
        parent_message_id: The parent message ID
        conn: asyncpg connection (RLS user set)
        limit: Max number of replies
        offset: Offset for pagination

    Returns:
        List of thread replies
    """
    try:
        sql = """
            SELECT
                cm.*,
                json_build_object('id', u.id, 'email', u.email, 'name', u.name, 'avatar_url', u.avatar_url) AS "user",
                CASE WHEN ai.id IS NOT NULL THEN
                    json_build_object('id', ai.id, 'name', ai.name, 'avatar_url', ai.avatar_url)
                ELSE NULL END AS agent,
                COALESCE(
                    json_agg(mr.*) FILTER (WHERE mr.id IS NOT NULL),
                    '[]'::json
                ) AS reactions
            FROM channel_messages cm
            LEFT JOIN users u ON u.id = cm.user_id
            LEFT JOIN agent_instances ai ON ai.id = cm.agent_id
            LEFT JOIN message_reactions mr ON mr.message_id = cm.id
            WHERE cm.thread_parent_id = $1
            GROUP BY cm.id, u.id, u.email, u.name, u.avatar_url, ai.id, ai.name, ai.avatar_url
            ORDER BY cm.created_at ASC
            LIMIT $2 OFFSET $3
        """
        rows = await conn.fetch(sql, parent_message_id, limit, offset)
        replies = []
        for row in rows:
            d = _row_to_dict(row)
            for col in ("user", "agent", "reactions"):
                if isinstance(d.get(col), str):
                    try:
                        d[col] = json.loads(d[col])
                    except Exception:
                        pass
            replies.append(d)

        # Enrich file blocks with presigned URLs
        await _enrich_messages_with_file_urls(replies, conn)

        return replies

    except Exception as e:
        logger.error(f"Error getting thread replies: {e}")
        raise


# =============================================================================
# Helpers: Enrich file blocks with image proxy / presigned download URLs
# =============================================================================

async def _enrich_messages_with_file_urls(messages: List[Dict[str, Any]], conn: asyncpg.Connection) -> None:
    """
    Scan message blocks and attach URLs for file blocks.

    If the image proxy is configured, generates deterministic HMAC-signed URLs
    that are CDN-cacheable. Falls back to presigned URLs if not configured.

    Mutates the message dicts in-place.
    """
    if not messages:
        return

    # Feature flag: use legacy presigned URLs if proxy is not configured
    if not settings.image_proxy_url or not settings.image_proxy_secret:
        return await _enrich_messages_with_file_urls_legacy(messages, conn)

    # Collect ALL file blocks by file_id for a single batch DB lookup.
    # Never trust client-supplied r2_key — always resolve from DB via file_id
    # to prevent forged access to arbitrary R2 objects.
    file_id_to_blocks: Dict[str, List[Dict[str, Any]]] = {}

    for msg in messages:
        blocks = msg.get("blocks") or []
        if not isinstance(blocks, list) or not blocks:
            continue

        for block in blocks:
            if not isinstance(block, dict) or block.get("type") != "file":
                continue
            data = block.get("data") or {}
            fid = data.get("file_id") or data.get("id")
            if fid:
                file_id_to_blocks.setdefault(fid, []).append(data)

    if not file_id_to_blocks:
        return

    # Single batch query: resolve file_id -> (r2_key, file_type) from DB.
    # Uses the RLS-enforced connection so users can only access files they own
    # or that belong to their workspace.
    try:
        file_ids = list(file_id_to_blocks.keys())
        rows = await conn.fetch(
            "SELECT id, r2_key, file_type FROM files WHERE id = ANY($1::uuid[])",
            file_ids,
        )
        for f in rows:
            r2_key = f.get("r2_key")
            if not r2_key:
                continue
            mime = f.get("file_type") or "application/octet-stream"
            for data_ref in file_id_to_blocks.get(str(f["id"]), []):
                data_ref["r2_key"] = r2_key
                if is_image_type(mime):
                    chat_url = generate_file_url(r2_key, mime, "chat")
                    preview_url = generate_file_url(r2_key, mime, "preview")
                    full_url = generate_file_url(r2_key, mime, "full")
                    data_ref["chat_url"] = chat_url
                    data_ref["preview_url"] = preview_url
                    data_ref["full_url"] = full_url
                    data_ref["url"] = chat_url or preview_url or full_url
                else:
                    data_ref["url"] = generate_file_url(r2_key, mime, "full")
    except Exception as e:
        logger.warning(f"Batch file lookup failed, falling back to legacy: {e}")
        await _enrich_messages_with_file_urls_legacy(messages, conn)


async def _enrich_messages_with_file_urls_legacy(messages: List[Dict[str, Any]], conn: asyncpg.Connection) -> None:
    """Legacy enrichment using presigned URLs and per-file DB queries.

    Kept as fallback when image proxy is not configured.
    Uses get_admin_db_conn for channel/file lookups (bypasses RLS for metadata).
    """
    if not messages:
        return

    r2 = get_r2_client()

    channel_ctx_cache: Dict[str, Tuple[str, str]] = {}
    file_url_cache: Dict[str, str] = {}

    async def get_channel_ctx(channel_id: str) -> Tuple[str, str]:
        if channel_id in channel_ctx_cache:
            return channel_ctx_cache[channel_id]

        async with get_admin_db_conn() as admin:
            ctx_row = await admin.fetchrow(
                """
                SELECT c.workspace_app_id, wa.workspace_id
                FROM channels c
                LEFT JOIN workspace_apps wa ON wa.id = c.workspace_app_id
                WHERE c.id = $1
                """,
                channel_id,
            )

        if not ctx_row:
            raise Exception("Channel context not found")

        wa_id = ctx_row["workspace_app_id"]
        ws_id = ctx_row["workspace_id"]

        if not ws_id:
            async with get_admin_db_conn() as admin:
                wa_row = await admin.fetchrow(
                    "SELECT workspace_id FROM workspace_apps WHERE id = $1",
                    wa_id,
                )
            ws_id = wa_row["workspace_id"] if wa_row else None

        if not ws_id:
            raise Exception("Workspace context not found for channel")

        channel_ctx_cache[channel_id] = (str(ws_id), str(wa_id))
        return str(ws_id), str(wa_id)

    for msg in messages:
        blocks = msg.get("blocks") or []
        if not isinstance(blocks, list) or not blocks:
            continue

        channel_id = msg.get("channel_id")
        if not channel_id:
            continue

        try:
            ws_id, wa_id = await get_channel_ctx(channel_id)
        except Exception:
            continue

        for block in blocks:
            try:
                if not isinstance(block, dict) or block.get("type") != "file":
                    continue
                data = block.get("data") or {}

                file_id = data.get("file_id") or data.get("id")
                r2_key = data.get("r2_key")
                url: Optional[str] = None

                async with get_admin_db_conn() as admin:
                    if file_id:
                        if file_id in file_url_cache:
                            url = file_url_cache[file_id]
                        else:
                            f_row = await admin.fetchrow(
                                "SELECT id, r2_key, workspace_id, workspace_app_id FROM files WHERE id = $1",
                                file_id,
                            )
                            if f_row:
                                if str(f_row.get("workspace_id")) == ws_id or str(f_row.get("workspace_app_id")) == wa_id:
                                    url = r2.get_presigned_url(f_row["r2_key"], expiration=3600)
                                    file_url_cache[file_id] = url
                    elif r2_key:
                        f2_row = await admin.fetchrow(
                            "SELECT id, workspace_id, workspace_app_id FROM files WHERE r2_key = $1",
                            r2_key,
                        )
                        if f2_row:
                            if str(f2_row.get("workspace_id")) == ws_id or str(f2_row.get("workspace_app_id")) == wa_id:
                                url = r2.get_presigned_url(r2_key, expiration=3600)

                if url:
                    data["url"] = url
                    block["data"] = data
            except Exception as e:
                logger.debug(f"Skipping file URL enrichment due to error: {e}")
