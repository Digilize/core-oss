import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import { authClient } from '../lib/auth-client';
import { API_BASE } from '../lib/apiBase';
import { trackEvent } from '../lib/posthog';

// UserProfile type (avoid circular import with client.ts)
export interface UserProfile {
  id: string;
  email: string;
  name?: string;
  avatar_url?: string;
  onboarding_completed_at?: string | null;
}

// Local types matching better-auth's opaque session shape
interface BetterAuthUser {
  id: string;
  email: string;
  name: string;
  image?: string | null;
  emailVerified: boolean;
  createdAt: Date;
  updatedAt: Date;
}

interface BetterAuthSession {
  id: string;
  token: string;
  userId: string;
  expiresAt: Date;
  createdAt: Date;
  updatedAt: Date;
  user: BetterAuthUser;
}

interface AuthState {
  user: BetterAuthUser | null;
  session: BetterAuthSession | null;
  userProfile: UserProfile | null;
  isLoading: boolean;
  isAuthenticated: boolean;
  // undefined = not yet loaded (wait), null = loaded + not completed, string = completed
  onboardingCompletedAt: string | null | undefined;

  // Actions
  initialize: () => Promise<void>;
  signInWithEmail: (email: string, password: string) => Promise<void>;
  signInWithGoogle: (redirectToOrEvent?: unknown) => Promise<void>;
  signInWithMicrosoft: (redirectToOrEvent?: unknown) => Promise<void>;
  signUpWithEmail: (email: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
  getAccessToken: () => string | null;
  fetchUserProfile: () => Promise<void>;
  updateAvatarUrl: (avatarUrl: string | null) => void;
  updateUserName: (name: string) => Promise<void>;
  completeOnboarding: () => Promise<void>;
}

let fetchProfilePromise: Promise<void> | null = null;

export const useAuthStore = create<AuthState>()(
  persist(
    (set, get) => ({
      user: null,
      session: null,
      userProfile: null,
      isLoading: true,
      isAuthenticated: false,
      onboardingCompletedAt: undefined,

      initialize: async () => {
        try {
          const result = await authClient.getSession();
          const session = (result.data?.session ?? null) as BetterAuthSession | null;
          const user = (result.data?.user ?? null) as BetterAuthUser | null;

          set({
            user,
            session,
            isAuthenticated: !!session,
            isLoading: false,
          });

          if (session) {
            void get().fetchUserProfile();
          }
        } catch (err) {
          console.error('Auth initialization error:', err);
          set({ isLoading: false });
        }
      },

      signInWithEmail: async (email, password) => {
        const result = await authClient.signIn.email({ email, password });
        if (result.error) throw new Error(result.error.message ?? 'Sign in failed');

        const session = (result.data?.session ?? null) as BetterAuthSession | null;
        const user = (result.data?.user ?? null) as BetterAuthUser | null;

        set({ user, session, isAuthenticated: !!session });
        trackEvent('signed_in', { method: 'email' });
        if (session) void get().fetchUserProfile();
      },

      signInWithGoogle: async () => {
        // OAuth login is deferred — not yet supported
        throw new Error('Google sign-in is not yet available.');
      },

      signInWithMicrosoft: async () => {
        // OAuth login is deferred — not yet supported
        throw new Error('Microsoft sign-in is not yet available.');
      },

      signUpWithEmail: async (email, password) => {
        const name = email.split('@')[0];
        const result = await authClient.signUp.email({ email, password, name });
        if (result.error) throw new Error(result.error.message ?? 'Sign up failed');

        const session = (result.data?.session ?? null) as BetterAuthSession | null;
        const user = (result.data?.user ?? null) as BetterAuthUser | null;

        set({ user, session, isAuthenticated: !!session });
        trackEvent('signed_up', { method: 'email' });
        if (session) void get().fetchUserProfile();
      },

      signOut: async () => {
        trackEvent('signed_out');
        await authClient.signOut();
        set({
          user: null,
          session: null,
          userProfile: null,
          isAuthenticated: false,
          onboardingCompletedAt: undefined,
        });
      },

      getAccessToken: () => {
        return get().session?.token ?? null;
      },

      fetchUserProfile: async () => {
        if (fetchProfilePromise) return fetchProfilePromise;

        const token = get().session?.token;
        if (!token) return;

        fetchProfilePromise = (async () => {
          try {
            const response = await fetch(`${API_BASE}/users/me`, {
              headers: {
                'Content-Type': 'application/json',
                Authorization: `Bearer ${token}`,
              },
            });
            if (response.ok) {
              const profile = await response.json() as UserProfile;
              set({
                userProfile: profile,
                onboardingCompletedAt: profile.onboarding_completed_at ?? null,
              });
            }
          } catch (err) {
            console.error('Failed to fetch user profile:', err);
          } finally {
            fetchProfilePromise = null;
          }
        })();

        return fetchProfilePromise;
      },

      updateAvatarUrl: (avatarUrl) => {
        const currentProfile = get().userProfile;
        if (currentProfile) {
          set({
            userProfile: {
              ...currentProfile,
              avatar_url: avatarUrl ?? undefined,
            },
          });
        }
      },

      updateUserName: async (name) => {
        const token = get().session?.token;
        if (!token) throw new Error('No auth token');

        const response = await fetch(`${API_BASE}/users/me`, {
          method: 'PATCH',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify({ name }),
        });

        if (!response.ok) {
          throw new Error(`Failed to update user name (${response.status})`);
        }

        const currentProfile = get().userProfile;
        if (currentProfile) {
          set({ userProfile: { ...currentProfile, name } });
        }
      },

      completeOnboarding: async () => {
        const token = get().session?.token;
        if (!token) throw new Error('No auth token');

        const timestamp = new Date().toISOString();
        const response = await fetch(`${API_BASE}/users/me`, {
          method: 'PATCH',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify({ onboarding_completed_at: timestamp }),
        });

        if (!response.ok) {
          throw new Error(`Failed to complete onboarding (${response.status})`);
        }

        const currentProfile = get().userProfile;
        if (currentProfile) {
          set({
            userProfile: { ...currentProfile, onboarding_completed_at: timestamp },
            onboardingCompletedAt: timestamp,
          });
        }
      },
    }),
    {
      name: 'core-auth-storage',
      partialize: (state) => ({
        // Persist isAuthenticated as a hint for instant redirect on page load
        isAuthenticated: state.isAuthenticated,
        // Persist onboarding status so new users are immediately redirected on reload
        // without waiting for profile fetch. undefined=unknown, null=not done, string=done.
        onboardingCompletedAt: state.onboardingCompletedAt,
      }),
    }
  )
);
