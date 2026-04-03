"""
Workspace CRUD operations
Handles creating, reading, updating, and deleting workspaces.

Uses asyncpg for non-blocking I/O.
"""
from typing import Dict, Any, List, Optional
from datetime import datetime, timezone
import logging
import asyncpg
from lib.db import get_admin_db_conn
from lib.image_proxy import generate_image_url

logger = logging.getLogger(__name__)


def _enrich_workspace_with_icon_url(workspace: Dict[str, Any]) -> Dict[str, Any]:
    """Generate icon_url from icon_r2_key for a workspace.

    The icon_r2_key is stored in the database, and we generate a fresh
    signed proxy URL on each fetch to avoid expiration issues.
    """
    r2_key = workspace.get("icon_r2_key")
    if r2_key:
        workspace["icon_url"] = generate_image_url(r2_key, variant="thumb")
    else:
        workspace["icon_url"] = None
    return workspace


def _enrich_workspaces_with_icon_url(workspaces: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Generate icon_url from icon_r2_key for a list of workspaces."""
    for workspace in workspaces:
        _enrich_workspace_with_icon_url(workspace)
    return workspaces


async def get_workspaces(
    user_id: str,
    conn: asyncpg.Connection,
) -> List[Dict[str, Any]]:
    """
    Get all workspaces the user is a member of.

    Args:
        user_id: User's ID
        conn: asyncpg connection

    Returns:
        List of workspaces with membership info
    """
    try:
        # Get workspaces through membership
        rows = await conn.fetch(
            """
            SELECT wm.role, wm.joined_at,
                   w.id, w.name, w.owner_id, w.is_default, w.emoji, w.icon_r2_key,
                   w.created_at, w.updated_at
            FROM workspace_members wm
            JOIN workspaces w ON w.id = wm.workspace_id
            WHERE wm.user_id = $1
            """,
            user_id,
        )

        # Flatten the response
        workspaces = []
        for row in rows:
            workspace = dict(row)
            workspace["role"] = row["role"]
            workspace["joined_at"] = row["joined_at"]
            workspace["is_shared"] = False
            workspaces.append(workspace)

        member_workspace_ids = {ws.get("id") for ws in workspaces if ws.get("id")}

        # Include workspaces shared via permissions table
        shared_rows = await conn.fetch(
            """
            SELECT workspace_id, created_at, expires_at
            FROM permissions
            WHERE grantee_type = 'user' AND grantee_id = $1
            """,
            user_id,
        )
        now = datetime.now(timezone.utc)
        active_shared_rows = []
        for row in shared_rows:
            expires_at = row["expires_at"]
            if not expires_at:
                active_shared_rows.append(dict(row))
                continue
            try:
                if hasattr(expires_at, "tzinfo"):
                    expires_dt = expires_at if expires_at.tzinfo else expires_at.replace(tzinfo=timezone.utc)
                else:
                    expires_dt = datetime.fromisoformat(str(expires_at).replace("Z", "+00:00"))
                if expires_dt > now:
                    active_shared_rows.append(dict(row))
            except Exception:
                # If parsing fails, keep the row to avoid hiding data unexpectedly.
                active_shared_rows.append(dict(row))

        shared_workspace_ids = []
        joined_at_by_workspace: Dict[str, Any] = {}
        for row in active_shared_rows:
            workspace_id = row.get("workspace_id")
            if not workspace_id or workspace_id in member_workspace_ids:
                continue
            if workspace_id not in joined_at_by_workspace:
                joined_at_by_workspace[workspace_id] = row.get("created_at")
                shared_workspace_ids.append(workspace_id)

        if shared_workspace_ids:
            shared_ws_rows = await conn.fetch(
                """
                SELECT id, name, owner_id, is_default, emoji, icon_r2_key, created_at, updated_at
                FROM workspaces
                WHERE id = ANY($1)
                """,
                shared_workspace_ids,
            )

            for ws in shared_ws_rows:
                ws_dict = dict(ws)
                ws_id = ws_dict.get("id")
                ws_dict["role"] = "viewer"
                ws_dict["joined_at"] = joined_at_by_workspace.get(ws_id)
                ws_dict["is_shared"] = True
                workspaces.append(ws_dict)

        # Generate icon_url from icon_r2_key
        _enrich_workspaces_with_icon_url(workspaces)

        logger.info(f"Fetched {len(workspaces)} workspaces for user {user_id}")
        return workspaces

    except Exception as e:
        logger.exception(f"Error fetching workspaces for user {user_id}: {e}")
        raise


async def get_workspace_by_id(
    workspace_id: str,
    conn: asyncpg.Connection,
) -> Optional[Dict[str, Any]]:
    """
    Get a single workspace by ID.
    RLS ensures user can only access workspaces they're a member of.

    Args:
        workspace_id: Workspace ID
        conn: asyncpg connection

    Returns:
        Workspace data or None if not found/not accessible
    """
    try:
        row = await conn.fetchrow(
            "SELECT * FROM workspaces WHERE id = $1",
            workspace_id,
        )

        if row:
            workspace = dict(row)
            _enrich_workspace_with_icon_url(workspace)
            return workspace
        return None

    except Exception as e:
        logger.exception(f"Error fetching workspace {workspace_id}: {e}")
        raise


async def get_default_workspace(
    user_id: str,
    conn: asyncpg.Connection,
) -> Optional[Dict[str, Any]]:
    """
    Get the user's default workspace.

    Args:
        user_id: User's ID
        conn: asyncpg connection

    Returns:
        Default workspace data or None
    """
    try:
        row = await conn.fetchrow(
            "SELECT * FROM workspaces WHERE owner_id = $1 AND is_default = TRUE",
            user_id,
        )

        if row:
            workspace = dict(row)
            _enrich_workspace_with_icon_url(workspace)
            return workspace
        return None

    except Exception as e:
        logger.exception(f"Error fetching default workspace for user {user_id}: {e}")
        raise


async def create_workspace(
    user_id: str,
    conn: asyncpg.Connection,
    name: str,
    create_default_apps: bool = True,
) -> Dict[str, Any]:
    """
    Create a new workspace with the user as owner.

    Uses an atomic RPC function to ensure all operations succeed or fail together.

    Args:
        user_id: User's ID (will be workspace owner)
        conn: asyncpg connection
        name: Workspace name
        create_default_apps: Whether to create the 6 default apps

    Returns:
        Created workspace data
    """
    try:
        # Use atomic RPC function to create workspace, member, and apps in one transaction
        workspace_id = await conn.fetchval(
            "SELECT create_workspace_with_defaults($1, $2, $3, $4)",
            name,
            user_id,
            False,
            create_default_apps,
        )

        if not workspace_id:
            raise Exception("Failed to create workspace")

        # Fetch the full workspace record to return
        workspace_row = await conn.fetchrow(
            "SELECT * FROM workspaces WHERE id = $1",
            workspace_id,
        )

        if not workspace_row:
            raise Exception("Workspace created but could not be fetched")

        logger.info(f"Created workspace '{name}' for user {user_id}")
        workspace_data = _enrich_workspace_with_icon_url(dict(workspace_row))

        # Create welcome note if default apps were created
        if create_default_apps:
            try:
                welcome_note = await _create_welcome_note(
                    workspace_id=str(workspace_id),
                    user_id=user_id,
                )
                if welcome_note:
                    workspace_data["welcome_note_id"] = welcome_note["id"]
            except Exception as e:
                logger.exception(f"Failed to create welcome note for workspace {workspace_id}: {e}")

        return workspace_data

    except Exception as e:
        logger.exception(f"Error creating workspace for user {user_id}: {e}")
        raise


async def update_workspace(
    workspace_id: str,
    conn: asyncpg.Connection,
    name: Optional[str] = None,
    emoji: Optional[str] = None,
    icon_r2_key: Optional[str] = None,
    clear_icon: bool = False,
) -> Dict[str, Any]:
    """
    Update a workspace's settings.
    RLS ensures only admins/owners can update.

    Args:
        workspace_id: Workspace ID
        conn: asyncpg connection
        name: New workspace name (optional)
        emoji: Emoji icon for workspace (optional)
        icon_r2_key: R2 key for workspace icon (optional)
        clear_icon: Clear the workspace icon

    Returns:
        Updated workspace data with icon_url generated from icon_r2_key
    """
    try:
        update_data: Dict[str, Any] = {}
        if name is not None:
            update_data["name"] = name
        if emoji is not None:
            update_data["emoji"] = emoji
        if clear_icon:
            update_data["icon_r2_key"] = None
        elif icon_r2_key is not None:
            update_data["icon_r2_key"] = icon_r2_key

        if not update_data:
            # Nothing to update, just fetch current data
            row = await conn.fetchrow(
                "SELECT * FROM workspaces WHERE id = $1",
                workspace_id,
            )
            return _enrich_workspace_with_icon_url(dict(row))

        # Build SET clause dynamically
        set_clauses = []
        values = []
        for i, (col, val) in enumerate(update_data.items(), start=1):
            set_clauses.append(f"{col} = ${i}")
            values.append(val)
        values.append(workspace_id)
        set_sql = ", ".join(set_clauses)

        row = await conn.fetchrow(
            f"UPDATE workspaces SET {set_sql} WHERE id = ${len(values)} RETURNING *",
            *values,
        )

        if not row:
            raise ValueError("Workspace not found or not authorized to update")

        logger.info(f"Updated workspace {workspace_id}")
        return _enrich_workspace_with_icon_url(dict(row))

    except Exception as e:
        logger.exception(f"Error updating workspace {workspace_id}: {e}")
        raise


async def delete_workspace(
    workspace_id: str,
    conn: asyncpg.Connection,
) -> bool:
    """
    Delete a workspace.
    RLS ensures only owners can delete, and default workspaces cannot be deleted.

    Args:
        workspace_id: Workspace ID
        conn: asyncpg connection

    Returns:
        True if deleted successfully

    Raises:
        ValueError: If workspace is default or user is not owner
    """
    try:
        # Check if it's a default workspace
        workspace = await get_workspace_by_id(workspace_id, conn)
        if not workspace:
            raise ValueError("Workspace not found")

        if workspace.get("is_default"):
            raise ValueError("Cannot delete default workspace")

        # Delete workspace (cascades to members, apps, etc.)
        result = await conn.execute(
            "DELETE FROM workspaces WHERE id = $1",
            workspace_id,
        )

        if result == "DELETE 0":
            raise ValueError("Failed to delete workspace - not authorized")

        logger.info(f"Deleted workspace {workspace_id}")
        return True

    except Exception as e:
        logger.exception(f"Error deleting workspace {workspace_id}: {e}")
        raise


WELCOME_NOTE_CONTENT = """# Welcome to Core! 👋

Everything you need. In one place.

---

## What is Core?

Core is an all-in-one productivity workspace that brings together your email, calendar, projects, files, and team messaging — all powered by an AI agent that helps you get things done faster.

Think of it as your unified hub for work — where everything connects and your AI assistant (the Core Agent) understands your full context.

---

## Core Features

- **Messaging** — Team channels for real-time discussions
- **Projects Board** — Organize and track your work with a visual project board
- **Files** — Upload, manage, and organize your files — including docs and notes that live right inside your file system
- **Email** — Search, read, and send emails right from Core
- **Calendar** — View, create, and manage your events
- **Core Agent** — An AI assistant that can search across all your data, answer questions, and take actions on your behalf

---

## Getting Started

1. **Set up your workspace** — Create or join a workspace to get started
2. **Connect your accounts** — Link your email and calendar for the full experience
3. **Explore your files** — Create docs, upload files, and keep everything organized in one place
4. **Try the AI agent** — Ask it anything about your emails, calendar, projects, or files
5. **Invite your team** — Add teammates to collaborate in channels and shared workspaces

---

## Platforms

- **Web app** — Available now
- **Desktop app** — Coming soon
- **Mobile app** — Coming soon

---

## Need Help?

The Core Agent is always here to help! Just ask it questions about your workspace, find information, or get things done.

---

Welcome aboard — let's build something great together!"""


async def _create_welcome_note(
    workspace_id: str,
    user_id: str,
) -> Optional[Dict[str, Any]]:
    """Create a 'Welcome to Core' note in the workspace's files app.

    Uses the admin connection to bypass RLS, since the user's membership
    may not yet be visible immediately after workspace creation.
    """
    async with get_admin_db_conn() as admin_conn:
        # Look up the files app for this workspace
        app_row = await admin_conn.fetchrow(
            """
            SELECT id FROM workspace_apps
            WHERE workspace_id = $1 AND app_type = 'files'
            LIMIT 1
            """,
            workspace_id,
        )

        if not app_row:
            logger.warning(f"No files app found for workspace {workspace_id}")
            return None

        files_app_id = app_row["id"]

        doc_row = await admin_conn.fetchrow(
            """
            INSERT INTO documents
                (user_id, workspace_app_id, workspace_id, title, content, icon, type, position, tags)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            RETURNING *
            """,
            user_id,
            files_app_id,
            workspace_id,
            "Welcome to Core!",
            WELCOME_NOTE_CONTENT,
            "\U0001f44b",
            "note",
            0,
            [],
        )

        if not doc_row:
            return None

        doc = dict(doc_row)
        logger.info(f"Created welcome note {doc['id']} for workspace {workspace_id}")
        return doc
