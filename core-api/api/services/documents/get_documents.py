"""Service for retrieving documents."""
from typing import Optional, List, Literal
from fastapi import HTTPException, status
import asyncpg
import json
from lib.image_proxy import generate_file_url, is_image_type
from api.config import settings
import logging

logger = logging.getLogger(__name__)


def _enrich_documents_with_image_urls(documents: List[dict]) -> None:
    """Add thumb_url/preview_url/file_url for image-type documents.

    Only enriches when the image proxy is configured. Mutates in-place.
    """
    if not settings.image_proxy_url or not settings.image_proxy_secret:
        return

    for doc in documents:
        file_data = doc.get("file")
        if not file_data or not isinstance(file_data, dict):
            continue
        r2_key = file_data.get("r2_key")
        mime = file_data.get("file_type", "")
        if not r2_key:
            continue
        if is_image_type(mime):
            doc["thumb_url"] = generate_file_url(r2_key, mime, "thumb")
            doc["preview_url"] = generate_file_url(r2_key, mime, "preview")
            doc["file_url"] = generate_file_url(r2_key, mime, "full")

# Valid sort options
SortBy = Literal["name", "type", "date", "size", "position"]
SortDirection = Literal["asc", "desc"]


def _row_to_doc(row: asyncpg.Record) -> dict:
    """Convert an asyncpg Record to a plain dict, handling the nested file sub-object."""
    d = dict(row)
    # file columns are prefixed with file__ — reconstruct nested dict
    file_keys = [k for k in d if k.startswith("file__")]
    if file_keys:
        file_obj: dict = {}
        for k in file_keys:
            file_obj[k[len("file__"):]] = d.pop(k)
        # Only attach if at least one file column is non-None
        d["file"] = file_obj if any(v is not None for v in file_obj.values()) else None
    return d


async def get_documents(
    user_id: str,
    conn: asyncpg.Connection,
    parent_id: Optional[str] = None,
    workspace_id: Optional[str] = None,
    workspace_app_id: Optional[str] = None,
    workspace_ids: Optional[List[str]] = None,
    include_archived: bool = False,
    favorites_only: bool = False,
    folders_only: bool = False,
    documents_only: bool = False,
    tags: Optional[List[str]] = None,
    sort_by: SortBy = "date",
    sort_direction: SortDirection = "desc",
    fetch_all: bool = False,
) -> List[dict]:
    """
    Get documents for a user.

    Args:
        user_id: User ID
        conn: Authenticated asyncpg connection (RLS already set for this user)
        parent_id: Filter by parent document ID (None for root documents)
        workspace_id: Optional workspace ID to filter by
        workspace_app_id: Optional workspace app ID to filter by
        include_archived: Whether to include archived documents
        favorites_only: Only return favorite documents
        folders_only: Only return folders
        documents_only: Only return documents (not folders)
        tags: Filter by tags (returns docs with ANY of these tags)
        sort_by: Sort field - "name", "type", "date", or "size"
        sort_direction: Sort direction - "asc" or "desc"

    Returns:
        List of documents
    """
    try:
        conditions: List[str] = []
        params: List = []

        def _p(val) -> str:
            params.append(val)
            return f"${len(params)}"

        # Workspace filters
        if workspace_app_id:
            conditions.append(f"d.workspace_app_id = {_p(workspace_app_id)}")
        elif workspace_ids:
            conditions.append(f"d.workspace_id = ANY({_p(workspace_ids)}::uuid[])")
        elif workspace_id:
            conditions.append(f"d.workspace_id = {_p(workspace_id)}")

        # Parent filter
        if not fetch_all:
            if parent_id is not None:
                conditions.append(f"d.parent_id = {_p(parent_id)}")
            else:
                conditions.append("d.parent_id IS NULL")

        # Archived filter
        if not include_archived:
            conditions.append("d.is_archived = FALSE")

        # Favorites filter
        if favorites_only:
            conditions.append("d.is_favorite = TRUE")

        # Type filters
        if folders_only:
            conditions.append("d.is_folder = TRUE")
        elif documents_only:
            conditions.append("d.is_folder = FALSE")

        # Tags filter (overlap — doc has ANY of these tags)
        if tags:
            conditions.append(f"d.tags && {_p(tags)}::text[]")

        where_clause = ("WHERE " + " AND ".join(conditions)) if conditions else ""

        # Sort column map
        sort_column_map = {
            "name": "d.title",
            "type": "d.type",
            "date": "d.updated_at",
            "size": "d.updated_at",  # size sorting handled in Python after fetch
            "position": "d.position",
        }
        sort_col = sort_column_map.get(sort_by, "d.updated_at")
        direction = "DESC" if sort_direction == "desc" else "ASC"
        is_desc = sort_direction == "desc"

        sql = f"""
            SELECT
                d.*,
                f.id          AS file__id,
                f.user_id     AS file__user_id,
                f.workspace_id AS file__workspace_id,
                f.workspace_app_id AS file__workspace_app_id,
                f.filename    AS file__filename,
                f.file_type   AS file__file_type,
                f.file_size   AS file__file_size,
                f.r2_key      AS file__r2_key,
                f.status      AS file__status,
                f.created_at  AS file__created_at,
                f.uploaded_at AS file__uploaded_at
            FROM documents d
            LEFT JOIN files f ON f.id = d.file_id
            {where_clause}
            ORDER BY {sort_col} {direction}
        """

        rows = await conn.fetch(sql, *params)
        documents = [_row_to_doc(r) for r in rows]

        if sort_by == "size":
            def get_file_size(doc: dict) -> int:
                file_data = doc.get("file")
                if file_data and isinstance(file_data, dict):
                    return file_data.get("file_size", 0) or 0
                return 0
            documents.sort(key=get_file_size, reverse=is_desc)

        logger.info(f"Retrieved {len(documents)} documents for user {user_id}")
        _enrich_documents_with_image_urls(documents)
        return documents

    except Exception as e:
        logger.error(f"Error retrieving documents: {str(e)}")
        raise


async def get_document_by_id(user_id: str, conn: asyncpg.Connection, document_id: str) -> Optional[dict]:
    """
    Get a specific document by ID.

    This will return the document if:
    1. User owns the document, OR
    2. Document is shared with the user

    Only updates last_opened_at for owned documents.

    Args:
        user_id: User ID
        conn: Authenticated asyncpg connection (RLS already set for this user)
        document_id: Document ID

    Returns:
        Document record or None if not found/no access
    """
    try:
        row = await conn.fetchrow(
            """
            SELECT
                d.*,
                f.id          AS file__id,
                f.user_id     AS file__user_id,
                f.workspace_id AS file__workspace_id,
                f.workspace_app_id AS file__workspace_app_id,
                f.filename    AS file__filename,
                f.file_type   AS file__file_type,
                f.file_size   AS file__file_size,
                f.r2_key      AS file__r2_key,
                f.status      AS file__status,
                f.created_at  AS file__created_at,
                f.uploaded_at AS file__uploaded_at,
                u.id          AS owner__id,
                u.email       AS owner__email,
                u.name        AS owner__name,
                u.avatar_url  AS owner__avatar_url
            FROM documents d
            LEFT JOIN files f ON f.id = d.file_id
            LEFT JOIN users u ON u.id = d.user_id
            WHERE d.id = $1
            """,
            document_id,
        )

        if row is None:
            # RLS returned nothing — check if document actually exists (admin conn)
            from lib.db import get_admin_db_conn
            async with get_admin_db_conn() as admin_conn:
                exists = await admin_conn.fetchrow(
                    "SELECT id FROM documents WHERE id = $1", document_id
                )
            if exists:
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail="You don't have access to this document",
                )
            return None

        doc = _row_to_doc(row)

        # Reconstruct owner sub-object
        owner_keys = [k for k in doc if k.startswith("owner__")]
        if owner_keys:
            owner_obj: dict = {}
            for k in owner_keys:
                owner_obj[k[len("owner__"):]] = doc.pop(k)
            doc["owner"] = owner_obj if any(v is not None for v in owner_obj.values()) else None

        # Update last_opened_at (best-effort, only for owned documents)
        from datetime import datetime, timezone
        await conn.execute(
            """
            UPDATE documents
            SET last_opened_at = $1
            WHERE id = $2 AND user_id = $3
            """,
            datetime.now(timezone.utc),
            document_id,
            user_id,
        )

        _enrich_documents_with_image_urls([doc])
        return doc

    except Exception as e:
        logger.error(f"Error retrieving document {document_id}: {str(e)}")
        raise


async def assert_document_access(
    user_id: str,
    conn: asyncpg.Connection,
    document_id: str,
) -> None:
    """Raise if the user cannot read the target document row.

    This is the same access contract as ``get_document_by_id`` but without the
    ``last_opened_at`` side effect, so it is safe for authorization-only checks
    such as notification subscription gating.
    """
    try:
        row = await conn.fetchrow(
            "SELECT id FROM documents WHERE id = $1 LIMIT 1",
            document_id,
        )

        if row is not None:
            return

        from lib.db import get_admin_db_conn
        async with get_admin_db_conn() as admin_conn:
            exists = await admin_conn.fetchrow(
                "SELECT id FROM documents WHERE id = $1", document_id
            )
        if exists:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="You don't have access to this document",
            )
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Document not found",
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error checking access for document {document_id}: {str(e)}")
        raise
