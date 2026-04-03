"""Service for updating documents."""
from typing import Optional, List
import asyncio
import asyncpg
from fastapi import HTTPException, status
from api.services.notifications.file_edits import emit_document_edited_notification
import logging

logger = logging.getLogger(__name__)

# Minimum content-length change required to trigger a snapshot.
MIN_DIFF_CHARS = 100


def _should_snapshot(
    document_type: Optional[str],
    old_content: str,
    new_content: Optional[str],
    force: bool = False,
) -> bool:
    """Decide whether a version snapshot should be attempted.

    Cheap deterministic checks only — no DB calls.  The time-interval gate
    lives in the ``insert_document_version_snapshot`` RPC so it is serialised
    under the advisory lock.

    When *force* is True every check except "is it a note?" is bypassed.
    This is used by the restore flow to guarantee the pre-restore state is
    always captured.
    """
    # Always require the document to be a note.
    if document_type and document_type != "note":
        logger.debug("[version] skip: document type is '%s', not 'note'", document_type)
        return False

    if force:
        logger.info("[version] force_snapshot requested — bypassing diff checks")
        return True

    if new_content is None:
        logger.debug("[version] skip: new_content is None (no content change)")
        return False

    # Content must actually differ.
    if old_content == new_content:
        logger.debug("[version] skip: content unchanged")
        return False

    # First non-empty save — always capture as Version 1 regardless of size.
    if not old_content.strip():
        logger.info("[version] first non-empty save — will snapshot")
        return True

    # Require a minimum magnitude of change (avoids snapshotting typo fixes).
    diff_size = abs(len(new_content) - len(old_content))
    if diff_size < MIN_DIFF_CHARS:
        logger.debug(
            "[version] skip: diff size %d < threshold %d",
            diff_size,
            MIN_DIFF_CHARS,
        )
        return False

    return True


async def _snapshot_version_async(
    conn: asyncpg.Connection,
    document_id: str,
    old_title: str,
    old_content: str,
    user_id: str,
    force: bool = False,
) -> bool:
    """Snapshot previous document content in the background.

    The interval check is handled atomically inside the RPC function under
    an advisory lock — no Python-side time check needed.

    When *force* is True the RPC is told to bypass the interval gate (used
    by restore to guarantee reversibility).

    Failures are intentionally non-blocking to keep save latency stable.
    """
    try:
        insert_row = await conn.fetchrow(
            "SELECT * FROM insert_document_version_snapshot($1, $2, $3, $4, $5)",
            document_id,
            old_title,
            old_content,
            user_id,
            force,
        )

        if not insert_row:
            # RPC returned no rows — interval gate rejected the snapshot.
            logger.info("[version] %s: skipped by RPC (interval not met)", document_id)
            return False

        version_number = insert_row.get("version_number")
        logger.info("[version] %s: saved v%s%s", document_id, version_number, " (forced)" if force else "")

        # Keep at most 50 versions per document (best effort).
        try:
            old_rows = await conn.fetch(
                """
                SELECT id FROM document_versions
                WHERE document_id = $1
                ORDER BY version_number DESC
                OFFSET 50
                LIMIT 100
                """,
                document_id,
            )
            if old_rows:
                old_ids = [r["id"] for r in old_rows]
                await conn.execute(
                    "DELETE FROM document_versions WHERE id = ANY($1::uuid[])",
                    old_ids,
                )
                logger.info("[version] %s: pruned %d old versions", document_id, len(old_ids))
        except Exception as prune_exc:
            logger.warning(
                "[version] %s: prune skipped — %s: %s",
                document_id,
                type(prune_exc).__name__,
                prune_exc,
            )

        return True
    except Exception as exc:
        logger.error(
            "[version] %s: FAILED — %s: %s",
            document_id,
            type(exc).__name__,
            exc,
            exc_info=True,
        )
        return False


async def _process_document_change_async(
    *,
    conn: asyncpg.Connection,
    document_id: str,
    old_title: str,
    old_content: str,
    new_title: str,
    user_id: str,
    workspace_id: Optional[str],
    owner_id: Optional[str],
    file_id: Optional[str],
    should_snapshot: bool,
    title_changed: bool,
    force_snapshot: bool = False,
) -> None:
    """Run non-blocking versioning and notification side effects for a save."""
    if should_snapshot:
        await _snapshot_version_async(
            conn=conn,
            document_id=document_id,
            old_title=old_title,
            old_content=old_content,
            user_id=user_id,
            force=force_snapshot,
        )

    if not should_snapshot and not title_changed:
        return

    try:
        await emit_document_edited_notification(
            document_id=document_id,
            document_title=new_title,
            editor_user_id=user_id,
            workspace_id=workspace_id,
            owner_id=owner_id,
            file_id=file_id,
        )
    except Exception as exc:
        logger.warning(
            "[file_edited] %s: notification skipped — %s: %s",
            document_id,
            type(exc).__name__,
            exc,
        )


async def update_document(
    user_id: str,
    conn: asyncpg.Connection,
    document_id: str,
    title: Optional[str] = None,
    content: Optional[str] = None,
    icon: Optional[str] = None,
    cover_image: Optional[str] = None,
    parent_id: Optional[str] = None,
    position: Optional[int] = None,
    tags: Optional[List[str]] = None,
    parent_id_explicitly_set: bool = False,
    expected_updated_at: Optional[str] = None,
    force_snapshot: bool = False,
) -> dict:
    """
    Update an existing document.

    Authorization is handled by RLS - owner or workspace member can update.

    Args:
        user_id: ID of the user performing the update
        conn: Authenticated asyncpg connection (RLS already set for this user)
        document_id: Document ID to update
        title: New title (optional)
        content: New content (optional)
        icon: New icon (optional)
        cover_image: New cover image (optional)
        parent_id: New parent ID (optional, can be None to move to root)
        position: New position (optional)
        tags: New tags list (optional)
        parent_id_explicitly_set: If True, parent_id will be updated even if None
                                  (used to move documents to root)
        expected_updated_at: Optional optimistic-lock timestamp from client.
        force_snapshot: If True, always create a version snapshot of the current
                        state before applying this update (bypasses interval and
                        diff-size checks).  Used by restore_version to guarantee
                        the pre-restore state is preserved.

    Returns:
        The updated document record
    """
    try:
        # Build SET clause dynamically
        set_parts: List[str] = []
        params: List = []

        def _p(val) -> str:
            params.append(val)
            return f"${len(params)}"

        if title is not None:
            set_parts.append(f"title = {_p(title)}")
        if content is not None:
            set_parts.append(f"content = {_p(content)}")
        if icon is not None:
            set_parts.append(f"icon = {_p(icon)}")
        if cover_image is not None:
            set_parts.append(f"cover_image = {_p(cover_image)}")
        if parent_id_explicitly_set:
            set_parts.append(f"parent_id = {_p(parent_id)}")
        elif parent_id is not None:
            set_parts.append(f"parent_id = {_p(parent_id)}")
        if position is not None:
            set_parts.append(f"position = {_p(position)}")
        if tags is not None:
            set_parts.append(f"tags = {_p(tags)}")

        if not set_parts:
            raise ValueError("No fields to update")

        # Read current state once for optimistic locking and version snapshot inputs.
        current_row = await conn.fetchrow(
            """
            SELECT title, content, type, updated_at, workspace_id, user_id, file_id
            FROM documents
            WHERE id = $1
            LIMIT 1
            """,
            document_id,
        )
        if not current_row:
            raise Exception("Document not found or access denied")

        current_doc = dict(current_row)
        old_title = current_doc.get("title") or ""
        old_content = current_doc.get("content") or ""
        doc_type = current_doc.get("type")
        workspace_id = current_doc.get("workspace_id")
        owner_id = str(current_doc.get("user_id")) if current_doc.get("user_id") else None
        file_id = str(current_doc.get("file_id")) if current_doc.get("file_id") else None

        # Optimistic locking
        if expected_updated_at:
            set_parts_str = ", ".join(set_parts)
            params.append(document_id)
            id_param = f"${len(params)}"
            params.append(expected_updated_at)
            ts_param = f"${len(params)}"
            updated_row = await conn.fetchrow(
                f"UPDATE documents SET {set_parts_str} WHERE id = {id_param} AND updated_at = {ts_param} RETURNING id",
                *params,
            )
        else:
            set_parts_str = ", ".join(set_parts)
            params.append(document_id)
            id_param = f"${len(params)}"
            updated_row = await conn.fetchrow(
                f"UPDATE documents SET {set_parts_str} WHERE id = {id_param} RETURNING id",
                *params,
            )

        if not updated_row:
            exists_row = await conn.fetchrow(
                "SELECT id FROM documents WHERE id = $1 LIMIT 1",
                document_id,
            )
            if exists_row:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Document changed in another session. Refresh and retry.",
                )
            raise Exception("Document not found or access denied")

        logger.info(f"Updated document {document_id} by user {user_id}")

        # Re-embed if content or title changed (fire-and-forget)
        new_title = title if title is not None else old_title
        new_content = content if content is not None else old_content
        if title is not None or content is not None:
            from lib.embed_hooks import embed_document
            embed_document(document_id, new_title, new_content)

        should_snap = _should_snapshot(doc_type, old_content, content, force=force_snapshot)
        title_changed = (
            doc_type == "note"
            and title is not None
            and title != old_title
        )

        if should_snap or title_changed:
            asyncio.create_task(
                _process_document_change_async(
                    conn=conn,
                    document_id=document_id,
                    old_title=old_title,
                    old_content=old_content,
                    new_title=new_title,
                    user_id=user_id,
                    workspace_id=str(workspace_id) if workspace_id else None,
                    owner_id=owner_id,
                    file_id=file_id,
                    should_snapshot=should_snap,
                    title_changed=title_changed,
                    force_snapshot=force_snapshot,
                )
            )

        # Fetch the complete document with file data joined
        full_row = await conn.fetchrow(
            """
            SELECT
                d.*,
                f.id          AS file__id,
                f.user_id     AS file__user_id,
                f.workspace_id AS file__workspace_id,
                f.workspace_app_id AS file__workspace_app_id,
                f.filename    AS file__filename,
                f.file_type   AS file__file_type,
                f.file_size   AS file__file_size,
                f.r2_key      AS file__r2_key,
                f.status      AS file__status,
                f.created_at  AS file__created_at,
                f.uploaded_at AS file__uploaded_at
            FROM documents d
            LEFT JOIN files f ON f.id = d.file_id
            WHERE d.id = $1
            """,
            document_id,
        )

        if full_row:
            from api.services.documents.get_documents import _row_to_doc
            return _row_to_doc(full_row)

        # Fallback: return minimal dict with just the id
        return {"id": document_id}

    except Exception as e:
        logger.error(f"Error updating document {document_id}: {str(e)}")
        raise
