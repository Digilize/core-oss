"""Service for creating new documents."""
from typing import Optional, List
import asyncpg
import logging

logger = logging.getLogger(__name__)


async def create_document(
    user_id: str,
    conn: asyncpg.Connection,
    workspace_app_id: str,
    title: str = "Untitled",
    content: str = "",
    icon: Optional[str] = None,
    cover_image: Optional[str] = None,
    parent_id: Optional[str] = None,
    position: int = 0,
    tags: Optional[List[str]] = None,
) -> dict:
    """
    Create a new document.

    Args:
        user_id: User ID who owns the document
        conn: Authenticated asyncpg connection (RLS already set for this user)
        workspace_app_id: Workspace app ID (files app)
        title: Document title
        content: Document content (markdown)
        icon: Optional emoji or icon identifier
        cover_image: Optional cover image URL
        parent_id: Optional parent document ID for nesting
        position: Position for ordering (default 0)
        tags: Optional list of tags for categorization

    Returns:
        The created document record
    """
    try:
        # Lookup workspace_id from workspace_app
        app_row = await conn.fetchrow(
            "SELECT workspace_id FROM workspace_apps WHERE id = $1",
            workspace_app_id,
        )

        if not app_row:
            raise ValueError("Workspace app not found")

        workspace_id = app_row["workspace_id"]

        doc = await conn.fetchrow(
            """
            INSERT INTO documents
                (user_id, workspace_app_id, workspace_id, title, content,
                 position, tags, type, icon, cover_image, parent_id)
            VALUES
                ($1, $2, $3, $4, $5, $6, $7, 'note',
                 $8, $9, $10)
            RETURNING *
            """,
            user_id,
            workspace_app_id,
            workspace_id,
            title,
            content,
            position,
            tags or [],
            icon,
            cover_image,
            parent_id,
        )

        if not doc:
            raise Exception("Failed to create document")

        result = dict(doc)
        logger.info(f"Created document {result['id']} for user {user_id}")

        # Embed for semantic search (fire-and-forget)
        from lib.embed_hooks import embed_document
        embed_document(result["id"], title, content)

        return result

    except Exception as e:
        logger.error(f"Error creating document: {str(e)}")
        raise
