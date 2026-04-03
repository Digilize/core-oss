"""
Comment service - CRUD operations for project issue comments.

Provides GitHub-style flat, chronological comments on issues with reactions.
"""
from typing import Dict, Any, List
import logging
import asyncpg
from api.services.notifications.subscriptions import subscribe
from api.services.notifications.create import notify_subscribers, NotificationType
from api.services.notifications.helpers import get_actor_info

logger = logging.getLogger(__name__)


def extract_plain_text(blocks: List[Dict[str, Any]]) -> str:
    """
    Extract plain text content from blocks for search indexing.

    Args:
        blocks: Array of content blocks

    Returns:
        Plain text string
    """
    text_parts = []

    for block in blocks:
        block_type = block.get("type")
        data = block.get("data", {})

        if block_type == "text":
            text_parts.append(data.get("content", ""))
        elif block_type == "mention":
            text_parts.append(f"@{data.get('display_name', '')}")
        elif block_type == "code":
            text_parts.append(data.get("content", ""))
        elif block_type == "quote":
            text_parts.append(data.get("preview", ""))

    return " ".join(text_parts).strip()


async def get_comments(
    conn: asyncpg.Connection,
    issue_id: str,
    limit: int = 100,
    offset: int = 0,
) -> Dict[str, Any]:
    """
    Get comments for an issue, ordered chronologically.

    Args:
        conn: asyncpg connection
        issue_id: Issue UUID
        limit: Max comments to return
        offset: Pagination offset

    Returns:
        Dict with comments list, page_count, and total_count
    """
    # Get total count first
    count_row = await conn.fetchrow(
        "SELECT COUNT(*) AS cnt FROM project_issue_comments WHERE issue_id = $1",
        issue_id,
    )
    total_count = count_row["cnt"] if count_row else 0

    # Get comments with user info via JOIN
    rows = await conn.fetch(
        """
        SELECT
            c.*,
            u.id AS user__id,
            u.email AS user__email,
            u.name AS user__name,
            u.avatar_url AS user__avatar_url
        FROM project_issue_comments c
        LEFT JOIN users u ON u.id = c.user_id
        WHERE c.issue_id = $1
        ORDER BY c.created_at
        LIMIT $2 OFFSET $3
        """,
        issue_id,
        limit,
        offset,
    )

    comments = []
    comment_ids = []
    for row in rows:
        d = dict(row)
        # Reconstruct nested user object
        d["user"] = {
            "id": d.pop("user__id"),
            "email": d.pop("user__email"),
            "name": d.pop("user__name"),
            "avatar_url": d.pop("user__avatar_url"),
        }
        comments.append(d)
        comment_ids.append(d["id"])

    # Get reactions for all comments in one query
    if comments:
        reaction_rows = await conn.fetch(
            "SELECT * FROM project_comment_reactions WHERE comment_id = ANY($1)",
            comment_ids,
        )

        # Build reaction lookup by comment_id
        reactions_by_comment: Dict[str, List[Dict[str, Any]]] = {}
        for reaction in reaction_rows:
            r = dict(reaction)
            reactions_by_comment.setdefault(r["comment_id"], []).append(r)

        # Attach reactions to comments
        for comment in comments:
            comment["reactions"] = reactions_by_comment.get(comment["id"], [])

    return {
        "comments": comments,
        "count": len(comments),  # Page count
        "total_count": total_count,  # Total comments for this issue
    }


async def create_comment(
    user_id: str,
    conn: asyncpg.Connection,
    issue_id: str,
    blocks: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """
    Create a new comment on an issue.

    Args:
        user_id: Current user's UUID
        conn: asyncpg connection
        issue_id: Issue UUID
        blocks: Content blocks

    Returns:
        Created comment dict with user info
    """
    import json

    # Get issue to obtain workspace_app_id, workspace_id, and title
    issue_row = await conn.fetchrow(
        "SELECT workspace_app_id, workspace_id, title, board_id FROM project_issues WHERE id = $1",
        issue_id,
    )

    if not issue_row:
        raise ValueError(f"Issue not found: {issue_id}")
    issue = dict(issue_row)

    # Extract plain text for search
    content = extract_plain_text(blocks)

    # Create comment
    comment_row = await conn.fetchrow(
        """
        INSERT INTO project_issue_comments
            (workspace_app_id, workspace_id, issue_id, user_id, content, blocks)
        VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING *
        """,
        issue["workspace_app_id"],
        issue["workspace_id"],
        issue_id,
        user_id,
        content,
        json.dumps(blocks),
    )

    if not comment_row:
        raise ValueError("Failed to create comment")

    # Fetch with user info
    full_row = await conn.fetchrow(
        """
        SELECT
            c.*,
            u.id AS user__id,
            u.email AS user__email,
            u.name AS user__name,
            u.avatar_url AS user__avatar_url
        FROM project_issue_comments c
        LEFT JOIN users u ON u.id = c.user_id
        WHERE c.id = $1
        """,
        comment_row["id"],
    )

    comment = dict(full_row)
    comment["user"] = {
        "id": comment.pop("user__id"),
        "email": comment.pop("user__email"),
        "name": comment.pop("user__name"),
        "avatar_url": comment.pop("user__avatar_url"),
    }
    comment["reactions"] = []

    # Auto-subscribe commenter and notify subscribers
    try:
        await subscribe(user_id=user_id, resource_type="issue", resource_id=issue_id, reason="commenter")

        actor = await get_actor_info(user_id)
        comment_preview = (content[:100] + "...") if len(content) > 100 else content
        await notify_subscribers(
            resource_type="issue",
            resource_id=issue_id,
            type=NotificationType.COMMENT_ADDED,
            title=f"{actor['actor_name']} commented on: {issue['title']}",
            body=comment_preview if comment_preview else None,
            actor_id=user_id,
            workspace_id=issue["workspace_id"],
            data={
                "board_id": issue.get("board_id"),
                "issue_title": issue["title"],
                "comment_preview": comment_preview,
                **actor,
            },
        )
    except Exception as e:
        logger.warning(f"Notification failed for comment create: {e}")

    return comment


async def update_comment(
    conn: asyncpg.Connection,
    comment_id: str,
    blocks: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """
    Update a comment's content (author only via RLS).

    Args:
        conn: asyncpg connection
        comment_id: Comment UUID
        blocks: New content blocks

    Returns:
        Updated comment dict
    """
    import json

    # Extract plain text for search
    content = extract_plain_text(blocks)

    # Update comment
    updated_row = await conn.fetchrow(
        """
        UPDATE project_issue_comments
        SET content = $1, blocks = $2, is_edited = TRUE, edited_at = NOW()
        WHERE id = $3
        RETURNING *
        """,
        content,
        json.dumps(blocks),
        comment_id,
    )

    if not updated_row:
        raise ValueError(f"Comment not found or unauthorized: {comment_id}")

    # Fetch with user info
    full_row = await conn.fetchrow(
        """
        SELECT
            c.*,
            u.id AS user__id,
            u.email AS user__email,
            u.name AS user__name,
            u.avatar_url AS user__avatar_url
        FROM project_issue_comments c
        LEFT JOIN users u ON u.id = c.user_id
        WHERE c.id = $1
        """,
        comment_id,
    )

    comment = dict(full_row)
    comment["user"] = {
        "id": comment.pop("user__id"),
        "email": comment.pop("user__email"),
        "name": comment.pop("user__name"),
        "avatar_url": comment.pop("user__avatar_url"),
    }

    # Get reactions (separate query)
    reaction_rows = await conn.fetch(
        "SELECT * FROM project_comment_reactions WHERE comment_id = $1",
        comment_id,
    )
    comment["reactions"] = [dict(r) for r in reaction_rows]

    return comment


async def delete_comment(
    conn: asyncpg.Connection,
    comment_id: str,
) -> Dict[str, Any]:
    """
    Delete a comment (author or admin only via RLS).

    Args:
        conn: asyncpg connection
        comment_id: Comment UUID

    Returns:
        Status dict

    Raises:
        ValueError: If comment not found or unauthorized
    """
    # Delete directly and check result - avoids pre-check blocking admin deletes
    result = await conn.execute(
        "DELETE FROM project_issue_comments WHERE id = $1",
        comment_id,
    )

    # If nothing was deleted, the comment didn't exist or user wasn't authorized
    if result == "DELETE 0":
        raise ValueError(f"Comment not found or unauthorized: {comment_id}")

    return {"status": "deleted"}


async def add_reaction(
    user_id: str,
    conn: asyncpg.Connection,
    comment_id: str,
    emoji: str,
) -> Dict[str, Any]:
    """
    Add a reaction to a comment.

    Args:
        user_id: Current user's UUID
        conn: asyncpg connection
        comment_id: Comment UUID
        emoji: Emoji string

    Returns:
        Created reaction dict
    """
    # Get comment to obtain workspace_app_id and workspace_id
    comment_row = await conn.fetchrow(
        "SELECT workspace_app_id, workspace_id FROM project_issue_comments WHERE id = $1",
        comment_id,
    )

    if not comment_row:
        raise ValueError(f"Comment not found: {comment_id}")

    # Create reaction
    row = await conn.fetchrow(
        """
        INSERT INTO project_comment_reactions
            (workspace_app_id, workspace_id, comment_id, user_id, emoji)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING *
        """,
        comment_row["workspace_app_id"],
        comment_row["workspace_id"],
        comment_id,
        user_id,
        emoji,
    )

    return dict(row) if row else {}


async def remove_reaction(
    user_id: str,
    conn: asyncpg.Connection,
    comment_id: str,
    emoji: str,
) -> bool:
    """
    Remove a reaction from a comment (own reaction only).

    Args:
        user_id: Current user's UUID
        conn: asyncpg connection
        comment_id: Comment UUID
        emoji: Emoji string to remove

    Returns:
        True if successful
    """
    # Explicit user_id filter for defense-in-depth (RLS also enforces this)
    await conn.execute(
        "DELETE FROM project_comment_reactions WHERE comment_id = $1 AND emoji = $2 AND user_id = $3",
        comment_id,
        emoji,
        user_id,
    )

    return True
