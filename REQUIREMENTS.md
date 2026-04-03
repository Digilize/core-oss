# Core — Requirements & Capabilities Document

> An all-in-one productivity platform combining Email, Calendar, Team Messaging, AI Chat, Documents, Files, Projects, and AI Agents into a single unified workspace.

---

## Table of Contents

1. [Overview](#1-overview)
2. [System Architecture](#2-system-architecture)
3. [Core Modules](#3-core-modules)
   - [3.1 Workspaces](#31-workspaces)
   - [3.2 Email](#32-email)
   - [3.3 Calendar](#33-calendar)
   - [3.4 AI Chat](#34-ai-chat)
   - [3.5 Team Messaging](#35-team-messaging)
   - [3.6 Documents & Files](#36-documents--files)
   - [3.7 Projects (Kanban)](#37-projects-kanban)
   - [3.8 AI Agents](#38-ai-agents)
   - [3.9 AI App Builder](#39-ai-app-builder)
   - [3.10 Notifications](#310-notifications)
   - [3.11 Permissions & Sharing](#311-permissions--sharing)
   - [3.12 App Drawer](#312-app-drawer)
4. [Cross-Cutting Capabilities](#4-cross-cutting-capabilities)
5. [External Integrations](#5-external-integrations)
6. [Data Model Summary](#6-data-model-summary)
7. [Authentication & Authorization](#7-authentication--authorization)
8. [Sync & Realtime Infrastructure](#8-sync--realtime-infrastructure)
9. [Non-Functional Requirements](#9-non-functional-requirements)

---

## 1. Overview

**Core** is a unified productivity platform that replaces multiple standalone tools. A single user can:

- Manage personal and team **workspaces**
- Read, send, search, and organize **email** across multiple Google and Microsoft accounts
- View and manage **calendar** events from all connected accounts
- Chat with an **AI assistant** that can search email, browse the web, manage calendars, create documents, and execute actions on the user's behalf
- Communicate with teammates via **channels and direct messages**
- Write and organize **documents and notes** in a hierarchical folder structure
- Track work on **Kanban project boards**
- Create, configure, and deploy **AI agents** that run in isolated sandboxes
- Generate web applications through an **AI app builder**
- Share resources with fine-grained **permissions and access control**
- Receive **notifications** for all relevant activity

The platform is built as a monorepo with three packages:

| Package | Stack | Purpose |
|---------|-------|---------|
| `core-api` | Python 3.12, FastAPI | Backend REST API, business logic, sync workers |
| `core-web` | React 19, Vite 7, TypeScript | Single-page web application |
| `core-image-proxy` | Cloudflare Workers | HMAC-signed image resizing and CDN |

---

## 2. System Architecture

### Backend Layer Flow

```
HTTP Request
  → API Routers (FastAPI endpoints, request validation)
    → Services (business logic, domain operations)
      → Shared Libraries (Supabase, R2, Resend, QStash, AI providers)
        → External Services
```

### Frontend Layer Flow

```
React Components (34 feature modules)
  → Custom Hooks (chat streaming, realtime, keyboard nav)
    → Zustand Stores (19 stores for client state)
      → API Client (single REST client with auth, streaming, error handling)
        → Backend (core-api)
```

### Key Architectural Decisions

- **Dependency injection** via FastAPI `Depends()` for auth/user context
- **Environment-driven configuration** via Pydantic `BaseSettings`
- **Row-Level Security (RLS)** in PostgreSQL for multi-tenant data isolation
- **Optimistic UI updates** across the frontend with rollback on failure
- **NDJSON streaming** for AI chat and app builder responses
- **Structured content parts** (`content_parts` JSONB) for rich message/document content

---

## 3. Core Modules

### 3.1 Workspaces

**What it does:** Workspaces are the top-level organizational unit. Each workspace contains a configurable set of "mini apps" (Chat, Messages, Files, Dashboard, Projects, Agents) and a roster of members with roles.

**Requirements:**

- Users can belong to multiple workspaces
- Each workspace has an owner, admins, and members
- Workspaces contain configurable mini apps (public or private)
- Private apps require explicit member assignment
- Workspace invitations via email with token-based acceptance
- Role-based access: owner > admin > member
- Members can be added, removed, or have their role updated
- Workspace creation includes default app provisioning
- Session-based app memory — remembers the last visited app per workspace

**Key Entities:** `workspaces`, `workspace_members`, `workspace_apps`, `workspace_app_members`, `workspace_invitations`

---

### 3.2 Email

**What it does:** A full-featured email client that unifies multiple Google and Microsoft accounts into a single inbox. Supports reading, composing, replying, forwarding, drafting, labeling, archiving, trashing, searching, and AI-powered analysis.

**Requirements:**

- Connect up to 5 email accounts (Google and/or Microsoft)
- Unified inbox view across all connected accounts
- Folder views: Inbox, Sent, Drafts, Trash, Starred
- Thread/conversation view with full body rendering
- Compose, reply, reply-all, and forward emails
- Auto-save drafts; send drafts on demand
- Move to trash, restore from trash, archive
- Mark as read/unread
- Apply and remove Gmail labels
- Server-side search across local database and provider APIs
- Remote email fetching for uncached messages
- AI analysis of emails (category, summary, priority) via Groq
- Attachment download
- Real-time sync via webhooks (Gmail Pub/Sub, Microsoft Graph)
- Incremental sync every 15 minutes as safety net
- Pagination for message lists

**Key Entities:** `emails` (with full-text search, vector embeddings, AI analysis fields), `ext_connections`

---

### 3.3 Calendar

**What it does:** A multi-account calendar with day/week/month/year views, event creation, editing, RSVP, and real-time sync from Google and Microsoft.

**Requirements:**

- Unified view of events from all connected Google and Microsoft calendars
- Day, week, month, and year views with swipeable navigation
- Create events (syncs to external provider)
- Edit and delete events (single instance or all recurring)
- RSVP to events: accept, decline, tentative
- Drag-to-create events with duration selection
- Click on time slot for inline event creation
- Multi-account filtering (toggle accounts on/off)
- Google Meet link support
- Optimistic event creation with rollback on failure
- Real-time sync via webhooks
- Today's events quick view

**Key Entities:** `calendar_events` (with attendee data, recurrence, meeting links, vector embeddings)

---

### 3.4 AI Chat

**What it does:** A conversational AI interface powered by Claude/OpenAI/Groq that can search the user's email, browse the web, manage calendars, search documents, manage files, interact with projects, and propose actions for the user to execute.

**Requirements:**

- Multiple concurrent conversations per user
- Streaming responses with progressive word-by-word reveal (~35ms tick)
- Rich structured content: text, tool calls, sources, actions, attachments
- Tool calling capabilities:
  - Email search and retrieval
  - Web search (via Exa)
  - Calendar event creation and lookup
  - Document search
  - File management
  - Project/issue management
  - Memory (persistent context)
- Staged actions: AI proposes actions (create event, send email, create document) that user reviews and executes with one click
- File/image attachments in conversations
- Message regeneration
- Auto-generated conversation titles
- Right-side slide-out chat panel (340px) for quick queries from any view
- Conversation history and management (rename, delete)
- R2 storage for chat attachments

**Key Entities:** `conversations`, `messages` (with `content_parts` JSONB), `chat_attachments`

---

### 3.5 Team Messaging

**What it does:** A Slack-like team messaging system with public channels, private channels, and direct messages. Supports rich message content, threads, reactions, and unread tracking.

**Requirements:**

- Public channels (visible to all workspace members)
- Private channels (explicit membership required)
- Direct messages between two users
- Rich message blocks: text, @mentions, files, links, code, quotes, shared messages
- Thread replies on any message
- Emoji reactions on messages
- Unread count tracking per channel
- Typing indicators
- Message editing and deletion
- Message sharing between channels
- Infinite scroll with pagination
- Real-time updates via Supabase Realtime
- Mark channel as read

**Key Entities:** `channels`, `channel_members`, `channel_messages`, `message_reactions`, `channel_read_status`

---

### 3.6 Documents & Files

**What it does:** A Notion-style document and file management system with hierarchical folders, rich text notes, version history, file uploads to cloud storage, and sharing capabilities.

**Requirements:**

- Hierarchical folder structure (documents can be nested)
- Markdown/rich text notes via TipTap editor
- File uploads to Cloudflare R2 (presigned URLs, 50MB max)
- Drag-and-drop file and folder reordering
- Favorites and archive (soft-delete)
- Document version history (list, view, restore)
- Crash recovery — pending edits persisted to localStorage
- Optimistic locking for concurrent edits
- Public sharing via links with custom slugs
- Resource-level permissions (read/write/admin)
- Tag-based organization
- Search with full-text and vector embeddings
- Inline attachments within documents
- Breadcrumb navigation

**Key Entities:** `documents`, `document_versions`, `files`, `note_attachments`, `permissions`

---

### 3.7 Projects (Kanban)

**What it does:** A Linear-style Kanban project management system with boards, states, issues, labels, assignees, comments, and reactions.

**Requirements:**

- Multiple project boards per workspace
- Board states/columns (default: To Do, In Progress, Done)
- State reordering and custom state creation
- Issues with auto-incrementing numbers (e.g., PROJ-1, PROJ-2)
- Issue properties: priority, due date, description, position, images
- Drag-and-drop issue movement between states
- Issue reordering within a state
- Color-coded labels per board
- Assignees (max 10 per issue)
- GitHub-style comments on issues with block content
- Emoji reactions on comments
- Filtering by status, assignee, label, priority, due date
- Archived issues filter

**Key Entities:** `project_boards`, `project_states`, `project_issues`, `project_labels`, `project_issue_labels`, `project_issue_assignees`, `project_issue_comments`, `project_comment_reactions`

---

### 3.8 AI Agents

**What it does:** Users can create custom AI agents from templates or from scratch, deploy them in isolated E2B sandboxes, assign tasks, and monitor execution in real-time with step-by-step observability.

**Requirements:**

- Agent templates (pre-built archetypes)
- Custom agent creation with system prompt, tools, and configuration
- Agent avatar upload
- Deploy agents in E2B cloud sandboxes
- Pause/resume sandboxes (cost optimization)
- Invoke agents with task instructions (queued execution)
- Task tracking with status and results
- Step-by-step execution log for observability
- Agent conversations (persistent threads)
- Sandbox file browsing and reading
- Agent health monitoring (cron every 5 minutes)
- Destroy sandbox on agent deletion
- Workspace-scoped agents

**Key Entities:** `agent_templates`, `agent_instances`, `agent_tasks`, `agent_task_steps`, `agent_conversations`

---

### 3.9 AI App Builder

**What it does:** Users describe a web application in natural language, and the system generates React Native code with a live preview, version history, and deployment capability.

**Requirements:**

- Create projects via natural language prompts
- Stream code generation with status updates (NDJSON)
- Sandpack-based live code preview
- File tree management
- Version history
- Build error reporting
- Toggle between preview and code view
- Project archiving

**Key Entities:** Builder projects, versions, conversations

---

### 3.10 Notifications

**What it does:** A centralized notification system that tracks activity across all modules with unread counts, grouping, and per-resource subscriptions.

**Requirements:**

- Paginated notification feed
- Unread count badge
- Mark individual or all notifications as read
- Archive notifications
- Notification grouping (collapse similar events)
- Resource-level subscriptions (subscribe/unsubscribe)
- Per-user notification preferences (by workspace and category)
- Domain-specific notifications: calendar invites, file edits, etc.
- Navigation from notification to relevant content

**Key Entities:** `notifications`, `notification_subscriptions`, `notification_preferences`

---

### 3.11 Permissions & Sharing

**What it does:** A fine-grained sharing system that allows users to share resources with specific users, via shareable links, or publicly, with configurable access levels and expiry.

**Requirements:**

- Share resources with specific users by email
- Permission levels: read, write, admin
- Share links with optional custom slugs (like Notion)
- Public access option
- Expiring permissions
- Folder ancestry permission inheritance
- Batch sharing with multiple users
- Revoke shares and links
- Access request workflow:
  - User requests access to a restricted resource
  - Owner receives notification
  - Owner approves/denies
  - Auto-grants permission on approval
- User search for sharing
- Public resource viewing (no auth required for shared links)

**Key Entities:** `permissions`, `access_requests`

---

### 3.12 App Drawer

**What it does:** An AI-powered natural language input that classifies user intent and automatically creates the appropriate entry — a task, a calendar event, or an email.

**Requirements:**

- Accept natural language input
- AI classifies intent (task / calendar / email)
- Auto-creates the corresponding entry
- Health check endpoint

---

## 4. Cross-Cutting Capabilities

| Capability | Description |
|------------|-------------|
| **Multi-Account Unified View** | All email and calendar data from multiple Google/Microsoft accounts normalized into a single view |
| **Optimistic UI** | All major operations (messages, events, documents, reactions, shares) update instantly and rollback on failure |
| **Workspace-Level Caching** | Each workspace's data cached independently for instant workspace switching |
| **Realtime Presence** | Online status indicators via Supabase Realtime |
| **Keyboard Navigation** | Arrow key navigation in sidebars with focus management |
| **Crash Recovery** | Note edits persisted to localStorage and restored on reload |
| **Horizontal Prefetching** | Hovering sidebar icons prefetches target view data |
| **Offline Detection** | Toast notification when network is unavailable |
| **Feature Error Boundaries** | Each major feature wrapped in its own error boundary |
| **Structured Content** | Messages and documents use `content_parts` schema for rich, typed content |
| **Vector Search** | Semantic search on emails, documents, calendar events, and messages via pgvector HNSW |

---

## 5. External Integrations

| Service | Required | Purpose |
|---------|----------|---------|
| **Supabase** | Yes | PostgreSQL database, auth, realtime, RLS |
| **Anthropic Claude** | No (at least one AI provider needed) | Primary AI agent runtime |
| **OpenAI** | No | Chat agent, embeddings (1536-dim vectors) |
| **Groq** | No | AI email analysis |
| **Exa** | No | Web search in AI chat |
| **Google OAuth** | No | Gmail + Google Calendar sync |
| **Microsoft OAuth** | No | Outlook + M365 Calendar sync |
| **Cloudflare R2** | No | File storage (presigned uploads) |
| **Cloudflare Image Proxy** | No | HMAC-signed image resizing |
| **Cloudflare Turnstile** | No | Bot protection |
| **Upstash QStash** | No | Async job queue for sync workers |
| **Upstash Redis** | No | Distributed rate limiting |
| **Resend** | No | Transactional emails (invitations) |
| **E2B** | No | AI agent sandbox execution |
| **Sentry** | No | Error tracking + cron monitoring |
| **PostHog** | No | Analytics |

---

## 6. Data Model Summary

### Core Entities

| Entity | Description |
|--------|-------------|
| `users` | User profiles |
| `ext_connections` | OAuth connections with encrypted tokens |
| `user_preferences` | User settings (timezone, disabled tools, search prefs) |
| `push_subscriptions` | Webhook watches for email/calendar sync |

### Workspace System

| Entity | Description |
|--------|-------------|
| `workspaces` | Workspaces with owner, name, emoji, icon |
| `workspace_members` | Membership with roles (owner/admin/member) |
| `workspace_apps` | Mini-apps within workspaces |
| `workspace_app_members` | Explicit membership for private apps |
| `workspace_invitations` | Email-based invitations with tokens |

### Communication

| Entity | Description |
|--------|-------------|
| `emails` | Email storage with FTS, embeddings, AI analysis |
| `calendar_events` | Events with attendees, recurrence, meeting links |
| `conversations` | AI chat conversations |
| `messages` | Chat messages with structured content parts |
| `chat_attachments` | Chat message file attachments in R2 |
| `channels` | Team messaging channels (public/private/DM) |
| `channel_messages` | Channel messages with block content |
| `message_reactions` | Emoji reactions on messages |

### Content & Work

| Entity | Description |
|--------|-------------|
| `documents` | Hierarchical notes/folders with tags, FTS, embeddings |
| `document_versions` | Version history snapshots |
| `files` | File metadata with R2 storage keys |
| `project_boards` | Kanban boards |
| `project_states` | Board columns/states |
| `project_issues` | Issues/cards with priority, due dates |
| `project_labels` | Color-coded labels |
| `project_issue_comments` | Issue comments with reactions |

### AI & Automation

| Entity | Description |
|--------|-------------|
| `agent_templates` | Pre-built agent archetypes |
| `agent_instances` | Deployed agents with E2B sandbox state |
| `agent_tasks` | Task queue and execution log |
| `agent_task_steps` | Step-by-step execution steps |
| `agent_conversations` | Persistent agent conversation threads |

### System

| Entity | Description |
|--------|-------------|
| `notifications` | User notification feed with grouping |
| `notification_subscriptions` | Resource-level subscriptions |
| `notification_preferences` | Per-user notification settings |
| `permissions` | Resource-level sharing (user/link/public) |
| `access_requests` | Access request workflow |

---

## 7. Authentication & Authorization

### Authentication

- **Supabase Auth** — Primary identity provider (JWT-based)
- **better-auth** — Frontend session management
- **Google & Microsoft OAuth** — For external service connections
- **Token encryption** — OAuth tokens encrypted at rest with Fernet + key rotation
- **Multi-account** — Up to 5 email/calendar accounts per user
- **Cloudflare Turnstile** — Bot protection on auth flows

### Authorization Layers (in order)

1. **Row-Level Security (RLS)** — Database-level multi-tenant isolation on every table
2. **Workspace membership** — Roles: owner, admin, member
3. **Workspace app access** — Public apps (all members) vs private apps (explicit members)
4. **Resource-level permissions** — Fine-grained sharing (read/write/admin, user/link/public, with expiry)
5. **Channel access** — Public (all members), private (explicit membership), DMs (participant check)
6. **Cron/Worker auth** — HMAC-shared secrets + QStash signature verification

---

## 8. Sync & Realtime Infrastructure

### Email & Calendar Sync

```
Webhook (push notification)
  → Webhook endpoint validates & processes
    → QStash queue (batch fanout, deduplication)
      → Sync worker fetches from provider API
        → Upserts into local database
```

### Safety Nets

| Cron Job | Frequency | Purpose |
|----------|-----------|---------|
| Incremental sync | Every 15 min | Catch missed webhooks |
| Watch renewal | Every 6 hours | Renew expiring push subscriptions |
| Watch setup | Every hour | Ensure all users have active watches |
| Agent health | Every 5 minutes | Check E2B sandbox health |
| Email analysis | Every hour | AI analysis for unanalyzed emails |
| Cleanup uploads | Every hour | Clean incomplete presigned uploads |
| Cleanup chat attachments | Every hour | Clean incomplete chat attachments |

### Realtime

- **Supabase Realtime** — Live messaging, presence, file updates
- **NDJSON streaming** — AI chat responses, app builder generation
- **Webhook push** — Gmail Pub/Sub, Google Calendar push, Microsoft Graph subscriptions

---

## 9. Non-Functional Requirements

| Requirement | Detail |
|-------------|--------|
| **Multi-tenancy** | RLS-enforced workspace isolation at database layer |
| **Performance** | Presigned direct-to-R2 uploads (bypass backend for large files) |
| **Reliability** | Webhook-first sync with cron safety nets; optimistic UI with rollback |
| **Scalability** | Distributed rate limiting via Redis; async job queue via QStash |
| **Security** | JWT auth, encrypted OAuth tokens, RLS, share link tokens, HMAC-signed image URLs |
| **Observability** | Sentry error tracking + cron check-ins; PostHog analytics |
| **Availability** | Graceful degradation — only Supabase is required; all other services are optional |
| **Type Safety** | TypeScript frontend, Pydantic models backend, OpenAPI schema validation |
| **Testing** | Pytest suite with auto async mode; CI pipeline runs lint + typecheck + tests |
| **CI/CD** | GitHub Actions: API lint → typecheck → tests → OpenAPI validation → Web build |

---

## Appendix: Package Manager Commands

### Backend (`core-api`)

```
make start          # Dev server with auto-reload
make test           # Run pytest
make check          # Lint + typecheck
make lint           # Ruff linter
make format         # Ruff formatter
make typecheck      # Mypy
make test-openapi   # Validate OpenAPI schema
```

### Frontend (`core-web`)

```
npm run dev         # Vite dev server with HMR
npm run build       # TypeScript check + Vite build
npm run lint        # ESLint
npx tsc -b          # TypeScript type check
```

### Image Proxy (`core-image-proxy`)

```
npm run dev         # Local Cloudflare Worker
npm run deploy      # Deploy to Cloudflare
```
