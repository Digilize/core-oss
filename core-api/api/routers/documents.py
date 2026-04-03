"""
Documents router - HTTP endpoints for document operations
"""
from fastapi import APIRouter, HTTPException, status, Depends, Response, Query
from typing import Optional, List
from pydantic import BaseModel, Field
import asyncpg
from api.services.documents import (
    create_document,
    create_folder,
    get_documents,
    get_document_by_id,
    update_document,
    delete_document,
    archive_document,
    unarchive_document,
    favorite_document,
    unfavorite_document,
    reorder_documents,
    list_versions,
    get_version,
    restore_version,
)
from api.dependencies import get_current_user_id, get_db
from api.exceptions import handle_api_exception
import logging

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/documents", tags=["documents"])


# Pydantic models for request validation
class CreateDocumentRequest(BaseModel):
    workspace_app_id: str = Field(..., description="Workspace app ID (files app)")
    title: str = "Untitled"
    content: str = ""
    icon: Optional[str] = None
    cover_image: Optional[str] = None
    parent_id: Optional[str] = None
    position: int = 0
    tags: Optional[List[str]] = []


class CreateFolderRequest(BaseModel):
    workspace_app_id: str = Field(..., description="Workspace app ID (files app)")
    title: str = "New Folder"
    parent_id: Optional[str] = None
    position: int = 0


class UpdateDocumentRequest(BaseModel):
    title: Optional[str] = None
    content: Optional[str] = None
    icon: Optional[str] = None
    cover_image: Optional[str] = None
    parent_id: Optional[str] = None
    position: Optional[int] = None
    tags: Optional[List[str]] = None
    expected_updated_at: Optional[str] = None


class ReorderDocumentsRequest(BaseModel):
    document_positions: List[dict]  # [{"id": "doc_id", "position": 0}, ...]


# ============================================================================
# Response Models
# ============================================================================

class DocumentItemResponse(BaseModel):
    """Response model for a single document."""
    id: str
    user_id: Optional[str] = None
    title: Optional[str] = None
    content: Optional[str] = None
    icon: Optional[str] = None
    cover_image: Optional[str] = None
    type: Optional[str] = None  # 'folder', 'note', or 'file'
    is_folder: bool = False  # Kept for backwards compatibility
    parent_id: Optional[str] = None
    position: int = 0
    tags: Optional[List[str]] = None
    is_archived: bool = False
    is_favorite: bool = False
    file_id: Optional[str] = None
    file_url: Optional[str] = None
    file_type: Optional[str] = None
    file_size: Optional[int] = None
    thumb_url: Optional[str] = None
    preview_url: Optional[str] = None
    created_at: Optional[str] = None
    updated_at: Optional[str] = None

    class Config:
        extra = "allow"


class DocumentListResponse(BaseModel):
    """Response model for document list."""
    documents: List[DocumentItemResponse]
    count: int


class DocumentTagsResponse(BaseModel):
    """Response model for document tags."""
    tags: List[str]


class DocumentVersionResponse(BaseModel):
    """Response model for a single document version."""
    id: str
    document_id: str
    title: Optional[str] = None
    content: Optional[str] = None
    version_number: int
    created_by: Optional[str] = None
    created_at: Optional[str] = None


class DocumentVersionListResponse(BaseModel):
    """Response model for document version list."""
    versions: List[DocumentVersionResponse]
    count: int


# ============================================================================
# Document CRUD endpoints
# ============================================================================

@router.get("", response_model=DocumentListResponse)
async def get_documents_endpoint(
    response: Response,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
    parent_id: Optional[str] = None,
    workspace_id: Optional[str] = Query(default=None, description="Filter by workspace ID"),
    workspace_app_id: Optional[str] = Query(default=None, description="Filter by workspace app ID"),
    include_archived: bool = False,
    favorites_only: bool = False,
    folders_only: bool = False,
    documents_only: bool = False,
    fetch_all: bool = Query(default=False, description="Fetch all documents regardless of nesting level"),
    tags: Optional[str] = None,
    sort_by: str = "date",
    sort_direction: str = "desc",
):
    """
    Get documents for a user with optional filtering and sorting.

    Query params:
        workspace_id: Filter by workspace ID
        workspace_app_id: Filter by workspace app ID
        tags: Comma-separated list of tags to filter by (e.g., "Health,Education")
        sort_by: Sort field - "name", "type", "date", or "size" (default: "date")
        sort_direction: Sort direction - "asc" or "desc" (default: "desc")
    """
    try:
        # Parse tags from comma-separated string
        tags_list = [t.strip() for t in tags.split(",") if t.strip()] if tags else None

        # Validate sort parameters
        valid_sort_by = ["name", "type", "date", "size", "position"]
        valid_sort_direction = ["asc", "desc"]

        if sort_by not in valid_sort_by:
            sort_by = "date"
        if sort_direction not in valid_sort_direction:
            sort_direction = "desc"

        logger.info(f"Fetching documents for user {user_id} (sort: {sort_by} {sort_direction})")
        documents = await get_documents(
            user_id=user_id,
            conn=conn,
            parent_id=parent_id,
            workspace_id=workspace_id,
            workspace_app_id=workspace_app_id,
            include_archived=include_archived,
            favorites_only=favorites_only,
            folders_only=folders_only,
            documents_only=documents_only,
            tags=tags_list,
            sort_by=sort_by,
            sort_direction=sort_direction,
            fetch_all=fetch_all,
        )
        # Documents are user-specific and mutation-heavy; disable intermediary/browser caching.
        response.headers["Cache-Control"] = "private, no-store"
        logger.info(f"Fetched {len(documents)} documents")
        return {"documents": documents, "count": len(documents)}
    except Exception as e:
        handle_api_exception(e, "Failed to fetch documents", logger)


@router.get("/tags", response_model=DocumentTagsResponse)
async def get_user_tags_endpoint(
    response: Response,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Get all unique tags used by this user's documents.

    Returns:
        {"tags": ["Health & Fitness", "Education", ...]}
    """
    try:
        logger.info(f"Fetching tags for user {user_id}")

        # Aggregate tags from the documents table using unnest
        rows = await conn.fetch(
            """
            SELECT DISTINCT unnest(tags) AS tag
            FROM documents
            WHERE user_id = $1
              AND tags IS NOT NULL
              AND array_length(tags, 1) > 0
            ORDER BY tag
            """,
            user_id,
        )

        tags_list = [row["tag"] for row in rows if row["tag"]]

        response.headers["Cache-Control"] = "private, no-store"
        logger.info(f"Found {len(tags_list)} unique tags")
        return {"tags": tags_list}
    except Exception as e:
        handle_api_exception(e, "Failed to fetch tags", logger)


@router.get("/{document_id}", response_model=DocumentItemResponse)
async def get_document_endpoint(
    document_id: str,
    response: Response,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Get a specific document by ID.
    """
    try:
        logger.info(f"Fetching document {document_id} for user {user_id}")
        document = await get_document_by_id(user_id=user_id, conn=conn, document_id=document_id)

        if not document:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Document not found"
            )

        # Document reads must be fresh right after edits.
        response.headers["Cache-Control"] = "private, no-store"
        logger.info(f"Fetched document {document_id}")
        return document
    except HTTPException:
        raise
    except Exception as e:
        handle_api_exception(e, "Failed to fetch document", logger)


@router.post("", response_model=DocumentItemResponse, status_code=status.HTTP_201_CREATED)
async def create_document_endpoint(
    request: CreateDocumentRequest,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Create a new document.
    """
    try:
        logger.info(f"Creating document for user {user_id}")
        document = await create_document(
            user_id=user_id,
            conn=conn,
            workspace_app_id=request.workspace_app_id,
            title=request.title,
            content=request.content,
            icon=request.icon,
            cover_image=request.cover_image,
            parent_id=request.parent_id,
            position=request.position,
            tags=request.tags or [],
        )
        logger.info(f"Created document {document['id']}")
        return document
    except Exception as e:
        handle_api_exception(e, "Failed to create document", logger)


@router.post("/folders", response_model=DocumentItemResponse, status_code=status.HTTP_201_CREATED)
async def create_folder_endpoint(
    request: CreateFolderRequest,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Create a new folder.
    """
    try:
        logger.info(f"Creating folder for user {user_id}")
        folder = await create_folder(
            user_id=user_id,
            conn=conn,
            workspace_app_id=request.workspace_app_id,
            title=request.title,
            parent_id=request.parent_id,
            position=request.position,
        )
        logger.info(f"Created folder {folder['id']}")
        return folder
    except Exception as e:
        handle_api_exception(e, "Failed to create folder", logger)


@router.patch("/{document_id}", response_model=DocumentItemResponse)
async def update_document_endpoint(
    document_id: str,
    request: UpdateDocumentRequest,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Update an existing document.
    """
    try:
        logger.info(f"Updating document {document_id} for user {user_id}")

        # Use model_fields_set to check which fields were explicitly provided
        # This allows us to distinguish between "not provided" and "explicitly set to None"
        fields_set = request.model_fields_set if hasattr(request, 'model_fields_set') else set()

        document = await update_document(
            user_id=user_id,
            conn=conn,
            document_id=document_id,
            title=request.title,
            content=request.content,
            icon=request.icon,
            cover_image=request.cover_image,
            parent_id=request.parent_id,
            position=request.position,
            tags=request.tags,
            parent_id_explicitly_set='parent_id' in fields_set,
            expected_updated_at=request.expected_updated_at,
        )
        logger.info(f"Updated document {document_id}")
        return document
    except Exception as e:
        handle_api_exception(e, "Failed to update document", logger, check_not_found=True)


@router.delete("/{document_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_document_endpoint(
    document_id: str,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Permanently delete a document.
    """
    try:
        logger.info(f"Deleting document {document_id} for user {user_id}")
        await delete_document(user_id=user_id, conn=conn, document_id=document_id)
        logger.info(f"Deleted document {document_id}")
        return None
    except Exception as e:
        handle_api_exception(e, "Failed to delete document", logger, check_not_found=True)


@router.post("/{document_id}/archive", response_model=DocumentItemResponse)
async def archive_document_endpoint(
    document_id: str,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Archive a document (soft delete).
    """
    try:
        logger.info(f"Archiving document {document_id} for user {user_id}")
        document = await archive_document(user_id=user_id, conn=conn, document_id=document_id)
        logger.info(f"Archived document {document_id}")
        return document
    except Exception as e:
        handle_api_exception(e, "Failed to archive document", logger, check_not_found=True)


@router.post("/{document_id}/unarchive", response_model=DocumentItemResponse)
async def unarchive_document_endpoint(
    document_id: str,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Unarchive a document.
    """
    try:
        logger.info(f"Unarchiving document {document_id} for user {user_id}")
        document = await unarchive_document(user_id=user_id, conn=conn, document_id=document_id)
        logger.info(f"Unarchived document {document_id}")
        return document
    except Exception as e:
        handle_api_exception(e, "Failed to unarchive document", logger, check_not_found=True)


@router.post("/{document_id}/favorite", response_model=DocumentItemResponse)
async def favorite_document_endpoint(
    document_id: str,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Mark a document as favorite.
    """
    try:
        logger.info(f"Favoriting document {document_id} for user {user_id}")
        document = await favorite_document(user_id=user_id, conn=conn, document_id=document_id)
        logger.info(f"Favorited document {document_id}")
        return document
    except Exception as e:
        handle_api_exception(e, "Failed to favorite document", logger, check_not_found=True)


@router.post("/{document_id}/unfavorite", response_model=DocumentItemResponse)
async def unfavorite_document_endpoint(
    document_id: str,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Remove favorite mark from a document.
    """
    try:
        logger.info(f"Unfavoriting document {document_id} for user {user_id}")
        document = await unfavorite_document(user_id=user_id, conn=conn, document_id=document_id)
        logger.info(f"Unfavorited document {document_id}")
        return document
    except Exception as e:
        handle_api_exception(e, "Failed to unfavorite document", logger, check_not_found=True)


# ============================================================================
# Version History endpoints
# ============================================================================

@router.get("/{document_id}/versions", response_model=DocumentVersionListResponse)
async def list_versions_endpoint(
    document_id: str,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    List all versions for a document (without content).
    """
    try:
        logger.info(f"Listing versions for document {document_id}")
        versions = await list_versions(document_id=document_id, conn=conn)
        return {"versions": versions, "count": len(versions)}
    except Exception as e:
        handle_api_exception(e, "Failed to list document versions", logger)


@router.get("/{document_id}/versions/{version_id}", response_model=DocumentVersionResponse)
async def get_version_endpoint(
    document_id: str,
    version_id: str,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Get a specific version with full content.
    """
    try:
        logger.info(f"Fetching version {version_id} for document {document_id}")
        version = await get_version(
            document_id=document_id, version_id=version_id, conn=conn
        )
        if not version:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Version not found"
            )
        return version
    except HTTPException:
        raise
    except Exception as e:
        handle_api_exception(e, "Failed to fetch document version", logger)


@router.post("/{document_id}/versions/{version_id}/restore", response_model=DocumentItemResponse)
async def restore_version_endpoint(
    document_id: str,
    version_id: str,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Restore a document to a previous version.
    The current content is automatically snapshotted before restoring.
    """
    try:
        logger.info(f"Restoring document {document_id} to version {version_id}")
        document = await restore_version(
            document_id=document_id,
            version_id=version_id,
            user_id=user_id,
            conn=conn,
        )
        logger.info(f"Restored document {document_id}")
        return document
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(e)
        )
    except Exception as e:
        handle_api_exception(e, "Failed to restore document version", logger)


@router.post("/reorder", response_model=DocumentListResponse)
async def reorder_documents_endpoint(
    request: ReorderDocumentsRequest,
    user_id: str = Depends(get_current_user_id),
    conn: asyncpg.Connection = Depends(get_db),
):
    """
    Reorder multiple documents at once.
    """
    try:
        logger.info(f"Reordering documents for user {user_id}")
        documents = await reorder_documents(
            user_id=user_id, conn=conn, document_positions=request.document_positions
        )
        logger.info(f"Reordered {len(documents)} documents")
        return {"documents": documents, "count": len(documents)}
    except Exception as e:
        handle_api_exception(e, "Failed to reorder documents", logger)
