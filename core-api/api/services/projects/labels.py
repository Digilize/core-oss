"""
Label service - CRUD operations for project board labels and issue-label assignments.

Uses asyncpg for non-blocking I/O.
"""
from typing import Dict, Any, List, Optional
import logging
import asyncpg

logger = logging.getLogger(__name__)


async def get_labels(
    conn: asyncpg.Connection,
    board_id: str,
) -> List[Dict[str, Any]]:
    """
    Get all labels for a board, ordered by name.

    Args:
        conn: asyncpg connection
        board_id: Board UUID

    Returns:
        List of label dicts
    """
    rows = await conn.fetch(
        "SELECT * FROM project_labels WHERE board_id = $1 ORDER BY name",
        board_id,
    )
    return [dict(r) for r in rows]


async def create_label(
    conn: asyncpg.Connection,
    user_id: str,
    board_id: str,
    name: str,
    color: str = '#6B7280',
) -> Dict[str, Any]:
    """
    Create a label definition on a board.

    Args:
        conn: asyncpg connection
        user_id: Creator's user ID
        board_id: Board UUID
        name: Label name
        color: Label color hex string

    Returns:
        Created label dict
    """
    # Look up board context
    board_row = await conn.fetchrow(
        "SELECT workspace_app_id, workspace_id FROM project_boards WHERE id = $1",
        board_id,
    )
    if not board_row:
        raise ValueError(f"Board not found: {board_id}")

    row = await conn.fetchrow(
        """
        INSERT INTO project_labels
            (workspace_app_id, workspace_id, board_id, name, color, created_by)
        VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING *
        """,
        board_row["workspace_app_id"],
        board_row["workspace_id"],
        board_id,
        name,
        color,
        user_id,
    )

    logger.info(f"Created label '{name}' on board {board_id}")
    return dict(row)


async def update_label(
    conn: asyncpg.Connection,
    label_id: str,
    name: Optional[str] = None,
    color: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Update a label's name and/or color.

    Args:
        conn: asyncpg connection
        label_id: Label UUID
        name: New name (optional)
        color: New color (optional)

    Returns:
        Updated label dict
    """
    updates: Dict[str, Any] = {}
    if name is not None:
        updates["name"] = name
    if color is not None:
        updates["color"] = color

    if not updates:
        row = await conn.fetchrow(
            "SELECT * FROM project_labels WHERE id = $1",
            label_id,
        )
        if not row:
            raise ValueError(f"Label not found: {label_id}")
        return dict(row)

    set_parts = []
    values = []
    for i, (col, val) in enumerate(updates.items(), start=1):
        set_parts.append(f"{col} = ${i}")
        values.append(val)
    values.append(label_id)

    row = await conn.fetchrow(
        f"UPDATE project_labels SET {', '.join(set_parts)} WHERE id = ${len(values)} RETURNING *",
        *values,
    )

    if not row:
        raise ValueError(f"Label not found: {label_id}")

    return dict(row)


async def delete_label(
    conn: asyncpg.Connection,
    label_id: str,
) -> Dict[str, Any]:
    """
    Delete a label. Cascades to remove from all issues.

    Args:
        conn: asyncpg connection
        label_id: Label UUID

    Returns:
        Status dict
    """
    await conn.execute(
        "DELETE FROM project_labels WHERE id = $1",
        label_id,
    )

    logger.info(f"Deleted label {label_id}")
    return {"status": "deleted", "label_id": label_id}


async def get_issue_labels(
    conn: asyncpg.Connection,
    issue_id: str,
) -> List[Dict[str, Any]]:
    """
    Get all labels attached to an issue.

    Args:
        conn: asyncpg connection
        issue_id: Issue UUID

    Returns:
        List of label dicts (from project_labels via junction)
    """
    rows = await conn.fetch(
        """
        SELECT pl.*
        FROM project_issue_labels pil
        JOIN project_labels pl ON pl.id = pil.label_id
        WHERE pil.issue_id = $1
        """,
        issue_id,
    )
    return [dict(r) for r in rows]


async def add_label_to_issue(
    conn: asyncpg.Connection,
    issue_id: str,
    label_id: str,
) -> Dict[str, Any]:
    """
    Add a label to an issue.

    Args:
        conn: asyncpg connection
        issue_id: Issue UUID
        label_id: Label UUID

    Returns:
        Created junction row
    """
    # Look up issue context
    issue_row = await conn.fetchrow(
        "SELECT workspace_app_id, workspace_id FROM project_issues WHERE id = $1",
        issue_id,
    )
    if not issue_row:
        raise ValueError(f"Issue not found: {issue_id}")

    row = await conn.fetchrow(
        """
        INSERT INTO project_issue_labels
            (workspace_app_id, workspace_id, issue_id, label_id)
        VALUES ($1, $2, $3, $4)
        RETURNING *
        """,
        issue_row["workspace_app_id"],
        issue_row["workspace_id"],
        issue_id,
        label_id,
    )

    logger.info(f"Added label {label_id} to issue {issue_id}")
    return dict(row)


async def remove_label_from_issue(
    conn: asyncpg.Connection,
    issue_id: str,
    label_id: str,
) -> Dict[str, Any]:
    """
    Remove a label from an issue.

    Args:
        conn: asyncpg connection
        issue_id: Issue UUID
        label_id: Label UUID

    Returns:
        Status dict
    """
    await conn.execute(
        "DELETE FROM project_issue_labels WHERE issue_id = $1 AND label_id = $2",
        issue_id,
        label_id,
    )

    logger.info(f"Removed label {label_id} from issue {issue_id}")
    return {"status": "removed", "issue_id": issue_id, "label_id": label_id}
