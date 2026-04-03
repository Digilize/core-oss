"""Get presigned URL service - generates temporary download URLs for files."""

from typing import Optional
import asyncpg
import logging

from lib.r2_client import get_r2_client

logger = logging.getLogger(__name__)


async def get_presigned_url(
    user_id: str,
    conn: asyncpg.Connection,
    file_id: str,
    expiration: Optional[int] = None,
) -> dict:
    """
    Generate a presigned URL for downloading a file from R2.

    Args:
        user_id: The ID of the user requesting the URL
        conn: Authenticated asyncpg connection (RLS already set for this user)
        file_id: The ID of the file
        expiration: URL expiration in seconds (default: from settings)

    Returns:
        dict with presigned URL and file metadata

    Raises:
        Exception: If file not found
    """
    r2_client = get_r2_client()

    logger.info(f"Generating presigned URL for file {file_id}")

    # Get file metadata (RLS ensures user owns or can access it)
    row = await conn.fetchrow(
        "SELECT * FROM files WHERE id = $1",
        file_id,
    )

    if not row:
        raise Exception(f"File not found: {file_id}")

    file_record = dict(row)
    r2_key = file_record["r2_key"]

    # Generate presigned URL
    url = r2_client.get_presigned_url(r2_key, expiration)

    logger.info(f"Generated presigned URL for: {file_id}")

    return {
        "url": url,
        "file": file_record,
        "expires_in": expiration or r2_client.presigned_url_expiry,
    }
