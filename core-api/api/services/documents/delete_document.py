"""Service for deleting documents."""
import asyncpg
from lib.r2_client import get_r2_client
import logging

logger = logging.getLogger(__name__)


async def delete_document(user_id: str, conn: asyncpg.Connection, document_id: str) -> bool:
    """
    Permanently delete a document.

    If the document has an associated file (file_id), also deletes the file
    from R2 storage and the files table.

    Note: This will cascade delete all child documents.
    Authorization is handled by RLS (owner or workspace admin can delete).
    DB deletion happens FIRST to ensure authorization before R2 deletion.

    Args:
        user_id: ID of the user performing the delete
        conn: Authenticated asyncpg connection (RLS already set for this user)
        document_id: Document ID to delete

    Returns:
        True if successful
    """
    try:
        # First, get the document to check if it has a file_id
        doc_row = await conn.fetchrow(
            """
            SELECT
                d.*,
                f.id       AS file__id,
                f.r2_key   AS file__r2_key
            FROM documents d
            LEFT JOIN files f ON f.id = d.file_id
            WHERE d.id = $1
            """,
            document_id,
        )

        if not doc_row:
            raise Exception("Document not found")

        file_id = doc_row["file__id"]
        r2_key = doc_row["file__r2_key"]

        # Delete the document FIRST - RLS enforces authorization
        deleted_row = await conn.fetchrow(
            "DELETE FROM documents WHERE id = $1 RETURNING id",
            document_id,
        )

        if not deleted_row:
            raise Exception("Failed to delete document (not authorized)")

        logger.info(f"Deleted document {document_id} for user {user_id}")

        # Document delete succeeded - now safe to clean up associated file
        if file_id:
            file_deleted = await conn.fetchrow(
                "DELETE FROM files WHERE id = $1 RETURNING id",
                file_id,
            )

            if file_deleted:
                logger.info(f"Deleted file record: {file_id}")

                # Only delete from R2 if DB delete succeeded
                if r2_key:
                    try:
                        r2_client = get_r2_client()
                        r2_client.delete_file(r2_key)
                        logger.info(f"Deleted file from R2: {r2_key}")
                    except Exception as e:
                        # Log but don't fail - DB records already deleted
                        logger.error(f"Failed to delete from R2 (DB already deleted): {e}")
            else:
                logger.warning(f"Could not delete file record: {file_id}")

        return True

    except Exception as e:
        logger.error(f"Error deleting document {document_id}: {str(e)}")
        raise
