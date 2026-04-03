"""
Board service - CRUD operations for project boards.

Uses asyncpg for non-blocking I/O.
"""
from typing import Dict, Any, List, Optional
import logging
import asyncpg

logger = logging.getLogger(__name__)


async def get_boards(
    conn: asyncpg.Connection,
    workspace_app_id: str,
) -> List[Dict[str, Any]]:
    """
    Get all boards for a workspace app, ordered by position.

    Args:
        conn: asyncpg connection
        workspace_app_id: Workspace app ID (projects app)

    Returns:
        List of board dicts
    """
    rows = await conn.fetch(
        "SELECT * FROM project_boards WHERE workspace_app_id = $1 ORDER BY position",
        workspace_app_id,
    )
    return [dict(r) for r in rows]


async def get_board_by_id(
    conn: asyncpg.Connection,
    board_id: str,
) -> Optional[Dict[str, Any]]:
    """
    Get a single board by ID.

    Args:
        conn: asyncpg connection
        board_id: Board UUID

    Returns:
        Board dict or None
    """
    row = await conn.fetchrow(
        "SELECT * FROM project_boards WHERE id = $1",
        board_id,
    )
    return dict(row) if row else None


async def create_board(
    user_id: str,
    conn: asyncpg.Connection,
    workspace_app_id: str,
    name: str,
    description: Optional[str] = None,
    icon: Optional[str] = None,
    color: Optional[str] = None,
    key: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Create a new board with 3 default states (To Do, In Progress, Done).

    Args:
        user_id: Creator's user ID
        conn: asyncpg connection
        workspace_app_id: Workspace app ID (projects app)
        name: Board name
        description: Optional board description
        icon: Optional board icon (emoji)
        color: Optional board color (hex)
        key: Optional short code (e.g. "CORE")

    Returns:
        Dict with board and states data
    """
    # Look up workspace_id from workspace_app
    app_row = await conn.fetchrow(
        "SELECT workspace_id FROM workspace_apps WHERE id = $1",
        workspace_app_id,
    )
    if not app_row:
        raise ValueError(f"Workspace app not found: {workspace_app_id}")
    workspace_id = app_row["workspace_id"]

    # Get next position
    position = await _get_next_board_position(conn, workspace_app_id)

    # Insert board
    board = await conn.fetchrow(
        """
        INSERT INTO project_boards
            (workspace_app_id, workspace_id, name, description, icon, color, key, position, created_by)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        RETURNING *
        """,
        workspace_app_id,
        workspace_id,
        name,
        description,
        icon,
        color,
        key,
        position,
        user_id,
    )
    board = dict(board)

    # Create default states
    default_states = [
        {"name": "To Do", "color": "#94A3B8", "position": 0, "is_done": False},
        {"name": "In Progress", "color": "#3B82F6", "position": 1, "is_done": False},
        {"name": "Done", "color": "#10B981", "position": 2, "is_done": True},
    ]

    states = []
    for s in default_states:
        state_row = await conn.fetchrow(
            """
            INSERT INTO project_states
                (workspace_app_id, workspace_id, board_id, name, color, position, is_done)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            RETURNING *
            """,
            workspace_app_id,
            workspace_id,
            board["id"],
            s["name"],
            s["color"],
            s["position"],
            s["is_done"],
        )
        states.append(dict(state_row))

    logger.info(f"Created board '{name}' with 3 default states for workspace app {workspace_app_id}")

    return {
        "board": board,
        "states": states,
    }


async def update_board(
    conn: asyncpg.Connection,
    board_id: str,
    name: Optional[str] = None,
    description: Optional[str] = None,
    icon: Optional[str] = None,
    color: Optional[str] = None,
    key: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Update a board's fields.

    Args:
        conn: asyncpg connection
        board_id: Board UUID
        name: New name (optional)
        description: New description (optional)
        icon: New icon (optional)
        color: New color (optional)
        key: New key (optional)

    Returns:
        Updated board dict
    """
    updates: Dict[str, Any] = {}
    if name is not None:
        updates["name"] = name
    if description is not None:
        updates["description"] = description
    if icon is not None:
        updates["icon"] = icon
    if color is not None:
        updates["color"] = color
    if key is not None:
        updates["key"] = key

    if not updates:
        # Nothing to update, just return current board
        return await get_board_by_id(conn, board_id)  # type: ignore

    # Build SET clause dynamically
    set_parts = []
    values = []
    for i, (col, val) in enumerate(updates.items(), start=1):
        set_parts.append(f"{col} = ${i}")
        values.append(val)
    values.append(board_id)

    row = await conn.fetchrow(
        f"UPDATE project_boards SET {', '.join(set_parts)} WHERE id = ${len(values)} RETURNING *",
        *values,
    )

    if not row:
        raise ValueError(f"Board not found: {board_id}")

    return dict(row)


async def delete_board(
    conn: asyncpg.Connection,
    board_id: str,
) -> Dict[str, Any]:
    """
    Delete a board (cascades to states and issues).

    Args:
        conn: asyncpg connection
        board_id: Board UUID

    Returns:
        Status dict
    """
    await conn.execute(
        "DELETE FROM project_boards WHERE id = $1",
        board_id,
    )

    logger.info(f"Deleted board {board_id}")

    return {"status": "deleted", "board_id": board_id}


async def _get_next_board_position(
    conn: asyncpg.Connection,
    workspace_app_id: str,
) -> int:
    """Get the next position for a new board in the workspace app."""
    row = await conn.fetchrow(
        "SELECT position FROM project_boards WHERE workspace_app_id = $1 ORDER BY position DESC LIMIT 1",
        workspace_app_id,
    )
    if row:
        return row["position"] + 1
    return 0
