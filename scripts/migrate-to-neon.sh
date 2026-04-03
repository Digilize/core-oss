#!/usr/bin/env bash
# migrate-to-neon.sh
#
# Preprocesses Supabase migration files for Neon DB compatibility and runs them.
#
# What it does:
#   1. Strips GRANT statements to Supabase-specific roles (anon, authenticated, service_role)
#   2. Strips ALTER TABLE ... OWNER TO "postgres" (Neon uses a different owner)
#   3. Skips migration files that configure Supabase-internal services
#   4. Runs the auth schema shim FIRST
#   5. Runs all remaining migrations in order
#
# Usage:
#   export NEON_DATABASE_URL="postgresql://user:pass@host/db?sslmode=require"
#   ./scripts/migrate-to-neon.sh
#
# Requirements:
#   - psql in PATH
#   - NEON_DATABASE_URL env var set

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MIGRATIONS_DIR="$REPO_ROOT/core-api/supabase/migrations"
PROCESSED_DIR="$REPO_ROOT/core-api/supabase/migrations_neon"

if [[ -z "${NEON_DATABASE_URL:-}" ]]; then
    echo "❌ NEON_DATABASE_URL is not set"
    exit 1
fi

# Files to skip entirely (Supabase-internal services)
SKIP_FILES=(
    "20260316000018_signup_trigger.sql"    # auth.users trigger — replaced by app-level hook
    "20260316000019_realtime_config.sql"   # Supabase Realtime — not available on Neon
    "20260316000021_storage_config.sql"    # Supabase Storage — using Cloudflare R2 instead
    "20260316000020_seed_data.sql"         # Optional: remove if you don't want seed data
)

echo "📁 Creating processed migrations directory..."
rm -rf "$PROCESSED_DIR"
mkdir -p "$PROCESSED_DIR"

preprocess_migration() {
    local input="$1"
    local output="$2"

    # Strip lines that contain GRANT to Supabase-specific roles
    # Strip lines that contain OWNER TO "postgres" (Neon uses a different owner)
    # Strip lines referencing Supabase-internal schemas for grants
    sed \
        -e '/GRANT.*TO "anon"/d' \
        -e '/GRANT.*TO "authenticated"/d' \
        -e '/GRANT.*TO "service_role"/d' \
        -e '/OWNER TO "postgres"/d' \
        -e '/OWNER TO "authenticator"/d' \
        -e '/OWNER TO "supabase_admin"/d' \
        -e '/ALTER DEFAULT PRIVILEGES/,/;/d' \
        "$input" > "$output"
}

# Check if a file should be skipped
should_skip() {
    local filename="$1"
    for skip in "${SKIP_FILES[@]}"; do
        if [[ "$filename" == "$skip" ]]; then
            return 0
        fi
    done
    return 1
}

echo "🔧 Preprocessing migration files..."

# Run auth schema shim first
SHIM_FILE="$MIGRATIONS_DIR/0000_auth_schema_shim.sql"
if [[ -f "$SHIM_FILE" ]]; then
    echo "  → 0000_auth_schema_shim.sql (shim, no preprocessing needed)"
    cp "$SHIM_FILE" "$PROCESSED_DIR/0000_auth_schema_shim.sql"
else
    echo "❌ Auth schema shim not found at $SHIM_FILE"
    exit 1
fi

# Process remaining migrations in sorted order
for migration in $(ls "$MIGRATIONS_DIR"/*.sql | grep -v "0000_auth_schema_shim" | sort); do
    filename="$(basename "$migration")"

    if should_skip "$filename"; then
        echo "  ⏭  Skipping: $filename"
        continue
    fi

    echo "  ✓  Processing: $filename"
    preprocess_migration "$migration" "$PROCESSED_DIR/$filename"
done

echo ""
echo "🚀 Running migrations against Neon DB..."
echo "   Database: ${NEON_DATABASE_URL%%@*}@***"
echo ""

# Run all processed migrations in order
for migration in $(ls "$PROCESSED_DIR"/*.sql | sort); do
    filename="$(basename "$migration")"
    echo "  ▶  $filename"
    psql "$NEON_DATABASE_URL" -f "$migration" --quiet 2>&1 | grep -v "^$" | sed 's/^/     /' || {
        echo "❌ Failed on $filename"
        exit 1
    }
done

echo ""
echo "✅ All migrations applied successfully!"
