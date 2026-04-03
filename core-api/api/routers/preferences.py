"""
User preferences router - HTTP endpoints for user settings
"""
from fastapi import APIRouter, HTTPException, status, Depends
from pydantic import BaseModel
from typing import Optional
import asyncpg
from api.dependencies import get_current_user_id, get_db
import logging

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/preferences", tags=["preferences"])


# ============================================================================
# Request/Response Models
# ============================================================================

class UserPreferencesResponse(BaseModel):
    """Response model for user preferences"""
    show_embedded_cards: bool = True
    always_search_content: bool = True
    timezone: str = "UTC"


class UpdatePreferencesRequest(BaseModel):
    """Request model for updating preferences"""
    show_embedded_cards: Optional[bool] = None
    always_search_content: Optional[bool] = None
    timezone: Optional[str] = None


# ============================================================================
# Endpoints
# ============================================================================

@router.get("", response_model=UserPreferencesResponse)
async def get_preferences(
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Get user preferences. Creates default preferences if none exist.
    """
    try:
        row = await conn.fetchrow(
            "SELECT * FROM user_preferences WHERE user_id = $1",
            user_id,
        )

        if row:
            prefs = dict(row)
            return UserPreferencesResponse(
                show_embedded_cards=prefs.get("show_embedded_cards", True),
                always_search_content=prefs.get("always_search_content", True),
                timezone=prefs.get("timezone", "UTC"),
            )

        # No preferences exist — create defaults
        inserted = await conn.fetchrow(
            """
            INSERT INTO user_preferences (user_id, show_embedded_cards, always_search_content, timezone)
            VALUES ($1, TRUE, TRUE, 'UTC')
            ON CONFLICT (user_id) DO NOTHING
            RETURNING *
            """,
            user_id,
        )

        if inserted:
            prefs = dict(inserted)
            return UserPreferencesResponse(
                show_embedded_cards=prefs.get("show_embedded_cards", True),
                always_search_content=prefs.get("always_search_content", True),
                timezone=prefs.get("timezone", "UTC"),
            )

        # Return defaults if insert returned nothing (race condition — row now exists)
        return UserPreferencesResponse()

    except Exception as e:
        logger.error(f"Error getting preferences for user {user_id}: {e}")
        # Return defaults on error to not break the app
        return UserPreferencesResponse()


@router.patch("", response_model=UserPreferencesResponse)
async def update_preferences(
    updates: UpdatePreferencesRequest,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Update user preferences. Creates preferences row if none exist.
    """
    try:
        # Build update dict with only provided fields
        update_data: dict = {}
        if updates.show_embedded_cards is not None:
            update_data["show_embedded_cards"] = updates.show_embedded_cards
        if updates.always_search_content is not None:
            update_data["always_search_content"] = updates.always_search_content
        if updates.timezone is not None:
            update_data["timezone"] = updates.timezone

        if not update_data:
            # No updates provided — return current preferences
            return await get_preferences(user_id=user_id, conn=conn)

        # Upsert: update if exists, insert with defaults merged with updates otherwise
        set_clauses = []
        params: list = []

        def _p(val) -> str:
            params.append(val)
            return f"${len(params)}"

        for col, val in update_data.items():
            set_clauses.append(f"{col} = {_p(val)}")

        params.append(user_id)
        user_id_placeholder = f"${len(params)}"

        # Build an upsert: insert defaults + updates, on conflict update only the changed cols
        insert_cols = ["user_id", "show_embedded_cards", "always_search_content", "timezone"]
        insert_defaults = {
            "show_embedded_cards": update_data.get("show_embedded_cards", True),
            "always_search_content": update_data.get("always_search_content", True),
            "timezone": update_data.get("timezone", "UTC"),
        }

        insert_params: list = [user_id]
        insert_placeholders = ["$1"]
        for col in ["show_embedded_cards", "always_search_content", "timezone"]:
            insert_params.append(insert_defaults[col])
            insert_placeholders.append(f"${len(insert_params)}")

        update_set_parts = []
        for col in update_data:
            insert_params.append(update_data[col])
            update_set_parts.append(f"{col} = ${len(insert_params)}")

        sql = f"""
            INSERT INTO user_preferences (user_id, show_embedded_cards, always_search_content, timezone)
            VALUES ({', '.join(insert_placeholders)})
            ON CONFLICT (user_id) DO UPDATE
            SET {', '.join(update_set_parts)}
            RETURNING *
        """

        row = await conn.fetchrow(sql, *insert_params)

        if row:
            prefs = dict(row)
            return UserPreferencesResponse(
                show_embedded_cards=prefs.get("show_embedded_cards", True),
                always_search_content=prefs.get("always_search_content", True),
                timezone=prefs.get("timezone", "UTC"),
            )

        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to update preferences"
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error updating preferences for user {user_id}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="An unexpected error occurred while updating preferences."
        )
