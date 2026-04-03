"""List files service - retrieves user's files from database."""

from typing import Optional, List
import asyncpg
import logging

logger = logging.getLogger(__name__)


async def list_files(
    user_id: str,
    conn: asyncpg.Connection,
    workspace_ids: Optional[List[str]] = None,
    workspace_app_ids: Optional[List[str]] = None,
    # Singular convenience params (wrapped into lists internally)
    workspace_id: Optional[str] = None,
    workspace_app_id: Optional[str] = None,
    file_type: Optional[str] = None,
    limit: int = 100,
    offset: int = 0,
) -> list:
    """
    List files for a user with optional filtering.

    Args:
        user_id: The ID of the user
        conn: Authenticated asyncpg connection (RLS already set for this user)
        workspace_ids: Workspace IDs to filter by
        workspace_app_ids: Workspace app IDs to filter by (most specific)
        workspace_id: Single workspace ID (convenience, wrapped into list)
        workspace_app_id: Single workspace app ID (convenience, wrapped into list)
        file_type: Optional MIME type filter (e.g., 'image/png' or 'image/' for all images)
        limit: Maximum number of files to return (default: 100, max: 100)
        offset: Offset for pagination (default: 0)

    Returns:
        List of file metadata dicts
    """
    # Normalize singular params into lists
    if workspace_app_id and not workspace_app_ids:
        workspace_app_ids = [workspace_app_id]
    if workspace_id and not workspace_ids:
        workspace_ids = [workspace_id]

    logger.info(f"Listing files for user {user_id}")

    limit = min(limit, 100)

    conditions: List[str] = []
    params: List = []

    def _p(val) -> str:
        params.append(val)
        return f"${len(params)}"

    # Apply filters: most specific wins (RLS handles access control)
    if workspace_app_ids:
        conditions.append(f"workspace_app_id = ANY({_p(workspace_app_ids)}::uuid[])")
    elif workspace_ids:
        conditions.append(f"workspace_id = ANY({_p(workspace_ids)}::uuid[])")
    else:
        conditions.append(f"user_id = {_p(user_id)}")

    # Filter by file type if specified
    if file_type:
        if file_type.endswith("/"):
            conditions.append(f"file_type LIKE {_p(file_type + '%')}")
        else:
            conditions.append(f"file_type = {_p(file_type)}")

    where_clause = "WHERE " + " AND ".join(conditions) if conditions else ""

    params.append(limit)
    params.append(offset)
    limit_placeholder = f"${len(params) - 1}"
    offset_placeholder = f"${len(params)}"

    sql = f"""
        SELECT * FROM files
        {where_clause}
        ORDER BY uploaded_at DESC
        LIMIT {limit_placeholder} OFFSET {offset_placeholder}
    """

    rows = await conn.fetch(sql, *params)
    files = [dict(r) for r in rows]
    logger.info(f"Found {len(files)} files")

    return files
