"""Service for favoriting/unfavoriting documents."""
import asyncpg
import logging

logger = logging.getLogger(__name__)


async def favorite_document(user_id: str, conn: asyncpg.Connection, document_id: str) -> dict:
    """
    Mark a document as favorite.

    Args:
        user_id: User ID who owns the document
        conn: Authenticated asyncpg connection (RLS already set for this user)
        document_id: Document ID to favorite

    Returns:
        The updated document record
    """
    try:
        row = await conn.fetchrow(
            """
            UPDATE documents
            SET is_favorite = TRUE
            WHERE user_id = $1 AND id = $2
            RETURNING *
            """,
            user_id,
            document_id,
        )

        if not row:
            raise Exception("Failed to favorite document or document not found")

        logger.info(f"Favorited document {document_id} for user {user_id}")
        return dict(row)

    except Exception as e:
        logger.error(f"Error favoriting document {document_id}: {str(e)}")
        raise


async def unfavorite_document(user_id: str, conn: asyncpg.Connection, document_id: str) -> dict:
    """
    Remove favorite mark from a document.

    Args:
        user_id: User ID who owns the document
        conn: Authenticated asyncpg connection (RLS already set for this user)
        document_id: Document ID to unfavorite

    Returns:
        The updated document record
    """
    try:
        row = await conn.fetchrow(
            """
            UPDATE documents
            SET is_favorite = FALSE
            WHERE user_id = $1 AND id = $2
            RETURNING *
            """,
            user_id,
            document_id,
        )

        if not row:
            raise Exception("Failed to unfavorite document or document not found")

        logger.info(f"Unfavorited document {document_id} for user {user_id}")
        return dict(row)

    except Exception as e:
        logger.error(f"Error unfavoriting document {document_id}: {str(e)}")
        raise
