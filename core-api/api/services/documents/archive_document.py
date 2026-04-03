"""Service for archiving/unarchiving documents."""
import asyncpg
import logging

logger = logging.getLogger(__name__)


async def archive_document(user_id: str, conn: asyncpg.Connection, document_id: str) -> dict:
    """
    Archive a document (soft delete).

    Args:
        user_id: User ID who owns the document
        conn: Authenticated asyncpg connection (RLS already set for this user)
        document_id: Document ID to archive

    Returns:
        The updated document record
    """
    try:
        row = await conn.fetchrow(
            """
            UPDATE documents
            SET is_archived = TRUE
            WHERE user_id = $1 AND id = $2
            RETURNING *
            """,
            user_id,
            document_id,
        )

        if not row:
            raise Exception("Failed to archive document or document not found")

        logger.info(f"Archived document {document_id} for user {user_id}")
        return dict(row)

    except Exception as e:
        logger.error(f"Error archiving document {document_id}: {str(e)}")
        raise


async def unarchive_document(user_id: str, conn: asyncpg.Connection, document_id: str) -> dict:
    """
    Unarchive a document.

    Args:
        user_id: User ID who owns the document
        conn: Authenticated asyncpg connection (RLS already set for this user)
        document_id: Document ID to unarchive

    Returns:
        The updated document record
    """
    try:
        row = await conn.fetchrow(
            """
            UPDATE documents
            SET is_archived = FALSE
            WHERE user_id = $1 AND id = $2
            RETURNING *
            """,
            user_id,
            document_id,
        )

        if not row:
            raise Exception("Failed to unarchive document or document not found")

        logger.info(f"Unarchived document {document_id} for user {user_id}")
        return dict(row)

    except Exception as e:
        logger.error(f"Error unarchiving document {document_id}: {str(e)}")
        raise
