"""Service for creating folders."""
from typing import Optional
import asyncpg
import logging

logger = logging.getLogger(__name__)


async def create_folder(
    user_id: str,
    conn: asyncpg.Connection,
    workspace_app_id: str,
    title: str = "New Folder",
    parent_id: Optional[str] = None,
    position: int = 0,
) -> dict:
    """
    Create a new folder.

    Args:
        user_id: User ID who owns the folder
        conn: Authenticated asyncpg connection (RLS already set for this user)
        workspace_app_id: Workspace app ID (files app)
        title: Folder title
        parent_id: Optional parent folder ID for nesting
        position: Position for ordering (default 0)

    Returns:
        The created folder record
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

        folder_row = await conn.fetchrow(
            """
            INSERT INTO documents
                (user_id, workspace_app_id, workspace_id, title, content,
                 type, position, parent_id)
            VALUES
                ($1, $2, $3, $4, '', 'folder', $5, $6)
            RETURNING *
            """,
            user_id,
            workspace_app_id,
            workspace_id,
            title,
            position,
            parent_id,
        )

        if not folder_row:
            raise Exception("Failed to create folder")

        result = dict(folder_row)
        logger.info(f"Created folder {result['id']} for user {user_id}")
        return result

    except Exception as e:
        logger.error(f"Error creating folder: {str(e)}")
        raise
