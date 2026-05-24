import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { createApiClient, type ApiClient } from "@/api/client";

const STORAGE_KEY = "katari-admin.apiKey";

type ApiKeyContextValue = {
  apiKey: string | null;
  baseUrl: string;
  client: ApiClient | null;
  setApiKey: (key: string) => void;
  clear: () => void;
};

const ApiKeyContext = createContext<ApiKeyContextValue | null>(null);

/**
 * Derive the API base URL from where the SPA itself is served. The picker
 * was removed in favour of "same-origin only" (= each katari deployment
 * bakes the admin UI into its api-server image at /admin/*). If we ever
 * add CORS middleware to api-server, a configurable base URL can come
 * back as a Settings field.
 *
 * Dev (`vite dev` at :5173): the vite proxy rewrites `/api/*` to the
 * api-server, so we use `${origin}/api`.
 * Prod (baked into api-server image): admin is served from `/admin/`,
 * API is on the same origin without prefix.
 */
function defaultBaseUrl(): string {
  if (typeof window === "undefined") return "";
  if (import.meta.env.DEV) {
    return `${window.location.origin}/api`;
  }
  return window.location.origin;
}

export function ApiKeyProvider({ children }: { children: ReactNode }) {
  // Read localStorage synchronously in the initializer so the first render
  // already knows whether we have a session. Otherwise AuthGate sees null
  // on tick 0 and bounces to /login before the useEffect catches up.
  const [apiKey, setApiKeyState] = useState<string | null>(() => {
    if (typeof window === "undefined") return null;
    return window.localStorage.getItem(STORAGE_KEY);
  });
  const baseUrl = defaultBaseUrl();

  const setApiKey = useCallback((key: string) => {
    window.localStorage.setItem(STORAGE_KEY, key);
    setApiKeyState(key);
  }, []);

  const clear = useCallback(() => {
    window.localStorage.removeItem(STORAGE_KEY);
    setApiKeyState(null);
  }, []);

  const client = useMemo(() => {
    if (apiKey === null) return null;
    return createApiClient({ apiKey, baseUrl });
  }, [apiKey, baseUrl]);

  const value = useMemo(
    () => ({ apiKey, baseUrl, client, setApiKey, clear }),
    [apiKey, baseUrl, client, setApiKey, clear],
  );

  return (
    <ApiKeyContext.Provider value={value}>{children}</ApiKeyContext.Provider>
  );
}

export function useApiKey(): ApiKeyContextValue {
  const ctx = useContext(ApiKeyContext);
  if (ctx === null) {
    throw new Error("useApiKey must be used inside ApiKeyProvider");
  }
  return ctx;
}

export function useApiClient(): ApiClient {
  const { client } = useApiKey();
  if (client === null) {
    throw new Error(
      "useApiClient called without an authenticated session — guard with ApiKeyGate first",
    );
  }
  return client;
}
