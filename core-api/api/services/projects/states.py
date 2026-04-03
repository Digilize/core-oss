"""
State service - CRUD operations for project board states/columns.

Uses asyncpg for non-blocking I/O.
"""
from typing import Dict, Any, List, Optional
import logging
import asyncpg

logger = logging.getLogger(__name__)


async def get_states(
    conn: asyncpg.Connection,
    board_id: str,
) -> List[Dict[str, Any]]:
    """
    Get all states for a board, ordered by position.

    Args:
        conn: asyncpg connection
        board_id: Board UUID

    Returns:
        List of state dicts
    """
    rows = await conn.fetch(
        "SELECT * FROM project_states WHERE board_id = $1 ORDER BY position",
        board_id,
    )
    return [dict(r) for r in rows]


async def create_state(
    conn: asyncpg.Connection,
    board_id: str,
    name: str,
    color: Optional[str] = None,
    is_done: bool = False,
) -> Dict[str, Any]:
    """
    Create a new state in a board.

    Args:
        conn: asyncpg connection
        board_id: Board UUID
        name: State name
        color: Optional color (hex)
        is_done: Whether this state represents completion

    Returns:
        Created state dict
    """
    # Look up board to get workspace context
    board_row = await conn.fetchrow(
        "SELECT workspace_app_id, workspace_id FROM project_boards WHERE id = $1",
        board_id,
    )
    if not board_row:
        raise ValueError(f"Board not found: {board_id}")

    # Get next position
    position = await _get_next_state_position(conn, board_id)

    row = await conn.fetchrow(
        """
        INSERT INTO project_states
            (workspace_app_id, workspace_id, board_id, name, color, position, is_done)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        RETURNING *
        """,
        board_row["workspace_app_id"],
        board_row["workspace_id"],
        board_id,
        name,
        color,
        position,
        is_done,
    )

    logger.info(f"Created state '{name}' in board {board_id}")

    return dict(row)


async def update_state(
    conn: asyncpg.Connection,
    state_id: str,
    name: Optional[str] = None,
    color: Optional[str] = None,
    is_done: Optional[bool] = None,
) -> Dict[str, Any]:
    """
    Update a state's fields.

    Args:
        conn: asyncpg connection
        state_id: State UUID
        name: New name (optional)
        color: New color (optional)
        is_done: New is_done flag (optional)

    Returns:
        Updated state dict
    """
    updates: Dict[str, Any] = {}
    if name is not None:
        updates["name"] = name
    if color is not None:
        updates["color"] = color
    if is_done is not None:
        updates["is_done"] = is_done

    if not updates:
        row = await conn.fetchrow(
            "SELECT * FROM project_states WHERE id = $1",
            state_id,
        )
        if not row:
            raise ValueError(f"State not found: {state_id}")
        return dict(row)

    set_parts = []
    values = []
    for i, (col, val) in enumerate(updates.items(), start=1):
        set_parts.append(f"{col} = ${i}")
        values.append(val)
    values.append(state_id)

    row = await conn.fetchrow(
        f"UPDATE project_states SET {', '.join(set_parts)} WHERE id = ${len(values)} RETURNING *",
        *values,
    )

    if not row:
        raise ValueError(f"State not found: {state_id}")

    return dict(row)


async def delete_state(
    conn: asyncpg.Connection,
    state_id: str,
) -> Dict[str, Any]:
    """
    Delete a state. Will fail if issues still reference it (RESTRICT).

    Args:
        conn: asyncpg connection
        state_id: State UUID

    Returns:
        Status dict
    """
    await conn.execute(
        "DELETE FROM project_states WHERE id = $1",
        state_id,
    )

    logger.info(f"Deleted state {state_id}")

    return {"status": "deleted", "state_id": state_id}


async def reorder_states(
    conn: asyncpg.Connection,
    board_id: str,
    items: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """
    Reorder states within a board using RPC for atomicity.

    Args:
        conn: asyncpg connection
        board_id: Board UUID
        items: List of {"id": "uuid", "position": int}

    Returns:
        Dict with updated_count
    """
    try:
        import json
        row = await conn.fetchrow(
            "SELECT reorder_project_states($1, $2)",
            board_id,
            json.dumps(items),
        )

        updated_count = row[0] if row and row[0] else 0

        logger.info(f"Reordered {updated_count} states in board {board_id}")

        return {
            "message": "States reordered successfully",
            "updated_count": updated_count,
        }
    except Exception as e:
        if "does not exist" in str(e).lower():
            logger.warning("RPC reorder_project_states not available, using fallback")
            return await _reorder_states_fallback(conn, board_id, items)
        raise


async def _get_next_state_position(
    conn: asyncpg.Connection,
    board_id: str,
) -> int:
    """Get the next position for a new state in the board."""
    row = await conn.fetchrow(
        "SELECT position FROM project_states WHERE board_id = $1 ORDER BY position DESC LIMIT 1",
        board_id,
    )
    if row:
        return row["position"] + 1
    return 0


async def _reorder_states_fallback(
    conn: asyncpg.Connection,
    board_id: str,
    items: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """Fallback: update positions individually (non-atomic)."""
    import asyncio

    async def update_one(item: Dict[str, Any]) -> bool:
        result = await conn.execute(
            "UPDATE project_states SET position = $1 WHERE id = $2 AND board_id = $3",
            item["position"],
            item["id"],
            board_id,
        )
        return result == "UPDATE 1"

    results = await asyncio.gather(*[update_one(item) for item in items])
    updated_count = sum(1 for r in results if r)

    return {
        "message": "States reordered successfully",
        "updated_count": updated_count,
    }
