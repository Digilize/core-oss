"""
FastAPI dependencies for authentication and authorization.

Replaces Supabase JWT validation with direct session table lookup against
the shared Neon DB. Both core-auth (better-auth) and core-api use the same
Neon DB, so the Python backend validates sessions by querying the session
table directly — no JWKS endpoint or JWT libraries needed.

Session validation:
  SELECT user_id FROM "session"
  WHERE token = $1 AND expires_at > NOW()
"""
import asyncpg
import logging
import sentry_sdk
from fastapi import Depends, Header, HTTPException, status
from typing import Optional, AsyncGenerator

from lib.db import get_pool, get_db_conn

logger = logging.getLogger(__name__)


async def get_current_user_id(
    authorization: Optional[str] = Header(None)
) -> str:
    """
    Validate the better-auth session token from the Authorization header.

    The frontend sends: Authorization: Bearer <session_token>
    The session_token is the opaque token stored in better-auth's `session` table.

    Returns:
        str: The user ID (UUID) for the authenticated user

    Raises:
        HTTPException 401: If token is missing, invalid, or expired
    """
    if not authorization:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing authorization header"
        )

    parts = authorization.split()
    if len(parts) != 2 or parts[0].lower() != "bearer":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid authorization header format. Expected: Bearer <token>"
        )

    token = parts[1]

    try:
        pool = get_pool()
        async with pool.acquire() as conn:
            row = await conn.fetchrow(
                'SELECT user_id FROM "session" WHERE token = $1 AND expires_at > NOW()',
                token
            )
    except asyncpg.PostgresError as e:
        logger.error(f"[auth] DB error validating session: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Authentication service unavailable"
        )

    if not row:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired session token"
        )

    user_id = str(row["user_id"])
    sentry_sdk.set_user({"id": user_id})
    return user_id


async def get_db(
    user_id: str = Depends(get_current_user_id)
) -> AsyncGenerator[asyncpg.Connection, None]:
    """
    FastAPI dependency that yields an authenticated asyncpg connection.

    Sets app.current_user_id on the connection so all RLS policies resolve
    correctly for the authenticated user.

    Usage:
        @router.get("/items")
        async def list_items(conn: asyncpg.Connection = Depends(get_db)):
            rows = await conn.fetch("SELECT * FROM items")
    """
    async with get_db_conn(user_id) as conn:
        yield conn


async def get_optional_user_id(
    authorization: Optional[str] = Header(None)
) -> Optional[str]:
    """
    Extract user ID from token if present, without raising on missing token.
    Returns None if no valid token is provided.

    Use for endpoints where auth is optional.
    """
    if not authorization:
        return None

    parts = authorization.split()
    if len(parts) != 2 or parts[0].lower() != "bearer":
        return None

    token = parts[1]
    try:
        pool = get_pool()
        async with pool.acquire() as conn:
            row = await conn.fetchrow(
                'SELECT user_id FROM "session" WHERE token = $1 AND expires_at > NOW()',
                token
            )
        return str(row["user_id"]) if row else None
    except Exception:
        return None
