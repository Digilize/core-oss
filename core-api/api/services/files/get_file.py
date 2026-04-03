"""Get file service - retrieves file metadata from database."""

import asyncpg
import logging

logger = logging.getLogger(__name__)


async def get_file(
    user_id: str,
    conn: asyncpg.Connection,
    file_id: str,
) -> dict:
    """
    Get file metadata from the database.

    Args:
        user_id: The ID of the user requesting the file
        conn: Authenticated asyncpg connection (RLS already set for this user)
        file_id: The ID of the file to retrieve

    Returns:
        File metadata dict

    Raises:
        Exception: If file not found
    """
    logger.info(f"Getting file {file_id} for user {user_id}")

    row = await conn.fetchrow(
        "SELECT * FROM files WHERE id = $1",
        file_id,
    )

    if not row:
        raise Exception(f"File not found: {file_id}")

    logger.info(f"Found file: {file_id}")
    return dict(row)
