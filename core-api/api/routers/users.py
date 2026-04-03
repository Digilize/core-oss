"""
User profile router - endpoints for user profile management including avatar upload
"""
from fastapi import APIRouter, HTTPException, status, Depends
from pydantic import BaseModel, Field
from typing import Optional
import asyncpg

from api.dependencies import get_current_user_id
from api.exceptions import handle_api_exception
from api.config import settings
from lib.r2_client import get_r2_client
from lib.db import get_admin_db_conn
import logging

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/users", tags=["users"])

# Allowed image types for avatars
AVATAR_MIME_TYPES = {
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/webp",
}

MAX_AVATAR_SIZE = 5 * 1024 * 1024  # 5MB


class AvatarUploadInitiateRequest(BaseModel):
    """Request to initiate avatar upload"""
    filename: str
    content_type: str
    file_size: int


class AvatarUploadInitiateResponse(BaseModel):
    """Response with presigned URL for avatar upload"""
    upload_url: str
    r2_key: str
    public_url: str
    expires_at: str


class AvatarUploadConfirmRequest(BaseModel):
    """Request to confirm avatar upload"""
    r2_key: str


class AvatarUploadConfirmResponse(BaseModel):
    """Response after confirming avatar upload"""
    avatar_url: str


class UpdateUserProfileRequest(BaseModel):
    """Request to update user profile"""
    name: Optional[str] = Field(None, min_length=1, max_length=100)
    onboarding_completed_at: Optional[str] = None


class UserProfileResponse(BaseModel):
    """User profile data"""
    id: str
    email: str
    name: Optional[str] = None
    avatar_url: Optional[str] = None
    onboarding_completed_at: Optional[str] = None


@router.get("/me", response_model=UserProfileResponse)
async def get_current_user_profile(
    current_user_id: str = Depends(get_current_user_id),
):
    """
    Get current user's profile.
    """
    try:
        async with get_admin_db_conn() as conn:
            row = await conn.fetchrow(
                "SELECT id, email, name, avatar_url, onboarding_completed_at FROM users WHERE id = $1",
                current_user_id,
            )

        if not row:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="User not found"
            )

        return dict(row)
    except HTTPException:
        raise
    except Exception as e:
        handle_api_exception(e, "Failed to get user profile", logger)


@router.patch("/me", response_model=UserProfileResponse)
async def update_current_user_profile(
    request: UpdateUserProfileRequest,
    current_user_id: str = Depends(get_current_user_id),
):
    """
    Update current user's profile (name, onboarding status).
    """
    try:
        updates: dict = {}
        if request.name is not None:
            updates["name"] = request.name
        if request.onboarding_completed_at is not None:
            updates["onboarding_completed_at"] = request.onboarding_completed_at

        if not updates:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="No fields to update"
            )

        # Build SET clause dynamically with $2, $3, ... for each field
        set_parts = []
        values = []
        for i, (col, val) in enumerate(updates.items(), start=2):
            set_parts.append(f"{col} = ${i}")
            values.append(val)

        sql = (
            f"UPDATE users SET {', '.join(set_parts)} WHERE id = $1 "
            "RETURNING id, email, name, avatar_url, onboarding_completed_at"
        )

        async with get_admin_db_conn() as conn:
            row = await conn.fetchrow(sql, current_user_id, *values)

        if not row:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="User not found"
            )

        return dict(row)
    except HTTPException:
        raise
    except Exception as e:
        handle_api_exception(e, "Failed to update user profile", logger)


@router.post("/avatar/initiate", response_model=AvatarUploadInitiateResponse)
async def initiate_avatar_upload(
    request: AvatarUploadInitiateRequest,
    current_user_id: str = Depends(get_current_user_id)
):
    """
    Initiate avatar upload by getting a presigned URL.

    Client uploads directly to R2 using the returned URL,
    then calls /avatar/confirm to finalize.
    """
    # Validate content type
    if request.content_type not in AVATAR_MIME_TYPES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid image type. Allowed: {', '.join(AVATAR_MIME_TYPES)}"
        )

    # Validate file size
    if request.file_size > MAX_AVATAR_SIZE:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"File too large. Maximum size: {MAX_AVATAR_SIZE // (1024*1024)}MB"
        )

    try:
        r2 = get_r2_client()

        # Generate R2 key for avatar
        r2_key = r2.generate_key_for_context(
            user_id=current_user_id,
            filename=request.filename,
            context="avatars"
        )

        # Generate presigned PUT URL (upload to public bucket)
        presigned = r2.generate_presigned_put_url(
            r2_key=r2_key,
            content_type=request.content_type,
            expiration=300,  # 5 minutes
            bucket=settings.r2_public_bucket
        )

        # Build public URL (using public r2.dev URL for avatars)
        public_url = f"{settings.r2_public_access_url}/{r2_key}" if settings.r2_public_access_url else ""

        logger.info(f"Initiated avatar upload for user {current_user_id}")

        return AvatarUploadInitiateResponse(
            upload_url=presigned["url"],
            r2_key=r2_key,
            public_url=public_url,
            expires_at=presigned["expires_at"]
        )

    except Exception as e:
        handle_api_exception(e, "Failed to initiate avatar upload", logger)


@router.post("/avatar/confirm", response_model=AvatarUploadConfirmResponse)
async def confirm_avatar_upload(
    request: AvatarUploadConfirmRequest,
    current_user_id: str = Depends(get_current_user_id)
):
    """
    Confirm avatar upload after client has uploaded to R2.

    Verifies the file exists in R2, then updates the user's avatar_url.
    """
    try:
        r2 = get_r2_client()

        # Verify file exists in R2 (public bucket)
        if not r2.file_exists(request.r2_key, bucket=settings.r2_public_bucket):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="File not found in storage. Upload may have failed."
            )

        # Verify the r2_key belongs to this user (security check)
        if f"avatars/{current_user_id}/" not in request.r2_key:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Invalid avatar key"
            )

        # Build public URL (using public r2.dev URL for avatars)
        public_url = f"{settings.r2_public_access_url}/{request.r2_key}"

        # Update user's avatar_url in database
        async with get_admin_db_conn() as conn:
            row = await conn.fetchrow(
                "UPDATE users SET avatar_url = $1 WHERE id = $2 RETURNING id",
                public_url,
                current_user_id,
            )

        if not row:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="User not found"
            )

        logger.info(f"Avatar updated for user {current_user_id}: {public_url}")

        return AvatarUploadConfirmResponse(avatar_url=public_url)

    except HTTPException:
        raise
    except Exception as e:
        handle_api_exception(e, "Failed to confirm avatar upload", logger)


@router.delete("/avatar", response_model=AvatarUploadConfirmResponse)
async def delete_avatar(
    current_user_id: str = Depends(get_current_user_id)
):
    """
    Remove user's avatar, reverting to default.
    """
    try:
        async with get_admin_db_conn() as conn:
            # Get current avatar URL to delete from R2
            user_row = await conn.fetchrow(
                "SELECT avatar_url FROM users WHERE id = $1",
                current_user_id,
            )

            if not user_row:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail="User not found"
                )

            if user_row["avatar_url"]:
                old_url = user_row["avatar_url"]
                # Extract r2_key from URL and delete from R2
                if settings.r2_public_access_url and old_url.startswith(settings.r2_public_access_url):
                    r2_key = old_url.replace(f"{settings.r2_public_access_url}/", "")
                    try:
                        r2 = get_r2_client()
                        r2.delete_file(r2_key, bucket=settings.r2_public_bucket)
                        logger.info(f"Deleted old avatar from R2: {r2_key}")
                    except Exception as e:
                        logger.warning(f"Failed to delete old avatar from R2: {e}")

            # Clear avatar_url in database
            await conn.execute(
                "UPDATE users SET avatar_url = NULL WHERE id = $1",
                current_user_id,
            )

        logger.info(f"Avatar removed for user {current_user_id}")

        return AvatarUploadConfirmResponse(avatar_url="")

    except HTTPException:
        raise
    except Exception as e:
        handle_api_exception(e, "Failed to delete avatar", logger)
