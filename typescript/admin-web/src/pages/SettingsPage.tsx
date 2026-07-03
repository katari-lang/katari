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
          <CardBody>
            <ThemeToggle />
          </CardBody>
        </Card>
        <Card>
          <CardHeader title="API token" />
          <CardBody className="flex flex-col gap-3">
            <p className="text-sm text-fg-muted">
              The runtime itself is unauthenticated; set a token only when this console reaches it
              through an authenticating proxy. It is sent as a Bearer header with every request.
            </p>
            <Label text="Token">
              <Input
                type="password"
                value={token}
                onChange={(event) => setToken(event.target.value)}
                placeholder="none"
              />
            </Label>
            <Button
              variant="primary"
              className="self-start"
              onClick={() => {
                setStoredApiToken(token === "" ? null : token);
                toast("Saved.");
              }}
            >
              Save
            </Button>
          </CardBody>
        </Card>
      </div>
    </>
  );
}
