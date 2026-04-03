"""
Reorder documents service.
Uses RPC function for atomic batch updates in a single transaction,
avoiding N individual UPDATE statements that each trigger a Realtime event.
"""
import asyncio
import logging
from typing import Any, Dict, List

import asyncpg

logger = logging.getLogger(__name__)


async def reorder_documents(
    user_id: str, conn: asyncpg.Connection, document_positions: List[Dict[str, Any]]
) -> List[dict]:
    """
    Reorder multiple documents at once using RPC for atomicity.

    Args:
        user_id: ID of the user performing the reorder
        conn: Authenticated asyncpg connection (RLS already set for this user)
        document_positions: List of {"id": document_id, "position": new_position}

    Returns:
        Updated document records for compatibility with existing clients
    """
    document_ids = [item.get("id") for item in document_positions if item.get("id")]
    if not document_ids:
        return []

    try:
        import json
        result_row = await conn.fetchrow(
            "SELECT reorder_documents($1::jsonb) AS updated_count",
            json.dumps(document_positions),
        )
        updated_count = result_row["updated_count"] if result_row else 0
        logger.info(f"Reordered {updated_count} documents for user {user_id} via RPC")

    except Exception as e:
        error_msg = str(e).lower()
        if "function reorder_documents" in error_msg or "does not exist" in error_msg:
            logger.warning(
                "RPC reorder_documents not available, falling back to individual updates"
            )
            updated_count = await _reorder_documents_fallback(
                user_id, conn, document_positions
            )
            logger.info(f"Reordered {updated_count} documents for user {user_id} (fallback)")
        else:
            logger.exception(f"Error reordering documents for user {user_id}: {e}")
            raise

    documents = await _fetch_documents_by_ids(conn, document_ids)
    logger.info(
        f"Returning {len(documents)} reordered document records for user {user_id}"
    )
    return documents


async def _reorder_documents_fallback(
    user_id: str,
    conn: asyncpg.Connection,
    document_positions: List[Dict[str, Any]],
) -> int:
    """Fallback: update positions individually in parallel (non-atomic)."""

    async def update_one(item: Dict[str, Any]) -> bool:
        doc_id = item.get("id")
        position = item.get("position")
        if doc_id is None or position is None:
            return False
        row = await conn.fetchrow(
            "UPDATE documents SET position = $1 WHERE id = $2 RETURNING id",
            position,
            doc_id,
        )
        return row is not None

    results = await asyncio.gather(*[update_one(item) for item in document_positions])
    updated_count = sum(1 for r in results if r)

    logger.info(f"Reordered {updated_count} documents (fallback) for user {user_id}")
    return updated_count


async def _fetch_documents_by_ids(
    conn: asyncpg.Connection,
    document_ids: List[str],
) -> List[dict]:
    """Fetch reordered documents and preserve request order."""
    from api.services.documents.get_documents import _row_to_doc

    rows = await conn.fetch(
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
            f.uploaded_at AS file__uploaded_at
        FROM documents d
        LEFT JOIN files f ON f.id = d.file_id
        WHERE d.id = ANY($1::uuid[])
        """,
        document_ids,
    )
    documents = [_row_to_doc(r) for r in rows]
    index_map = {doc_id: idx for idx, doc_id in enumerate(document_ids)}
    documents.sort(key=lambda doc: index_map.get(str(doc.get("id")), len(index_map)))
    return documents
