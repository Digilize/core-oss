"""
Assignee service - operations for project issue multi-assignee management.

Uses asyncpg for non-blocking I/O.
"""
from typing import Dict, Any, List, Optional
import logging
import asyncpg
from api.services.notifications.subscriptions import subscribe
from api.services.notifications.create import create_notification, NotificationType
from api.services.notifications.helpers import get_actor_info

logger = logging.getLogger(__name__)


async def get_issue_assignees(
    conn: asyncpg.Connection,
    issue_id: str,
) -> List[Dict[str, Any]]:
    """
    Get all assignees for an issue.

    Args:
        conn: asyncpg connection
        issue_id: Issue UUID

    Returns:
        List of assignee dicts with user_id and created_at
    """
    rows = await conn.fetch(
        "SELECT * FROM project_issue_assignees WHERE issue_id = $1 ORDER BY created_at",
        issue_id,
    )
    return [dict(r) for r in rows]


async def add_assignee(
    conn: asyncpg.Connection,
    issue_id: str,
    user_id: str,
    current_user_id: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Add an assignee to an issue. DB trigger enforces max 10.

    Args:
        conn: asyncpg connection
        issue_id: Issue UUID
        user_id: User UUID to assign
        current_user_id: Who is performing the action (for notifications)

    Returns:
        Created assignee row
    """
    # Look up issue context
    issue_row = await conn.fetchrow(
        "SELECT workspace_app_id, workspace_id, title, board_id FROM project_issues WHERE id = $1",
        issue_id,
    )
    if not issue_row:
        raise ValueError(f"Issue not found: {issue_id}")
    issue = dict(issue_row)

    row = await conn.fetchrow(
        """
        INSERT INTO project_issue_assignees
            (workspace_app_id, workspace_id, issue_id, user_id)
        VALUES ($1, $2, $3, $4)
        RETURNING *
        """,
        issue["workspace_app_id"],
        issue["workspace_id"],
        issue_id,
        user_id,
    )

    logger.info(f"Added assignee {user_id} to issue {issue_id}")

    # Auto-subscribe assignee and notify
    try:
        await subscribe(user_id=user_id, resource_type="issue", resource_id=issue_id, reason="assignee")

        if current_user_id and current_user_id != user_id:
            actor = await get_actor_info(current_user_id)
            await create_notification(
                recipients=[user_id],
                type=NotificationType.TASK_ASSIGNED,
                title=f"{actor['actor_name']} assigned you to: {issue['title']}",
                resource_type="issue",
                resource_id=issue_id,
                actor_id=current_user_id,
                workspace_id=issue["workspace_id"],
                data={
                    "board_id": issue["board_id"],
                    "issue_title": issue["title"],
                    **actor,
                },
            )
    except Exception as e:
        logger.warning(f"Notification failed for assignee add: {e}")

    return dict(row)


async def remove_assignee(
    conn: asyncpg.Connection,
    issue_id: str,
    user_id: str,
) -> Dict[str, Any]:
    """
    Remove an assignee from an issue.

    Args:
        conn: asyncpg connection
        issue_id: Issue UUID
        user_id: User UUID to remove

    Returns:
        Status dict
    """
    await conn.execute(
        "DELETE FROM project_issue_assignees WHERE issue_id = $1 AND user_id = $2",
        issue_id,
        user_id,
    )

    logger.info(f"Removed assignee {user_id} from issue {issue_id}")
    return {"status": "removed", "issue_id": issue_id, "user_id": user_id}
