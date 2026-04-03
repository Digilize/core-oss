"""Service for document version history."""
from typing import Optional, List
import asyncpg
import logging

logger = logging.getLogger(__name__)


async def list_versions(
    document_id: str,
    conn: asyncpg.Connection,
) -> List[dict]:
    """List all versions for a document (without content, for performance).

    Returns versions ordered by version_number descending (newest first).
    RLS ensures the caller has access to the parent document.
    """
    try:
        rows = await conn.fetch(
            """
            SELECT id, document_id, title, version_number, created_by, created_at
            FROM document_versions
            WHERE document_id = $1
            ORDER BY version_number DESC
            """,
            document_id,
        )
        return [dict(r) for r in rows]
    except Exception as e:
        logger.error(f"Error listing versions for document {document_id}: {e}")
        raise


async def get_version(
    document_id: str,
    version_id: str,
    conn: asyncpg.Connection,
) -> Optional[dict]:
    """Get a specific version with full content.

    RLS ensures the caller has access to the parent document.
    """
    try:
        row = await conn.fetchrow(
            """
            SELECT *
            FROM document_versions
            WHERE id = $1 AND document_id = $2
            """,
            version_id,
            document_id,
        )
        return dict(row) if row else None
    except Exception as e:
        logger.error(f"Error getting version {version_id}: {e}")
        raise


async def restore_version(
    document_id: str,
    version_id: str,
    user_id: str,
    conn: asyncpg.Connection,
) -> dict:
    """Restore a document to a previous version.

    This updates the live document with the version's content and title.
    The update_document service will automatically snapshot the current
    content before overwriting, so the pre-restore state is also preserved.
    """
    from .update_document import update_document

    # Fetch the version to restore
    version = await get_version(document_id, version_id, conn)
    if not version:
        raise ValueError("Version not found")

    # Update the live document with the version's content.
    # force_snapshot=True ensures the current state is always captured before
    # the restore overwrites it, bypassing interval and diff-size gates.
    updated_doc = await update_document(
        user_id=user_id,
        conn=conn,
        document_id=document_id,
        title=version.get("title"),
        content=version.get("content"),
        force_snapshot=True,
    )

    logger.info(f"Restored document {document_id} to version {version.get('version_number')}")
    return updated_doc
