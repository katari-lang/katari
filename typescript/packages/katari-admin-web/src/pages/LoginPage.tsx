import { useState, type FormEvent } from "react";
import { useNavigate, useLocation } from "react-router-dom";
import { motion } from "framer-motion";
import { ApiError, createApiClient } from "@/api/client";
import { useApiKey } from "@/contexts/ApiKeyContext";
import { Logo } from "@/components/shell/Logo";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Label } from "@/components/ui/Label";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/Card";

export function LoginPage() {
  const navigate = useNavigate();
  const location = useLocation();
  const { setApiKey: storeApiKey, baseUrl } = useApiKey();
  const [apiKey, setApiKey] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const client = createApiClient({ baseUrl, apiKey: apiKey.trim() });
      await client.listProjects({ limit: 1 });
      storeApiKey(apiKey.trim());
      const redirect = new URLSearchParams(location.search).get("redirect");
      navigate(redirect ?? "/projects", { replace: true });
    } catch (err) {
      if (err instanceof ApiError) {
        if (err.status === 401) {
          setError("Invalid API key.");
        } else {
          setError(err.message);
        }
      } else if (err instanceof TypeError) {
        setError(
          "Could not reach the API server. Make sure it is running on this origin.",
        );
      } else {
        setError(err instanceof Error ? err.message : "Unknown error.");
      }
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-6">
      <motion.div
        initial={{ opacity: 0, y: 8 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.25, ease: "easeOut" }}
        className="w-full max-w-md"
      >
        <Card>
          <CardHeader>
            <div className="mb-3">
              <Logo size="lg" />
            </div>
            <CardTitle>Sign in</CardTitle>
            <CardDescription>
              Enter the API key for this Katari runtime to manage projects, agents, and env entries.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <form onSubmit={handleSubmit} className="space-y-4">
              <div className="space-y-1.5">
                <Label htmlFor="apiKey">API key</Label>
                <Input
                  id="apiKey"
                  type="password"
                  required
                  autoComplete="off"
                  spellCheck={false}
                  value={apiKey}
                  onChange={(e) => setApiKey(e.target.value)}
                  placeholder="KATARI_API_KEY"
                  autoFocus
                />
              </div>
              <div className=" border border-border bg-muted/40 px-3 py-2 text-xs text-subtle-foreground">
                <span className="text-muted-foreground">Endpoint:</span>{" "}
                <span className="break-all font-mono text-foreground">{baseUrl}</span>
              </div>
              {error !== null && (
                <p className=" border border-danger/30 bg-danger/10 px-3 py-2 text-sm text-danger">
                  {error}
                </p>
              )}
              <Button type="submit" variant="primary" loading={loading} className="w-full">
                Sign in
              </Button>
            </form>
          </CardContent>
        </Card>
        <p className="mt-4 text-center text-xs text-subtle-foreground">
          The API key is stored in this browser's localStorage only.
        </p>
      </motion.div>
    </div>
  );
}
