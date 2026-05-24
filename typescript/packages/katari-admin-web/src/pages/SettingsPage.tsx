import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { useTheme } from "next-themes";
import toast from "react-hot-toast";
import { Monitor, Moon, Sun } from "lucide-react";
import { useApiKey } from "@/contexts/ApiKeyContext";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Label } from "@/components/ui/Label";
import { cn } from "@/lib/cn";

export function SettingsPage() {
  const { apiKey, baseUrl, setApiKey, clear } = useApiKey();
  const { theme, setTheme } = useTheme();
  const navigate = useNavigate();

  const [draftKey, setDraftKey] = useState(apiKey ?? "");

  function saveKey() {
    setApiKey(draftKey.trim());
    toast.success("API key updated");
  }

  function signOut() {
    clear();
    navigate("/login");
  }

  return (
    <div>
      <PageHeader
        title="Settings"
        description="Theme + API key for this runtime. All stored in this browser's localStorage."
      />
      <PageContent>
        <div className="grid gap-4 lg:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle>Theme</CardTitle>
              <CardDescription>Pick the system, light, or dark variant.</CardDescription>
            </CardHeader>
            <CardContent>
              <div className="flex gap-2">
                <ThemeOption
                  active={theme === "system"}
                  onClick={() => setTheme("system")}
                  icon={<Monitor className="size-4" />}
                  label="System"
                />
                <ThemeOption
                  active={theme === "light"}
                  onClick={() => setTheme("light")}
                  icon={<Sun className="size-4" />}
                  label="Light"
                />
                <ThemeOption
                  active={theme === "dark"}
                  onClick={() => setTheme("dark")}
                  icon={<Moon className="size-4" />}
                  label="Dark"
                />
              </div>
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle>API key</CardTitle>
              <CardDescription>
                Bearer token sent with every request to{" "}
                <span className="font-mono text-foreground">{baseUrl}</span>.
              </CardDescription>
            </CardHeader>
            <CardContent>
              <form
                onSubmit={(e) => {
                  e.preventDefault();
                  saveKey();
                }}
                className="space-y-3"
              >
                <div className="space-y-1.5">
                  <Label htmlFor="settings-key">API key</Label>
                  <Input
                    id="settings-key"
                    type="password"
                    value={draftKey}
                    onChange={(e) => setDraftKey(e.target.value)}
                  />
                </div>
                <div className="flex items-center justify-between pt-2">
                  <Button type="button" variant="ghost" onClick={signOut}>
                    Sign out
                  </Button>
                  <Button type="submit" variant="primary">Save</Button>
                </div>
              </form>
            </CardContent>
          </Card>
        </div>
      </PageContent>
    </div>
  );
}

function ThemeOption({
  active,
  onClick,
  icon,
  label,
}: {
  active: boolean;
  onClick: () => void;
  icon: React.ReactNode;
  label: string;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "flex flex-1 items-center gap-2  border px-3 py-2 text-sm transition-colors hover:cursor-pointer",
        active
          ? "border-accent bg-accent text-accent-foreground"
          : "border-border  text-muted-foreground hover:bg-muted hover:text-foreground",
      )}
    >
      {icon}
      {label}
    </button>
  );
}
