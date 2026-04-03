"""Channel management service for workspace messaging."""

from typing import Dict, Any, List, Optional
import asyncpg
import json
import logging

logger = logging.getLogger(__name__)


def _row_to_dict(row) -> dict:
    """Convert asyncpg Record to dict, stringifying datetime values."""
    d = dict(row)
    for k, v in d.items():
        if hasattr(v, 'isoformat'):
            d[k] = v.isoformat()
    return d


# =============================================================================
# UNREAD INDICATORS
# =============================================================================


async def get_unread_counts(
    workspace_app_id: str,
    conn: asyncpg.Connection,
) -> Dict[str, int]:
    """
    Get unread message counts for all channels in a workspace.

    Args:
        workspace_app_id: The workspace app ID
        conn: asyncpg connection (RLS user set)

    Returns:
        Dict mapping channel_id to unread count
    """
    try:
        rows = await conn.fetch(
            "SELECT * FROM get_workspace_unread_counts($1)",
            workspace_app_id,
        )

        counts = {}
        for row in rows:
            counts[str(row["channel_id"])] = int(row["unread_count"])

        logger.info(f"Got unread counts for workspace app {workspace_app_id}: {len(counts)} channels")
        return counts

    except Exception as e:
        logger.error(f"Error getting unread counts: {e}")
        raise


async def mark_channel_read(
    channel_id: str,
    conn: asyncpg.Connection,
) -> bool:
    """
    Mark a channel as read for the current user.

    Args:
        channel_id: The channel ID
        conn: asyncpg connection (RLS user set — current_user_id drives auth.uid() equivalent)

    Returns:
        True if successful
    """
    try:
        await conn.execute(
            "SELECT mark_channel_read($1)",
            channel_id,
        )

        logger.info(f"Marked channel {channel_id} as read")
        return True

    except Exception as e:
        logger.error(f"Error marking channel read: {e}")
        raise


async def get_channels(
    workspace_app_id: str,
    conn: asyncpg.Connection,
) -> List[Dict[str, Any]]:
    """
    Get all channels in a workspace app.

    RLS automatically filters private channels to those the user is a member of.

    Args:
        workspace_app_id: The workspace app ID
        conn: asyncpg connection (RLS user set)

    Returns:
        List of channels
    """
    try:
        # Exclude DMs - they're fetched separately via get_user_dms
        rows = await conn.fetch(
            """
            SELECT
                c.*,
                json_build_object(
                    'id', u.id, 'email', u.email, 'name', u.name, 'avatar_url', u.avatar_url
                ) AS created_by_user
            FROM channels c
            LEFT JOIN users u ON u.id = c.created_by
            WHERE c.workspace_app_id = $1 AND c.is_dm = FALSE
            ORDER BY c.created_at ASC
            """,
            workspace_app_id,
        )

        channels = []
        for row in rows:
            d = _row_to_dict(row)
            if isinstance(d.get("created_by_user"), str):
                try:
                    d["created_by_user"] = json.loads(d["created_by_user"])
                except Exception:
                    pass
            channels.append(d)

        logger.info(f"Retrieved {len(channels)} channels for workspace app {workspace_app_id}")
        return channels

    except Exception as e:
        logger.error(f"Error getting channels: {e}")
        raise


async def get_channel(
    channel_id: str,
    conn: asyncpg.Connection,
) -> Optional[Dict[str, Any]]:
    """
    Get a single channel by ID.

    Args:
        channel_id: The channel ID
        conn: asyncpg connection (RLS user set)

    Returns:
        Channel data or None if not found
    """
    try:
        row = await conn.fetchrow(
            """
            SELECT
                c.*,
                json_build_object(
                    'id', u.id, 'email', u.email, 'name', u.name, 'avatar_url', u.avatar_url
                ) AS created_by_user
            FROM channels c
            LEFT JOIN users u ON u.id = c.created_by
            WHERE c.id = $1
            """,
            channel_id,
        )

        if row:
            d = _row_to_dict(row)
            if isinstance(d.get("created_by_user"), str):
                try:
                    d["created_by_user"] = json.loads(d["created_by_user"])
                except Exception:
                    pass
            return d
        return None

    except Exception as e:
        logger.error(f"Error getting channel {channel_id}: {e}")
        raise


async def create_channel(
    workspace_app_id: str,
    user_id: str,
    conn: asyncpg.Connection,
    name: str,
    description: Optional[str] = None,
    is_private: bool = False,
) -> Dict[str, Any]:
    """
    Create a new channel.

    Args:
        workspace_app_id: The workspace app ID
        user_id: User creating the channel
        conn: asyncpg connection (RLS user set)
        name: Channel name (will be lowercased, spaces replaced with hyphens)
        description: Optional channel description
        is_private: Whether the channel is private

    Returns:
        Created channel data
    """
    # Normalize channel name (lowercase, hyphens instead of spaces)
    normalized_name = name.lower().strip().replace(" ", "-")

    try:
        row = await conn.fetchrow(
            """
            INSERT INTO channels (workspace_app_id, name, description, is_private, created_by)
            VALUES ($1, $2, $3, $4, $5)
            RETURNING *
            """,
            workspace_app_id,
            normalized_name,
            description,
            is_private,
            user_id,
        )

        if row:
            channel = _row_to_dict(row)
            logger.info(f"Created channel '{normalized_name}' ({channel['id']}) in workspace app {workspace_app_id}")

            # Safety net: explicitly add the creator to channel_members for private channels.
            # A DB trigger also does this, but we add it here in case the trigger fails silently.
            # Both use ON CONFLICT DO NOTHING, so double-insertion is safe.
            if is_private:
                try:
                    await conn.execute(
                        """
                        INSERT INTO channel_members (channel_id, user_id, role)
                        VALUES ($1, $2, 'owner')
                        ON CONFLICT DO NOTHING
                        """,
                        channel["id"],
                        user_id,
                    )
                except Exception as e:
                    err = str(e).lower()
                    if "duplicate" in err or "conflict" in err:
                        logger.debug(f"Creator already in channel_members (trigger handled it): {channel['id']}")
                    else:
                        logger.warning(f"Failed to add creator to channel_members for {channel['id']}: {e}")

            return channel

        raise Exception("Failed to create channel")

    except Exception as e:
        logger.error(f"Error creating channel: {e}")
        raise


async def update_channel(
    channel_id: str,
    conn: asyncpg.Connection,
    name: Optional[str] = None,
    description: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Update a channel.

    Args:
        channel_id: The channel ID
        conn: asyncpg connection (RLS user set)
        name: New channel name (optional)
        description: New description (optional)

    Returns:
        Updated channel data
    """
    set_parts = ["updated_at = NOW()"]
    values: List[Any] = []
    idx = 1

    if name is not None:
        set_parts.append(f"name = ${idx}")
        values.append(name.lower().strip().replace(" ", "-"))
        idx += 1
    if description is not None:
        set_parts.append(f"description = ${idx}")
        values.append(description)
        idx += 1

    values.append(channel_id)

    try:
        row = await conn.fetchrow(
            f"UPDATE channels SET {', '.join(set_parts)} WHERE id = ${idx} RETURNING *",
            *values,
        )

        if row:
            logger.info(f"Updated channel {channel_id}")
            return _row_to_dict(row)

        raise Exception("Channel not found or no permission")

    except Exception as e:
        logger.error(f"Error updating channel {channel_id}: {e}")
        raise


async def delete_channel(
    channel_id: str,
    conn: asyncpg.Connection,
) -> bool:
    """
    Delete a channel.

    Args:
        channel_id: The channel ID
        conn: asyncpg connection (RLS user set)

    Returns:
        True if successful
    """
    try:
        await conn.execute(
            "DELETE FROM channels WHERE id = $1",
            channel_id,
        )

        logger.info(f"Deleted channel {channel_id}")
        return True

    except Exception as e:
        logger.error(f"Error deleting channel {channel_id}: {e}")
        raise


async def get_channel_members(
    channel_id: str,
    conn: asyncpg.Connection,
) -> List[Dict[str, Any]]:
    """
    Get members of a channel (handles public, private, and DMs).

    Args:
        channel_id: The channel ID
        conn: asyncpg connection (RLS user set)

    Returns:
        List of channel members with user info
    """
    try:
        rows = await conn.fetch(
            "SELECT * FROM get_channel_members_with_profiles($1)",
            channel_id,
        )
        return [_row_to_dict(r) for r in rows]

    except asyncpg.PostgresError as e:
        logger.error(f"RPC error getting channel members: {e}")
        raise
    except Exception as e:
        logger.error(f"Error getting channel members: {e}")
        raise


async def add_channel_member(
    channel_id: str,
    member_user_id: str,
    conn: asyncpg.Connection,
    role: str = "member",
) -> Dict[str, Any]:
    """
    Add a member to a private channel.

    Args:
        channel_id: The channel ID
        member_user_id: User ID to add
        conn: asyncpg connection (RLS user set)
        role: Member role (owner, moderator, member)

    Returns:
        Created membership data
    """
    try:
        # Validate that the channel exists, is private, and is not a DM
        channel_row = await conn.fetchrow(
            "SELECT is_private, is_dm FROM channels WHERE id = $1",
            channel_id,
        )
        if not channel_row:
            raise ValueError("Channel not found or not accessible")
        if channel_row["is_dm"]:
            raise ValueError("Cannot add members to DM channels — use DM endpoints")
        if not channel_row["is_private"]:
            raise ValueError("Can only add members to private channels")

        row = await conn.fetchrow(
            """
            INSERT INTO channel_members (channel_id, user_id, role)
            VALUES ($1, $2, $3)
            RETURNING *
            """,
            channel_id,
            member_user_id,
            role,
        )

        if row:
            logger.info(f"Added user {member_user_id} to channel {channel_id}")
            return _row_to_dict(row)

        raise Exception("Failed to add member")

    except ValueError:
        raise
    except Exception as e:
        logger.error(f"Error adding channel member: {e}")
        raise


async def remove_channel_member(
    channel_id: str,
    member_user_id: str,
    conn: asyncpg.Connection,
) -> bool:
    """
    Remove a member from a private channel.

    Args:
        channel_id: The channel ID
        member_user_id: User ID to remove
        conn: asyncpg connection (RLS user set)

    Returns:
        True if successful
    """
    try:
        await conn.execute(
            "DELETE FROM channel_members WHERE channel_id = $1 AND user_id = $2",
            channel_id,
            member_user_id,
        )

        logger.info(f"Removed user {member_user_id} from channel {channel_id}")
        return True

    except Exception as e:
        logger.error(f"Error removing channel member: {e}")
        raise


# =============================================================================
# DIRECT MESSAGES (DMs)
# =============================================================================


async def get_or_create_dm(
    workspace_app_id: str,
    user_id: str,
    conn: asyncpg.Connection,
    participant_ids: List[str],
) -> Dict[str, Any]:
    """
    Get or create a DM channel between participants.

    Args:
        workspace_app_id: The workspace app ID
        user_id: Current user ID (must be in participant_ids)
        conn: asyncpg connection (RLS user set)
        participant_ids: List of user IDs for the DM (including current user)

    Returns:
        DM channel data
    """
    # Ensure current user is in participants
    if user_id not in participant_ids:
        participant_ids = [user_id] + participant_ids

    # Sort for consistent lookup
    sorted_participants = sorted(participant_ids)

    try:
        channel_id_row = await conn.fetchrow(
            "SELECT get_or_create_dm($1, $2) AS channel_id",
            workspace_app_id,
            sorted_participants,
        )

        if channel_id_row and channel_id_row["channel_id"]:
            channel_id = str(channel_id_row["channel_id"])
            # Fetch the full channel with participant info
            channel = await get_dm_channel(channel_id, conn)
            if channel:
                logger.info(f"Got/created DM channel {channel_id}")
                return channel

        raise Exception("Failed to get or create DM")

    except Exception as e:
        logger.error(f"Error getting/creating DM: {e}")
        raise


async def get_dm_channel(
    channel_id: str,
    conn: asyncpg.Connection,
) -> Optional[Dict[str, Any]]:
    """
    Get a DM channel with participant info.

    Args:
        channel_id: The channel ID
        conn: asyncpg connection (RLS user set)

    Returns:
        DM channel data with participants
    """
    try:
        row = await conn.fetchrow(
            "SELECT * FROM channels WHERE id = $1 AND is_dm = TRUE",
            channel_id,
        )

        if row:
            channel = _row_to_dict(row)

            # Fetch participant user info
            dm_participants = channel.get("dm_participants") or []
            if dm_participants:
                user_rows = await conn.fetch(
                    "SELECT id, email, name, avatar_url FROM users WHERE id = ANY($1::uuid[])",
                    dm_participants,
                )
                channel["participants"] = [_row_to_dict(u) for u in user_rows]

            return channel
        return None

    except Exception as e:
        logger.error(f"Error getting DM channel {channel_id}: {e}")
        raise


async def get_user_dms(
    workspace_app_id: str,
    user_id: str,
    conn: asyncpg.Connection,
) -> List[Dict[str, Any]]:
    """
    Get all DM channels for a user in a workspace.

    Args:
        workspace_app_id: The workspace app ID
        user_id: The user ID
        conn: asyncpg connection (RLS user set)

    Returns:
        List of DM channels with participant info
    """
    try:
        # Get DMs where user is a participant
        rows = await conn.fetch(
            """
            SELECT * FROM channels
            WHERE workspace_app_id = $1 AND is_dm = TRUE AND dm_participants @> ARRAY[$2::uuid]
            ORDER BY updated_at DESC
            """,
            workspace_app_id,
            user_id,
        )

        dms = [_row_to_dict(r) for r in rows]

        if not dms:
            return dms

        # Get workspace_id from workspace_app to check membership
        app_row = await conn.fetchrow(
            "SELECT workspace_id FROM workspace_apps WHERE id = $1",
            workspace_app_id,
        )
        workspace_id = str(app_row["workspace_id"]) if app_row else None

        # Get current workspace member IDs to filter out DMs with departed members
        active_member_ids: set = set()
        if workspace_id:
            member_rows = await conn.fetch(
                "SELECT user_id FROM workspace_members WHERE workspace_id = $1",
                workspace_id,
            )
            active_member_ids = {str(m["user_id"]) for m in member_rows}

        # Filter DMs: only keep those where ALL other participants are still workspace members
        if active_member_ids:
            filtered_dms = []
            for dm in dms:
                other_participants = [
                    str(pid) for pid in (dm.get("dm_participants") or [])
                    if str(pid) != user_id
                ]
                # Keep DM if all other participants are still active members
                if all(pid in active_member_ids for pid in other_participants):
                    filtered_dms.append(dm)
            dms = filtered_dms

        # Fetch participant info for all DMs
        all_participant_ids: set = set()
        for dm in dms:
            if dm.get("dm_participants"):
                all_participant_ids.update(str(p) for p in dm["dm_participants"])

        if all_participant_ids:
            user_rows = await conn.fetch(
                "SELECT id, email, name, avatar_url FROM users WHERE id = ANY($1::uuid[])",
                list(all_participant_ids),
            )
            users_by_id = {str(u["id"]): _row_to_dict(u) for u in user_rows}

            # Attach participant info to each DM
            for dm in dms:
                dm["participants"] = [
                    users_by_id.get(str(pid), {"id": str(pid)})
                    for pid in (dm.get("dm_participants") or [])
                ]

        logger.info(f"Retrieved {len(dms)} DMs for user {user_id}")
        return dms

    except Exception as e:
        logger.error(f"Error getting user DMs: {e}")
        raise
