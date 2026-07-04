import { useState } from "react";
import { setStoredApiToken, storedApiToken } from "../api/client";
import { ThemeToggle } from "../components/shell/ThemeToggle";
import { Button } from "../components/ui/Button";
import { Card, CardBody, CardHeader } from "../components/ui/Card";
import { Input, Label } from "../components/ui/Field";
import { PageHeader } from "../components/ui/PageHeader";
import { useToast } from "../lib/toast";

export function SettingsPage() {
  const toast = useToast();
  const [token, setToken] = useState(storedApiToken() ?? "");

  return (
    <>
      <PageHeader title="Settings" />
      <div className="flex max-w-xl flex-col gap-4">
        <Card>
          <CardHeader title="Appearance" />
          <CardBody className="flex jutify-start">
            <ThemeToggle />
          </CardBody>
        </Card>
        <Card>
          <CardHeader title="API key" />
          <CardBody className="flex flex-col gap-3">
            <p className="text-sm text-fg-muted">
              The key this console sends as a Bearer header (the runtime's{" "}
              <code className="font-mono">KATARI_API_KEY</code>). Clear it to
              sign out; if the runtime requires one, you will be prompted at the
              next request.
            </p>
            <Label text="Key">
              <Input
                type="password"
                value={token}
                onChange={(event) => setToken(event.target.value)}
                placeholder="none"
              />
            </Label>
            <div className="flex gap-2">
              <Button
                variant="primary"
                onClick={() => {
                  setStoredApiToken(token === "" ? null : token);
                  toast("Saved.");
                }}
              >
                Save
              </Button>
              <Button
                variant="secondary"
                disabled={token === ""}
                onClick={() => {
                  setToken("");
                  setStoredApiToken(null);
                  toast("Signed out.");
                }}
              >
                Sign out
              </Button>
            </div>
          </CardBody>
        </Card>
      </div>
    </>
  );
}
