"""
Init router - batched endpoint for app cold start + internal user provisioning.

Endpoints:
  GET  /api/me/init         - Batched cold-start data (workspaces, channels, DMs)
  POST /api/init/new-user   - Internal: provision user + workspace after better-auth signup
"""
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel
from typing import Dict, List, Any, Optional
import asyncio
import logging
import time

from api.config import settings
from api.dependencies import get_current_user_id
from api.exceptions import handle_api_exception
from api.services.workspaces import get_workspaces, get_workspace_apps, get_default_workspace
from api.services.messages import get_channels, get_user_dms, get_unread_counts
from lib.db import get_admin_db_conn

logger = logging.getLogger(__name__)

router = APIRouter(tags=["init"])


# ── Internal: User provisioning ───────────────────────────────────────────────

class NewUserPayload(BaseModel):
    user_id: str
    email: str
    name: Optional[str] = None


@router.post("/api/init/new-user")
async def provision_new_user(
    payload: NewUserPayload,
    x_internal_secret: Optional[str] = Header(None),
) -> Dict[str, str]:
    """
    Called by core-auth (better-auth) after a new user signs up.
    Creates the public.users profile row and a default "Personal" workspace.

    Protected by X-Internal-Secret header — NOT a user-facing endpoint.
    """
    if not settings.internal_api_secret or x_internal_secret != settings.internal_api_secret:
        raise HTTPException(status_code=403, detail="Forbidden")

    async with get_admin_db_conn() as conn:
        # Insert app user profile (idempotent — ON CONFLICT DO NOTHING)
        await conn.execute(
            """
            INSERT INTO public.users (id, email, name, created_at, updated_at)
            VALUES ($1, $2, $3, NOW(), NOW())
            ON CONFLICT (id) DO NOTHING
            """,
            payload.user_id,
            payload.email,
            payload.name or "",
        )

        # Create default "Personal" workspace using existing Postgres function
        await conn.execute(
            "SELECT create_workspace_with_defaults($1, $2, true)",
            payload.name or "Personal",
            payload.user_id,
        )

    logger.info(f"[init] Provisioned user {payload.user_id} ({payload.email})")
    return {"status": "ok", "user_id": payload.user_id}


@router.get("/api/me/init")
async def get_init_data(
    user_id: str = Depends(get_current_user_id),
) -> Dict[str, Any]:
    """
    Batched init endpoint for app cold start.

    Returns all data needed to render the app in a single request:
    workspaces with their apps, channels/DMs for message apps,
    and unread counts.
    """
    try:
        t_start = time.perf_counter()
        logger.info(f"[Init] Fetching init data for user {user_id}")

        # Step 0: Fetch onboarding status
        onboarding_completed_at = None
        try:
            async with get_admin_db_conn() as conn:
                row = await conn.fetchrow(
                    "SELECT onboarding_completed_at FROM public.users WHERE id = $1",
                    user_id,
                )
            onboarding_completed_at = row["onboarding_completed_at"].isoformat() if row and row["onboarding_completed_at"] else None
        except Exception as e:
            logger.warning(f"[Init] Failed to fetch onboarding status: {e}")

        # Step 1: Fetch workspaces (recover default if none found)
        workspaces = await get_workspaces(user_id)
        t_workspaces = time.perf_counter()
        logger.info(f"[Init] Step 1 (workspaces): {(t_workspaces - t_start)*1000:.0f}ms — {len(workspaces)} workspaces")

        if not workspaces:
            logger.info(f"[Init] No workspaces found for user {user_id}, fetching default")
            try:
                default_ws = await get_default_workspace(user_id)
                if default_ws:
                    workspaces = [default_ws]
            except Exception as default_err:
                logger.error(f"[Init] Failed to get default workspace: {default_err}")

        if not workspaces:
            return {
                "workspaces": [],
                "channels_by_app": {},
                "dms_by_app": {},
                "unread_counts": {},
            }

        # Step 2: Fetch apps for all workspaces in parallel
        t_apps_start = time.perf_counter()
        app_results = await asyncio.gather(
            *[get_workspace_apps(ws["id"], user_id) for ws in workspaces],
            return_exceptions=True,
        )
        t_apps = time.perf_counter()
        logger.info(f"[Init] Step 2 (apps): {(t_apps - t_apps_start)*1000:.0f}ms — {len(workspaces)} workspace(s) queried in parallel")

        # Attach apps to workspaces and collect message app IDs
        message_app_ids: List[str] = []
        for ws, apps in zip(workspaces, app_results):
            if isinstance(apps, Exception):
                logger.error(f"[Init] Failed to fetch apps for workspace {ws['id']}: {apps}")
                ws["apps"] = []
            else:
                ws["apps"] = apps
                for app in apps:
                    if app.get("app_type") == "messages":
                        message_app_ids.append(app["id"])

        # Step 3: Fetch channels, DMs, and unread counts for all message apps in parallel
        if message_app_ids:
            t_msgs_start = time.perf_counter()
            tasks = []
            for app_id in message_app_ids:
                tasks.append(get_channels(app_id, user_id))
                tasks.append(get_user_dms(app_id, user_id))
                tasks.append(get_unread_counts(app_id, user_id))

            results = await asyncio.gather(*tasks, return_exceptions=True)
            t_msgs = time.perf_counter()
            logger.info(f"[Init] Step 3 (channels/DMs/unreads): {(t_msgs - t_msgs_start)*1000:.0f}ms — {len(message_app_ids)} message app(s), {len(tasks)} parallel queries")

            channels_by_app: Dict[str, List[Dict[str, Any]]] = {}
            dms_by_app: Dict[str, List[Dict[str, Any]]] = {}
            unread_counts: Dict[str, int] = {}

            for i, app_id in enumerate(message_app_ids):
                base = i * 3
                channels_result = results[base]
                dms_result = results[base + 1]
                unread_result = results[base + 2]

                channels_by_app[app_id] = [] if isinstance(channels_result, Exception) else channels_result
                dms_by_app[app_id] = [] if isinstance(dms_result, Exception) else dms_result

                if not isinstance(unread_result, Exception):
                    unread_counts.update(unread_result)
        else:
            channels_by_app = {}
            dms_by_app = {}
            unread_counts = {}

        t_total = time.perf_counter() - t_start
        logger.info(f"[Init] Total: {t_total*1000:.0f}ms for user {user_id}")

        return {
            "workspaces": workspaces,
            "channels_by_app": channels_by_app,
            "dms_by_app": dms_by_app,
            "unread_counts": unread_counts,
            "onboarding_completed_at": onboarding_completed_at,
        }

    except Exception as e:
        handle_api_exception(e, "Failed to fetch init data", logger)
