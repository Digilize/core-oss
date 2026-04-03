"""
Workspace member management
Handles adding, removing, and updating workspace members.

Uses asyncpg for non-blocking I/O.
"""
from typing import Dict, Any, List, Optional
import logging
import asyncpg
from api.services.users import get_users_by_ids

logger = logging.getLogger(__name__)


async def _enrich_members_with_user_info(members: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Enrich member records with email and name from auth.users.

    Args:
        members: List of member dicts with user_id

    Returns:
        Members with email and name added
    """
    if not members:
        return members

    try:
        # De-duplicate user_ids
        user_ids = list({m.get("user_id") for m in members if m.get("user_id")})

        if not user_ids:
            return members

        # Use the users service to fetch user info
        user_map = await get_users_by_ids(user_ids)

        # Enrich members
        for member in members:
            user_info = user_map.get(member.get("user_id"), {})
            member["email"] = user_info.get("email")
            member["name"] = user_info.get("name")
            member["avatar_url"] = user_info.get("avatar_url")

        return members

    except Exception as e:
        logger.warning(f"Failed to enrich members with user info: {e}")
        # Return members without enrichment on failure
        return members


async def get_workspace_members(
    workspace_id: str,
    conn: asyncpg.Connection,
) -> List[Dict[str, Any]]:
    """
    Get all members of a workspace with their email and name.
    RLS ensures user can only see members if they're also a member.

    Args:
        workspace_id: Workspace ID
        conn: asyncpg connection

    Returns:
        List of members with their roles, email, and name
    """
    try:
        rows = await conn.fetch(
            """
            SELECT id, user_id, role, joined_at
            FROM workspace_members
            WHERE workspace_id = $1
            ORDER BY joined_at
            """,
            workspace_id,
        )

        members = [dict(r) for r in rows]

        # Enrich with email and name
        members = await _enrich_members_with_user_info(members)

        logger.info(f"Fetched {len(members)} members for workspace {workspace_id}")
        return members

    except Exception as e:
        logger.exception(f"Error fetching members for workspace {workspace_id}: {e}")
        raise


async def add_workspace_member(
    workspace_id: str,
    conn: asyncpg.Connection,
    member_user_id: str,
    role: str = "member",
) -> Dict[str, Any]:
    """
    Add a user to a workspace.
    RLS ensures only admins/owners can add members.

    Args:
        workspace_id: Workspace ID
        conn: asyncpg connection
        member_user_id: ID of user to add
        role: Role to assign ('member' or 'admin')

    Returns:
        Created membership data

    Raises:
        ValueError: If role is invalid or user is already a member
    """
    try:
        if role not in ("member", "admin"):
            raise ValueError("Role must be 'member' or 'admin'")

        # Check if user is already a member
        existing = await conn.fetchrow(
            "SELECT id FROM workspace_members WHERE workspace_id = $1 AND user_id = $2 LIMIT 1",
            workspace_id,
            member_user_id,
        )

        if existing:
            raise ValueError("User is already a member of this workspace")

        # Add member
        row = await conn.fetchrow(
            """
            INSERT INTO workspace_members (workspace_id, user_id, role)
            VALUES ($1, $2, $3)
            RETURNING *
            """,
            workspace_id,
            member_user_id,
            role,
        )

        if not row:
            raise Exception("Failed to add member - not authorized")

        logger.info(f"Added user {member_user_id} to workspace {workspace_id} as {role}")
        return dict(row)

    except Exception as e:
        logger.exception(f"Error adding member to workspace {workspace_id}: {e}")
        raise


async def update_member_role(
    workspace_id: str,
    conn: asyncpg.Connection,
    member_user_id: str,
    new_role: str,
) -> Dict[str, Any]:
    """
    Update a member's role in a workspace.
    RLS ensures only admins/owners can update roles.
    Cannot promote to owner (only one owner allowed).

    Args:
        workspace_id: Workspace ID
        conn: asyncpg connection
        member_user_id: ID of member to update
        new_role: New role ('member' or 'admin')

    Returns:
        Updated membership data

    Raises:
        ValueError: If role is invalid or trying to change owner
    """
    try:
        if new_role not in ("member", "admin"):
            raise ValueError("Role must be 'member' or 'admin'")

        # Check current role
        existing = await conn.fetchrow(
            "SELECT role FROM workspace_members WHERE workspace_id = $1 AND user_id = $2 LIMIT 1",
            workspace_id,
            member_user_id,
        )

        if not existing:
            raise ValueError("Member not found")

        if existing["role"] == "owner":
            raise ValueError("Cannot change the owner's role")

        # Update role
        row = await conn.fetchrow(
            """
            UPDATE workspace_members SET role = $1
            WHERE workspace_id = $2 AND user_id = $3
            RETURNING *
            """,
            new_role,
            workspace_id,
            member_user_id,
        )

        if not row:
            raise ValueError("Failed to update role - not authorized")

        logger.info(f"Updated role for user {member_user_id} in workspace {workspace_id} to {new_role}")
        return dict(row)

    except Exception as e:
        logger.exception(f"Error updating member role in workspace {workspace_id}: {e}")
        raise


async def remove_workspace_member(
    workspace_id: str,
    conn: asyncpg.Connection,
    member_user_id: str,
) -> bool:
    """
    Remove a member from a workspace.
    RLS ensures only admins/owners can remove members.
    Cannot remove the owner.

    Args:
        workspace_id: Workspace ID
        conn: asyncpg connection
        member_user_id: ID of member to remove

    Returns:
        True if removed successfully

    Raises:
        ValueError: If trying to remove owner or member not found
    """
    try:
        # Check if member exists and their role
        existing = await conn.fetchrow(
            "SELECT role FROM workspace_members WHERE workspace_id = $1 AND user_id = $2 LIMIT 1",
            workspace_id,
            member_user_id,
        )

        if not existing:
            raise ValueError("Member not found")

        if existing["role"] == "owner":
            raise ValueError("Cannot remove the workspace owner")

        # Remove member
        result = await conn.execute(
            "DELETE FROM workspace_members WHERE workspace_id = $1 AND user_id = $2",
            workspace_id,
            member_user_id,
        )

        if result == "DELETE 0":
            raise ValueError("Failed to remove member - not authorized")

        logger.info(f"Removed user {member_user_id} from workspace {workspace_id}")

        # Clean up empty DM channels with the removed user
        try:
            # Find workspace apps for this workspace
            app_rows = await conn.fetch(
                "SELECT id FROM workspace_apps WHERE workspace_id = $1",
                workspace_id,
            )

            for app_row in app_rows:
                # Find DM channels where removed user is a participant
                dm_rows = await conn.fetch(
                    """
                    SELECT id FROM channels
                    WHERE workspace_app_id = $1
                      AND is_dm = TRUE
                      AND dm_participants @> $2::jsonb
                    """,
                    app_row["id"],
                    f'["{member_user_id}"]',
                )

                for dm_row in dm_rows:
                    # Check if DM has any messages
                    msg = await conn.fetchrow(
                        "SELECT id FROM channel_messages WHERE channel_id = $1 LIMIT 1",
                        dm_row["id"],
                    )

                    if not msg:
                        await conn.execute(
                            "DELETE FROM channels WHERE id = $1",
                            dm_row["id"],
                        )
                        logger.info(f"Deleted empty DM channel {dm_row['id']} with removed user {member_user_id}")
        except Exception as cleanup_err:
            # Don't fail the member removal if DM cleanup fails
            logger.warning(f"Failed to clean up DMs for removed user {member_user_id}: {cleanup_err}")

        return True

    except Exception as e:
        logger.exception(f"Error removing member from workspace {workspace_id}: {e}")
        raise


async def leave_workspace(
    workspace_id: str,
    user_id: str,
    conn: asyncpg.Connection,
) -> bool:
    """
    Allow a user to leave a workspace voluntarily.
    Owners cannot leave — they must transfer ownership or delete the workspace.

    Args:
        workspace_id: Workspace ID
        user_id: ID of the user leaving
        conn: asyncpg connection

    Returns:
        True if left successfully

    Raises:
        ValueError: If user is the owner or not a member
    """
    try:
        # Check membership and role
        existing = await conn.fetchrow(
            "SELECT role FROM workspace_members WHERE workspace_id = $1 AND user_id = $2 LIMIT 1",
            workspace_id,
            user_id,
        )

        if not existing:
            raise ValueError("You are not a member of this workspace")

        if existing["role"] == "owner":
            raise ValueError("Workspace owners cannot leave. Transfer ownership or delete the workspace instead.")

        # Remove self from workspace
        result = await conn.execute(
            "DELETE FROM workspace_members WHERE workspace_id = $1 AND user_id = $2",
            workspace_id,
            user_id,
        )

        if result == "DELETE 0":
            raise ValueError("Failed to leave workspace")

        logger.info(f"User {user_id} left workspace {workspace_id}")

        # Clean up empty DM channels with the leaving user
        try:
            app_rows = await conn.fetch(
                "SELECT id FROM workspace_apps WHERE workspace_id = $1",
                workspace_id,
            )

            for app_row in app_rows:
                dm_rows = await conn.fetch(
                    """
                    SELECT id FROM channels
                    WHERE workspace_app_id = $1
                      AND is_dm = TRUE
                      AND dm_participants @> $2::jsonb
                    """,
                    app_row["id"],
                    f'["{user_id}"]',
                )

                for dm_row in dm_rows:
                    msg = await conn.fetchrow(
                        "SELECT id FROM channel_messages WHERE channel_id = $1 LIMIT 1",
                        dm_row["id"],
                    )

                    if not msg:
                        await conn.execute(
                            "DELETE FROM channels WHERE id = $1",
                            dm_row["id"],
                        )
                        logger.info(f"Deleted empty DM channel {dm_row['id']} for departing user {user_id}")
        except Exception as cleanup_err:
            logger.warning(f"Failed to clean up DMs for departing user {user_id}: {cleanup_err}")

        return True

    except Exception as e:
        logger.exception(f"Error leaving workspace {workspace_id}: {e}")
        raise


async def get_user_workspace_role(
    workspace_id: str,
    user_id: str,
    conn: asyncpg.Connection,
) -> Optional[str]:
    """
    Get the user's role in a workspace.

    Args:
        workspace_id: Workspace ID
        user_id: User's ID
        conn: asyncpg connection

    Returns:
        Role string ('owner', 'admin', 'member') or None if not a member
    """
    try:
        row = await conn.fetchrow(
            "SELECT role FROM workspace_members WHERE workspace_id = $1 AND user_id = $2 LIMIT 1",
            workspace_id,
            user_id,
        )

        return row["role"] if row else None

    except Exception as e:
        logger.exception(f"Error getting user role for workspace {workspace_id}: {e}")
        raise
