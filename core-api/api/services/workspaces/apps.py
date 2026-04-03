"""
Workspace app management
Handles workspace mini-apps (files, messages, projects, etc.).

Uses asyncpg for non-blocking I/O.
"""
from typing import Dict, Any, List, Optional
import logging
import asyncpg

logger = logging.getLogger(__name__)

# Valid app types
VALID_APP_TYPES = (
    "chat",
    "files",
    "messages",
    "dashboard",
    "projects",
    "email",
    "calendar",
    "agents",
)


async def get_workspace_apps(
    workspace_id: str,
    conn: asyncpg.Connection,
) -> List[Dict[str, Any]]:
    """
    Get all apps in a workspace.
    Returns apps the user has access to (public or explicitly added).

    Args:
        workspace_id: Workspace ID
        conn: asyncpg connection

    Returns:
        List of apps with access info
    """
    try:
        rows = await conn.fetch(
            """
            SELECT id, workspace_id, app_type, is_public, position, config, created_at
            FROM workspace_apps
            WHERE workspace_id = $1
            ORDER BY position
            """,
            workspace_id,
        )

        result = [dict(r) for r in rows]
        logger.info(f"Fetched {len(result)} apps for workspace {workspace_id}")
        return result

    except Exception as e:
        logger.exception(f"Error fetching apps for workspace {workspace_id}: {e}")
        raise


async def get_workspace_app(
    workspace_app_id: str,
    conn: asyncpg.Connection,
) -> Optional[Dict[str, Any]]:
    """
    Get a single workspace app by ID.

    Args:
        workspace_app_id: App ID
        conn: asyncpg connection

    Returns:
        App data or None
    """
    try:
        row = await conn.fetchrow(
            "SELECT * FROM workspace_apps WHERE id = $1",
            workspace_app_id,
        )
        return dict(row) if row else None

    except Exception as e:
        logger.exception(f"Error fetching app {workspace_app_id}: {e}")
        raise


async def get_workspace_app_by_type(
    workspace_id: str,
    app_type: str,
    conn: asyncpg.Connection,
) -> Optional[Dict[str, Any]]:
    """
    Get a workspace app by type.

    Args:
        workspace_id: Workspace ID
        app_type: App type (chat, files, messages, dashboard, projects, email, calendar, agents)
        conn: asyncpg connection

    Returns:
        App data or None
    """
    try:
        if app_type not in VALID_APP_TYPES:
            raise ValueError(f"Invalid app type. Must be one of: {VALID_APP_TYPES}")

        row = await conn.fetchrow(
            "SELECT * FROM workspace_apps WHERE workspace_id = $1 AND app_type = $2 LIMIT 1",
            workspace_id,
            app_type,
        )
        return dict(row) if row else None

    except Exception as e:
        logger.exception(f"Error fetching {app_type} app for workspace {workspace_id}: {e}")
        raise


async def update_workspace_app(
    workspace_app_id: str,
    conn: asyncpg.Connection,
    is_public: Optional[bool] = None,
    position: Optional[int] = None,
    config: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """
    Update a workspace app's settings.
    RLS ensures only admins/owners can update.

    Args:
        workspace_app_id: App ID
        conn: asyncpg connection
        is_public: Whether app is visible to all workspace members
        position: Display order position
        config: App-specific configuration JSON

    Returns:
        Updated app data
    """
    try:
        update_data: Dict[str, Any] = {}
        if is_public is not None:
            update_data["is_public"] = is_public
        if position is not None:
            update_data["position"] = position
        if config is not None:
            update_data["config"] = config

        if not update_data:
            # Nothing to update, just fetch current data
            row = await conn.fetchrow(
                "SELECT * FROM workspace_apps WHERE id = $1",
                workspace_app_id,
            )
            return dict(row)

        set_clauses = []
        values = []
        for i, (col, val) in enumerate(update_data.items(), start=1):
            set_clauses.append(f"{col} = ${i}")
            values.append(val)
        values.append(workspace_app_id)
        set_sql = ", ".join(set_clauses)

        row = await conn.fetchrow(
            f"UPDATE workspace_apps SET {set_sql} WHERE id = ${len(values)} RETURNING *",
            *values,
        )

        if not row:
            raise ValueError("App not found or not authorized to update")

        logger.info(f"Updated workspace app {workspace_app_id}")
        return dict(row)

    except Exception as e:
        logger.exception(f"Error updating workspace app {workspace_app_id}: {e}")
        raise


async def add_app_member(
    workspace_app_id: str,
    conn: asyncpg.Connection,
    member_user_id: str,
    added_by_user_id: str,
) -> Dict[str, Any]:
    """
    Add a user to a private app.
    RLS ensures only admins/owners can add members.

    Args:
        workspace_app_id: App ID
        conn: asyncpg connection
        member_user_id: ID of user to add
        added_by_user_id: ID of user adding the member

    Returns:
        Created app membership data

    Raises:
        ValueError: If user is already a member
    """
    try:
        # Check if user is already a member
        existing = await conn.fetchrow(
            "SELECT id FROM workspace_app_members WHERE workspace_app_id = $1 AND user_id = $2",
            workspace_app_id,
            member_user_id,
        )

        if existing:
            raise ValueError("User already has access to this app")

        # Add member
        row = await conn.fetchrow(
            """
            INSERT INTO workspace_app_members (workspace_app_id, user_id, added_by)
            VALUES ($1, $2, $3)
            RETURNING *
            """,
            workspace_app_id,
            member_user_id,
            added_by_user_id,
        )

        if not row:
            raise Exception("Failed to add app member - not authorized")

        logger.info(f"Added user {member_user_id} to app {workspace_app_id}")
        return dict(row)

    except Exception as e:
        logger.exception(f"Error adding member to app {workspace_app_id}: {e}")
        raise


async def remove_app_member(
    workspace_app_id: str,
    conn: asyncpg.Connection,
    member_user_id: str,
) -> bool:
    """
    Remove a user from a private app.
    RLS ensures only admins/owners can remove members.

    Args:
        workspace_app_id: App ID
        conn: asyncpg connection
        member_user_id: ID of member to remove

    Returns:
        True if removed successfully

    Raises:
        ValueError: If member not found
    """
    try:
        # Check if member exists
        existing = await conn.fetchrow(
            "SELECT id FROM workspace_app_members WHERE workspace_app_id = $1 AND user_id = $2",
            workspace_app_id,
            member_user_id,
        )

        if not existing:
            raise ValueError("User does not have explicit access to this app")

        # Remove member
        result = await conn.execute(
            "DELETE FROM workspace_app_members WHERE workspace_app_id = $1 AND user_id = $2",
            workspace_app_id,
            member_user_id,
        )

        if result == "DELETE 0":
            raise ValueError("Failed to remove member - not authorized")

        logger.info(f"Removed user {member_user_id} from app {workspace_app_id}")
        return True

    except Exception as e:
        logger.exception(f"Error removing member from app {workspace_app_id}: {e}")
        raise


async def create_workspace_app(
    workspace_id: str,
    app_type: str,
    conn: asyncpg.Connection,
    is_public: bool = True,
    position: Optional[int] = None,
) -> Dict[str, Any]:
    """
    Create a new app in a workspace.
    RLS ensures only admins/owners can create apps.

    Args:
        workspace_id: Workspace ID
        app_type: App type (chat, files, messages, dashboard, projects, email, calendar, agents)
        conn: asyncpg connection
        is_public: Whether app is visible to all workspace members
        position: Display order position (defaults to end)

    Returns:
        Created app data

    Raises:
        ValueError: If app type is invalid or already exists
    """
    if app_type not in VALID_APP_TYPES:
        raise ValueError(f"Invalid app type. Must be one of: {VALID_APP_TYPES}")

    try:
        # Check if app already exists
        existing = await conn.fetchrow(
            "SELECT id FROM workspace_apps WHERE workspace_id = $1 AND app_type = $2",
            workspace_id,
            app_type,
        )

        if existing:
            raise ValueError(f"App type '{app_type}' already exists in this workspace")
    except ValueError:
        raise
    except Exception as e:
        logger.exception(f"Error checking existing app: {e}")
        raise ValueError(f"Failed to check existing apps: {str(e)}")

    try:
        # Get max position if not specified
        if position is None:
            max_pos = await conn.fetchval(
                "SELECT MAX(position) FROM workspace_apps WHERE workspace_id = $1",
                workspace_id,
            )
            position = (max_pos + 1) if max_pos is not None else 0
    except Exception as e:
        logger.exception(f"Error getting max position: {e}")
        position = 0  # Default to 0 if we can't get max

    try:
        # Create app
        logger.info(f"Creating app: workspace_id={workspace_id}, app_type={app_type}, is_public={is_public}, position={position}")
        row = await conn.fetchrow(
            """
            INSERT INTO workspace_apps (workspace_id, app_type, is_public, position)
            VALUES ($1, $2, $3, $4)
            RETURNING *
            """,
            workspace_id,
            app_type,
            is_public,
            position,
        )

        if not row:
            raise ValueError("Failed to create app - RLS policy may have blocked the insert")

        logger.info(f"Created {app_type} app in workspace {workspace_id}")
        return dict(row)

    except ValueError:
        raise
    except Exception as e:
        logger.exception(f"Error inserting app: {e}")
        raise ValueError(f"Failed to create app: {str(e)}")


async def delete_workspace_app(
    workspace_app_id: str,
    conn: asyncpg.Connection,
) -> bool:
    """
    Delete a workspace app.
    RLS ensures only admins/owners can delete apps.

    Args:
        workspace_app_id: App ID
        conn: asyncpg connection

    Returns:
        True if deleted successfully

    Raises:
        ValueError: If app not found
    """
    try:
        # Delete app (this will cascade delete app members)
        result = await conn.execute(
            "DELETE FROM workspace_apps WHERE id = $1",
            workspace_app_id,
        )

        if result == "DELETE 0":
            raise ValueError("App not found or not authorized to delete")

        logger.info(f"Deleted workspace app {workspace_app_id}")
        return True

    except Exception as e:
        logger.exception(f"Error deleting workspace app {workspace_app_id}: {e}")
        raise


async def get_app_members(
    workspace_app_id: str,
    conn: asyncpg.Connection,
) -> List[Dict[str, Any]]:
    """
    Get all members with explicit access to a private app.

    Args:
        workspace_app_id: App ID
        conn: asyncpg connection

    Returns:
        List of app members
    """
    try:
        rows = await conn.fetch(
            """
            SELECT id, user_id, added_by, added_at
            FROM workspace_app_members
            WHERE workspace_app_id = $1
            ORDER BY added_at
            """,
            workspace_app_id,
        )
        return [dict(r) for r in rows]

    except Exception as e:
        logger.exception(f"Error fetching members for app {workspace_app_id}: {e}")
        raise


async def reorder_workspace_apps(
    workspace_id: str,
    conn: asyncpg.Connection,
    app_positions: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """
    Reorder workspace apps by updating their positions using RPC function.
    All updates happen atomically in a single database transaction.

    Args:
        workspace_id: Workspace ID
        conn: asyncpg connection
        app_positions: List of dicts with 'id' and 'position' keys
                       e.g., [{"id": "uuid1", "position": 0}, {"id": "uuid2", "position": 1}]

    Returns:
        Dict with success message and count of updated apps
    """
    try:
        # Use RPC function for atomic batch update
        import json as _json
        updated_count = await conn.fetchval(
            "SELECT reorder_workspace_apps($1, $2)",
            workspace_id,
            _json.dumps(app_positions),
        )

        updated_count = updated_count if updated_count is not None else 0

        logger.info(f"Reordered {updated_count} apps in workspace {workspace_id}")

        return {
            "message": "Apps reordered successfully",
            "updated_count": updated_count,
        }

    except Exception as e:
        # Fallback to individual updates if RPC function doesn't exist yet
        if "function reorder_workspace_apps" in str(e).lower() or "does not exist" in str(e).lower():
            logger.warning("RPC function not available, falling back to individual updates")
            return await _reorder_apps_fallback(workspace_id, app_positions, conn)

        logger.exception(f"Error reordering apps in workspace {workspace_id}: {e}")
        raise


async def _reorder_apps_fallback(
    workspace_id: str,
    app_positions: List[Dict[str, Any]],
    conn: asyncpg.Connection,
) -> Dict[str, Any]:
    """
    Fallback method for reordering when RPC function is not available.
    Uses sequential per-app updates (not atomic).
    """
    updated_count = 0
    for item in app_positions:
        app_id = item.get("id")
        position = item.get("position")
        if app_id is not None and position is not None:
            result = await conn.execute(
                "UPDATE workspace_apps SET position = $1 WHERE id = $2 AND workspace_id = $3",
                position,
                app_id,
                workspace_id,
            )
            if result != "UPDATE 0":
                updated_count += 1

    return {
        "message": "Apps reordered successfully",
        "updated_count": updated_count,
    }
