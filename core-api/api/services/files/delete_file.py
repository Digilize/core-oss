"""Delete file service - handles file deletion from R2 and database."""

import asyncpg
import logging

from lib.r2_client import get_r2_client

logger = logging.getLogger(__name__)


async def delete_file(
    user_id: str,
    conn: asyncpg.Connection,
    file_id: str,
) -> bool:
    """
    Delete a file from R2 and remove metadata from the database.
    Also removes any document entries that reference this file.

    Authorization is handled by RLS (owner or workspace admin can delete).
    DB deletion happens FIRST to ensure authorization before R2 deletion.

    Args:
        user_id: The ID of the user deleting the file
        conn: Authenticated asyncpg connection (RLS already set for this user)
        file_id: The ID of the file to delete

    Returns:
        True if deletion was successful

    Raises:
        Exception: If deletion fails or not authorized
    """
    logger.info(f"Deleting file {file_id} for user {user_id}")

    # Delete any documents that reference this file first
    # RLS will enforce authorization
    deleted_docs = await conn.fetch(
        "DELETE FROM documents WHERE file_id = $1 RETURNING id",
        file_id,
    )
    if deleted_docs:
        logger.info(f"Deleted {len(deleted_docs)} document(s) referencing file")

    # Delete file metadata from database FIRST
    # RLS enforces authorization — only owner or workspace admin can delete
    deleted_row = await conn.fetchrow(
        "DELETE FROM files WHERE id = $1 RETURNING id, r2_key",
        file_id,
    )

    if not deleted_row:
        # RLS blocked the delete (not authorized) or file not found
        raise Exception(f"Failed to delete file: {file_id} (not found or not authorized)")

    # DB delete succeeded — now safe to delete from R2
    r2_key = deleted_row["r2_key"]

    if r2_key:
        try:
            r2_client = get_r2_client()
            r2_client.delete_file(r2_key)
            logger.info(f"Deleted file from R2: {r2_key}")
        except Exception as e:
            # Log but don't fail — DB record is already deleted
            # Orphaned R2 files can be cleaned up separately
            logger.error(f"Failed to delete from R2 (DB already deleted): {e}")

    logger.info(f"File deleted successfully: {file_id}")
    return True
