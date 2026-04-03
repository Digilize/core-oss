import { createAuthClient } from 'better-auth/react';

const AUTH_BASE = import.meta.env.VITE_AUTH_URL || 'http://localhost:3001';

export const authClient = createAuthClient({
  baseURL: AUTH_BASE,
});

export type AuthSession = (typeof authClient.$Infer)['Session']['session'];
export type AuthUser = (typeof authClient.$Infer)['Session']['user'];
