"""
Database connection pool using asyncpg for Neon DB.

Replaces lib/supabase_client.py.

Provides two connection contexts:
  get_db_conn(user_id)  — sets app.current_user_id so RLS policies resolve
  get_admin_db_conn()   — no user context, bypasses RLS (cron/internal only)

The auth.uid() function in the database is defined to read from the
'app.current_user_id' session variable, so all existing RLS policies
continue to work without any changes.
"""
import asyncpg
import logging
from contextlib import asynccontextmanager
from typing import AsyncGenerator

logger = logging.getLogger(__name__)

_pool: asyncpg.Pool | None = None


async def init_pool(database_url: str) -> None:
    """Initialize the asyncpg connection pool. Call once on app startup."""
    global _pool
    _pool = await asyncpg.create_pool(
        database_url,
        min_size=2,
        max_size=10,
        # statement_cache_size=0 is required for Neon's connection pooler (PgBouncer)
        # Without this, prepared statements will fail across connections
        statement_cache_size=0,
        command_timeout=30,
    )
    logger.info("[db] asyncpg pool initialized")


async def close_pool() -> None:
    """Close the connection pool. Call on app shutdown."""
    global _pool
    if _pool:
        await _pool.close()
        logger.info("[db] asyncpg pool closed")


def get_pool() -> asyncpg.Pool:
    """Return the global connection pool. Raises if not yet initialized."""
    if _pool is None:
        raise RuntimeError("Database pool not initialized. Call init_pool() first.")
    return _pool


@asynccontextmanager
async def get_db_conn(user_id: str) -> AsyncGenerator[asyncpg.Connection, None]:
    """
    Acquires a connection and sets app.current_user_id.

    All RLS policies (which call auth.uid() → current_setting('app.current_user_id'))
    will resolve to this user for the duration of the context.

    Uses SET LOCAL which scopes the setting to the current transaction and
    auto-clears when the connection returns to the pool — safe for pooling.
    """
    async with get_pool().acquire() as conn:
        # SET LOCAL scopes to the current transaction — auto-clears at end
        await conn.execute(
            "SET LOCAL \"app.current_user_id\" = $1", user_id
        )
        try:
            yield conn
        finally:
            # Explicit clear as belt-and-suspenders (SET LOCAL already handles it)
            try:
                await conn.execute("SET LOCAL \"app.current_user_id\" = ''")
            except Exception:
                pass  # Connection may already be released


@asynccontextmanager
async def get_admin_db_conn() -> AsyncGenerator[asyncpg.Connection, None]:
    """
    Acquires a connection with NO user context — bypasses all RLS policies.

    Use ONLY for:
      - Internal service-to-service endpoints (protected by INTERNAL_API_SECRET)
      - Background jobs / cron tasks
      - System-level operations that must access all rows

    Never expose this to user-initiated requests.
    """
    async with get_pool().acquire() as conn:
        yield conn
