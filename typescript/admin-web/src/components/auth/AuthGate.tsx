// The auth boundary for the console. The runtime enforces auth only when a KATARI_API_KEY is set, so the
// gate is reactive rather than eager: it renders the app straight away and only interposes a login screen
// once a request actually comes back 401 (reported through `lib/auth`). That way an unauthenticated dev
// runtime shows no login at all, while a secured one prompts the moment the first request is rejected.
//
// Signing in stores the token (sent as a Bearer header by the API layer) and validates it against a
// protected endpoint before letting the app back in, so a wrong key gives immediate feedback instead of a
// second bounce.

import { useQueryClient } from "@tanstack/react-query";
import { KeyRound } from "lucide-react";
import { type ReactNode, useEffect, useState } from "react";
import { ApiError, api, setStoredApiToken } from "../../api/client";
import { setUnauthorizedHandler } from "../../lib/auth";
import { Button } from "../ui/Button";
import { Input, Label } from "../ui/Field";

export function AuthGate({ children }: { children: ReactNode }) {
  const [locked, setLocked] = useState(false);

  useEffect(() => {
    setUnauthorizedHandler(() => setLocked(true));
    return () => setUnauthorizedHandler(null);
  }, []);

  if (!locked) return children;
  return <LoginScreen onSignedIn={() => setLocked(false)} />;
}

function LoginScreen({ onSignedIn }: { onSignedIn: () => void }) {
  const queryClient = useQueryClient();
  const [token, setToken] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const signIn = async () => {
    setBusy(true);
    setError(null);
    setStoredApiToken(token === "" ? null : token);
    try {
      // A protected endpoint (health is public, so it cannot validate the key). Success means the key is
      // accepted; drop the cached 401s and let the app re-fetch with the new credentials.
      await api.listProjects();
      await queryClient.invalidateQueries();
      onSignedIn();
    } catch (caught) {
      setStoredApiToken(null);
      setError(
        caught instanceof ApiError && caught.status === 401
          ? "That API key was not accepted."
          : caught instanceof Error
            ? caught.message
            : "Could not reach the runtime.",
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex min-h-dvh items-center justify-center bg-sunken p-6">
      <form
        className="flex w-full max-w-sm flex-col gap-4 rounded-xl border border-edge bg-surface p-6"
        onSubmit={(event) => {
          event.preventDefault();
          void signIn();
        }}
      >
        <div className="flex items-center gap-2 text-fg">
          <KeyRound className="size-5 text-accent" />
          <h1 className="text-lg font-semibold">Sign in to Katari</h1>
        </div>
        <p className="text-sm text-fg-muted">
          This runtime requires an API key. Enter the{" "}
          <code className="font-mono">KATARI_API_KEY</code> it was started with.
        </p>
        <Label text="API key">
          <Input
            type="password"
            autoFocus
            value={token}
            onChange={(event) => setToken(event.target.value)}
            placeholder="KATARI_API_KEY"
          />
        </Label>
        {error !== null && <p className="text-sm text-danger">{error}</p>}
        <Button type="submit" variant="primary" loading={busy} disabled={token === ""}>
          Sign in
        </Button>
      </form>
    </div>
  );
}
