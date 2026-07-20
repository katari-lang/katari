// OAuth credentials + the registered clients they authenticate as. Two resources on one page:
//
//   - Credentials: the stored OAuth tokens (metadata only — token material is write-only, deposited by the
//     runtime-hosted flow). Each can be re-authorized (a proactive login: configured credentials log in
//     directly against their registered client; an mcp credential prompts for its server URL) or forgotten.
//   - Registered OAuth clients: the operator-registered clients a `configured` credential authenticates as
//     (endpoints, client id, an optional write-only secret, scopes). Register / delete here, and "Log in"
//     to establish (or refresh) the credential for a client's name.
//
// The login hand-off reuses the popup-safe `window.open` pattern from EscalationCard: a blank popup is
// opened synchronously inside the click (so the browser attributes it to the gesture), then navigated to
// the minted authorization URL once the runtime returns it; a blocked popup falls back to a direct anchor.

import { useQueryClient } from "@tanstack/react-query";
import { KeyRound, LogIn, Plus, RotateCw, Trash2 } from "lucide-react";
import { useState } from "react";
import { useParams } from "react-router-dom";
import { ApiError, api } from "../api/client";
import { useCredentials, useOauthClients } from "../api/queries";
import type { OauthClient } from "../api/types";
import { Badge } from "../components/ui/Badge";
import { Button } from "../components/ui/Button";
import { Card } from "../components/ui/Card";
import { ConfirmDialog, Dialog } from "../components/ui/Dialog";
import { EmptyState } from "../components/ui/EmptyState";
import { Input, Label, Switch } from "../components/ui/Field";
import { PageHeader } from "../components/ui/PageHeader";
import { LoadingBlock } from "../components/ui/Spinner";
import { Cell, Row, Table } from "../components/ui/Table";
import { formatDateTime } from "../lib/format";
import { useToast } from "../lib/toast";

export function CredentialsPage() {
  const { projectId = "" } = useParams();
  const credentials = useCredentials(projectId);
  const clients = useOauthClients(projectId);
  const queryClient = useQueryClient();

  const refreshCredentials = () =>
    queryClient.invalidateQueries({ queryKey: ["projects", projectId, "credentials"] });
  const refreshClients = () =>
    queryClient.invalidateQueries({ queryKey: ["projects", projectId, "oauth-clients"] });

  return (
    <>
      <PageHeader
        title="Credentials"
        description="OAuth credentials and the clients they authenticate as."
      />

      <h2 className="mb-2 mt-2 text-sm font-medium text-fg-muted">Stored credentials</h2>
      {credentials.isPending ? (
        <LoadingBlock />
      ) : (credentials.data ?? []).length === 0 ? (
        <EmptyState
          icon={KeyRound}
          title="No credentials yet"
          description="Log in to a registered client below, or run a workflow that needs one."
        />
      ) : (
        <Card>
          <Table headers={["Name", "Profile", "Updated", ""]}>
            {(credentials.data ?? []).map((credential) => (
              <Row key={credential.name}>
                <Cell className="font-mono text-xs font-medium">{credential.name}</Cell>
                <Cell>
                  <Badge tone="neutral">{credential.profile}</Badge>
                </Cell>
                <Cell className="text-fg-muted">{formatDateTime(credential.updatedAt)}</Cell>
                <Cell className="text-right whitespace-nowrap">
                  <span className="inline-flex items-center gap-1">
                    <ReauthorizeButton
                      projectId={projectId}
                      name={credential.name}
                      profile={credential.profile}
                    />
                    <ForgetButton
                      projectId={projectId}
                      name={credential.name}
                      onForgotten={refreshCredentials}
                    />
                  </span>
                </Cell>
              </Row>
            ))}
          </Table>
        </Card>
      )}

      <div className="mt-8 mb-2 flex items-center justify-between">
        <h2 className="text-sm font-medium text-fg-muted">Registered OAuth clients</h2>
        <RegisterClientButton projectId={projectId} onSaved={refreshClients} />
      </div>
      {clients.isPending ? (
        <LoadingBlock />
      ) : (clients.data ?? []).length === 0 ? (
        <EmptyState
          icon={KeyRound}
          title="No OAuth clients registered"
          description="Register a client, then log in to store a credential."
        />
      ) : (
        <Card>
          <Table headers={["Name", "Issuer", "Client ID", "Secret", ""]}>
            {(clients.data ?? []).map((client) => (
              <Row key={client.name}>
                <Cell className="font-mono text-xs font-medium">{client.name}</Cell>
                <Cell
                  className="max-w-48 truncate font-mono text-xs text-fg-muted"
                  title={client.issuer}
                >
                  {client.issuer}
                </Cell>
                <Cell
                  className="max-w-56 truncate font-mono text-xs text-fg-muted"
                  title={client.clientId}
                >
                  {client.clientId}
                </Cell>
                <Cell>
                  {client.hasSecret ? (
                    <Badge tone="danger">secret · write-only</Badge>
                  ) : (
                    <Badge tone="neutral">public</Badge>
                  )}
                </Cell>
                <Cell className="text-right whitespace-nowrap">
                  <span className="inline-flex items-center gap-1">
                    <LoginButton
                      label="Log in"
                      icon={LogIn}
                      start={() => api.loginCredential(projectId, client.name)}
                    />
                    <DeleteClientButton
                      projectId={projectId}
                      name={client.name}
                      onDeleted={refreshClients}
                    />
                  </span>
                </Cell>
              </Row>
            ))}
          </Table>
        </Card>
      )}
    </>
  );
}

/** Where the hand-off to the authorization window stands. `blocked` keeps the minted URL so the user can
 *  follow it with a direct anchor click, which browsers never popup-block (mirrors EscalationCard). */
type LoginHandoff = { kind: "idle" } | { kind: "blocked"; authorizationUrl: string };

/** A popup-safe login button: opens a blank popup synchronously inside the click, then navigates it to the
 *  authorization URL `start` mints. A blocked popup surfaces the URL as an anchor instead. */
function LoginButton({
  label,
  icon: Icon,
  start,
  variant = "ghost",
}: {
  label: string;
  icon: typeof LogIn;
  start: () => Promise<{ authorizationUrl: string }>;
  variant?: "primary" | "ghost";
}) {
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const [handoff, setHandoff] = useState<LoginHandoff>({ kind: "idle" });

  const authorize = () => {
    // Open the popup synchronously inside the click so the browser attributes it to the user gesture; a
    // window opened only after the async POST resolves would be caught by the popup blocker.
    const popup = window.open("", "_blank");
    setBusy(true);
    start()
      .then(({ authorizationUrl }) => {
        if (popup === null) {
          setHandoff({ kind: "blocked", authorizationUrl });
          return;
        }
        popup.location.href = authorizationUrl;
        setHandoff({ kind: "idle" });
      })
      .catch((error: unknown) => {
        popup?.close();
        toast(error instanceof ApiError ? error.message : "Login failed.", "error");
      })
      .finally(() => setBusy(false));
  };

  return (
    <span className="inline-flex items-center gap-1.5">
      <Button size="sm" variant={variant} loading={busy} onClick={authorize}>
        <Icon className="size-3.5" /> {label}
      </Button>
      {handoff.kind === "blocked" && (
        <a
          href={handoff.authorizationUrl}
          target="_blank"
          rel="noopener noreferrer"
          className="text-xs text-accent hover:underline"
        >
          popup blocked — open
        </a>
      )}
    </span>
  );
}

/** Re-authorize a stored credential, dispatching on the RETURNED acquisition profile (the runtime's
 *  discriminant column — never a name-match heuristic): a `configured` credential logs in directly
 *  against its registered client; an `mcp` one prompts for its server URL first (a fresh mcp login
 *  needs the server). */
function ReauthorizeButton({
  projectId,
  name,
  profile,
}: {
  projectId: string;
  name: string;
  profile: "mcp" | "configured";
}) {
  const [prompting, setPrompting] = useState(false);
  if (profile === "configured") {
    return (
      <LoginButton
        label="Re-authorize"
        icon={RotateCw}
        start={() => api.loginCredential(projectId, name)}
      />
    );
  }
  return (
    <>
      <Button size="sm" variant="ghost" onClick={() => setPrompting(true)}>
        <RotateCw className="size-3.5" /> Re-authorize
      </Button>
      {prompting && (
        <McpLoginDialog projectId={projectId} name={name} onClose={() => setPrompting(false)} />
      )}
    </>
  );
}

/** The mcp re-auth dialog: collect the server URL, then hand off popup-safely from the Authorize click. */
function McpLoginDialog({
  projectId,
  name,
  onClose,
}: {
  projectId: string;
  name: string;
  onClose: () => void;
}) {
  const [url, setUrl] = useState("");
  return (
    <Dialog open onClose={onClose} title={`Re-authorize ${name}`}>
      <div className="flex flex-col gap-3">
        <Label text="Server URL" hint="OAuth endpoints are discovered from it">
          <Input
            value={url}
            onChange={(event) => setUrl(event.target.value)}
            placeholder="https://mcp.example.com/mcp"
          />
        </Label>
        <div className="flex justify-end gap-2 pt-1">
          <Button onClick={onClose}>Cancel</Button>
          {url !== "" && (
            <LoginButton
              label="Authorize"
              icon={LogIn}
              variant="primary"
              start={() => api.loginCredential(projectId, name, url)}
            />
          )}
        </div>
      </div>
    </Dialog>
  );
}

function ForgetButton({
  projectId,
  name,
  onForgotten,
}: {
  projectId: string;
  name: string;
  onForgotten: () => void;
}) {
  const toast = useToast();
  const [confirming, setConfirming] = useState(false);
  return (
    <>
      <Button size="sm" variant="ghost" onClick={() => setConfirming(true)}>
        <Trash2 className="size-3.5" />
      </Button>
      <ConfirmDialog
        open={confirming}
        onClose={() => setConfirming(false)}
        onConfirm={() => {
          api
            .forgetCredential(projectId, name)
            .then(() => {
              setConfirming(false);
              onForgotten();
            })
            .catch((error: unknown) =>
              toast(error instanceof ApiError ? error.message : "Forget failed.", "error"),
            );
        }}
        title={`Forget ${name}?`}
        description="The next use of this credential will pause the run and ask to authorize again."
        confirmLabel="Forget"
      />
    </>
  );
}

function DeleteClientButton({
  projectId,
  name,
  onDeleted,
}: {
  projectId: string;
  name: string;
  onDeleted: () => void;
}) {
  const toast = useToast();
  const [confirming, setConfirming] = useState(false);
  return (
    <>
      <Button size="sm" variant="ghost" onClick={() => setConfirming(true)}>
        <Trash2 className="size-3.5" />
      </Button>
      <ConfirmDialog
        open={confirming}
        onClose={() => setConfirming(false)}
        onConfirm={() => {
          api
            .deleteOauthClient(projectId, name)
            .then(() => {
              setConfirming(false);
              onDeleted();
            })
            .catch((error: unknown) =>
              toast(error instanceof ApiError ? error.message : "Delete failed.", "error"),
            );
        }}
        title={`Delete client ${name}?`}
        description="A configured credential naming this client can no longer refresh until it is re-registered."
        confirmLabel="Delete"
      />
    </>
  );
}

function RegisterClientButton({ projectId, onSaved }: { projectId: string; onSaved: () => void }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <Button variant="primary" onClick={() => setOpen(true)}>
        <Plus className="size-4" /> Register client
      </Button>
      {open && (
        <RegisterClientDialog
          projectId={projectId}
          onClose={() => setOpen(false)}
          onSaved={() => {
            setOpen(false);
            onSaved();
          }}
        />
      )}
    </>
  );
}

/** The register form — the full desired state of one client (an idempotent PUT). Leaving the secret blank
 *  registers a public client (a genuine absence, PKCE only); scopes are space-separated. */
function RegisterClientDialog({
  projectId,
  onClose,
  onSaved,
}: {
  projectId: string;
  onClose: () => void;
  onSaved: () => void;
}) {
  const toast = useToast();
  const [form, setForm] = useState<OauthClient & { clientSecret: string }>({
    name: "",
    issuer: "",
    authorizeEndpoint: "",
    tokenEndpoint: "",
    clientId: "",
    clientSecret: "",
    hasSecret: false,
    scopes: [],
    authorizationParameters: {},
  });
  const [scopesText, setScopesText] = useState("");
  const [parametersText, setParametersText] = useState("");
  const [removeSecret, setRemoveSecret] = useState(false);
  const [busy, setBusy] = useState(false);
  const update = (patch: Partial<typeof form>) => setForm((current) => ({ ...current, ...patch }));

  const save = async () => {
    setBusy(true);
    try {
      // The secret is write-only, so a blank field means "keep whatever is stored" (nothing, on a fresh
      // registration); the explicit removeSecret switch is the deliberate downgrade to a public client.
      await api.setOauthClient(projectId, form.name, {
        issuer: form.issuer,
        authorizeEndpoint: form.authorizeEndpoint,
        tokenEndpoint: form.tokenEndpoint,
        clientId: form.clientId,
        ...(removeSecret || form.clientSecret === "" ? {} : { clientSecret: form.clientSecret }),
        clearSecret: removeSecret,
        scopes: scopesText.split(/[\s,]+/).filter((scope) => scope !== ""),
        authorizationParameters: parseKeyValuePairs(parametersText),
      });
      onSaved();
    } catch (error) {
      toast(error instanceof ApiError ? error.message : "Save failed.", "error");
    } finally {
      setBusy(false);
    }
  };

  const incomplete =
    form.name === "" ||
    form.issuer === "" ||
    form.authorizeEndpoint === "" ||
    form.tokenEndpoint === "" ||
    form.clientId === "";

  return (
    <Dialog open onClose={onClose} title="Register OAuth client" width="wide">
      <div className="flex flex-col gap-3">
        <Label text="Name">
          <Input
            value={form.name}
            onChange={(event) => update({ name: event.target.value })}
            placeholder="stripe"
          />
        </Label>
        <Label text="Issuer">
          <Input
            value={form.issuer}
            onChange={(event) => update({ issuer: event.target.value })}
            placeholder="https://auth.example.com"
          />
        </Label>
        <Label text="Authorization endpoint">
          <Input
            value={form.authorizeEndpoint}
            onChange={(event) => update({ authorizeEndpoint: event.target.value })}
            placeholder="https://auth.example.com/oauth/authorize"
          />
        </Label>
        <Label text="Token endpoint">
          <Input
            value={form.tokenEndpoint}
            onChange={(event) => update({ tokenEndpoint: event.target.value })}
            placeholder="https://auth.example.com/oauth/token"
          />
        </Label>
        <Label text="Client ID">
          <Input
            value={form.clientId}
            onChange={(event) => update({ clientId: event.target.value })}
          />
        </Label>
        <Label
          text="Client secret"
          hint="write-only; blank keeps the stored one (none = public client)"
        >
          <Input
            type="password"
            value={form.clientSecret}
            disabled={removeSecret}
            onChange={(event) => update({ clientSecret: event.target.value })}
          />
        </Label>
        <Switch
          checked={removeSecret}
          onChange={setRemoveSecret}
          label="Remove secret (public client)"
        />
        <Label text="Scopes" hint="space-separated">
          <Input
            value={scopesText}
            onChange={(event) => setScopesText(event.target.value)}
            placeholder="read write"
          />
        </Label>
        <Label
          text="Extra authorize parameters"
          hint="key=value, space-separated; appended to the authorization URL"
        >
          <Input
            value={parametersText}
            onChange={(event) => setParametersText(event.target.value)}
            placeholder="access_type=offline prompt=consent"
          />
        </Label>
        <div className="flex justify-end gap-2 pt-1">
          <Button onClick={onClose}>Cancel</Button>
          <Button
            variant="primary"
            disabled={incomplete}
            loading={busy}
            onClick={() => void save()}
          >
            Register
          </Button>
        </div>
      </div>
    </Dialog>
  );
}

/** Parse a `key=value` list (whitespace / newline separated pairs) into a record. A token without an `=`
 *  is skipped rather than erroring — the field is free-form and a half-typed pair should not block the
 *  register button; the value may itself contain `=` (split at the first only). */
function parseKeyValuePairs(text: string): Record<string, string> {
  const parameters: Record<string, string> = {};
  for (const token of text.split(/\s+/)) {
    const separator = token.indexOf("=");
    if (separator <= 0) continue;
    parameters[token.slice(0, separator)] = token.slice(separator + 1);
  }
  return parameters;
}
