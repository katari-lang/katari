// One open escalation, answerable in place. The runtime tells each surface how to render it via the
// `presentation` sum: a `form` escalation shows the question plus a schema-driven answer form (or the
// raw-JSON fallback, or a `never` badge when it cannot be answered), while an `oauth` escalation shows
// the MCP server that needs authorizing and an Authorize button that hands off to the runtime-hosted
// OAuth flow. Both close the same way — the run resumes and the card drops on the next inbox refetch.

import { KeyRound } from "lucide-react";
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useAnswerEscalation, useStartOauthFlow } from "../../api/queries";
import type { Escalation, Json, JsonSchema } from "../../api/types";
import { formatDateTime, relativeTime } from "../../lib/format";
import { useToast } from "../../lib/toast";
import { SchemaForm } from "../schema-form/SchemaForm";
import { Badge } from "../ui/Badge";
import { Button } from "../ui/Button";
import { Card, CardBody, CardHeader } from "../ui/Card";
import { CopyableId } from "../ui/Copy";
import { KeyValueList, KeyValueRow } from "../ui/KeyValue";
import { Spinner } from "../ui/Spinner";
import { ValueBlock } from "../values/ValueViewer";
import { FormContextForRun, useRunSnapshot } from "./run-snapshot";

export function EscalationCard({
  projectId,
  escalation,
  showRunLink = true,
}: {
  projectId: string;
  escalation: Escalation;
  showRunLink?: boolean;
}) {
  const { presentation } = escalation;
  return (
    <Card>
      <CardHeader
        title={
          <span className="inline-flex items-center gap-2 font-mono">
            {escalation.request}
            <CopyableId id={escalation.id} />
          </span>
        }
        actions={
          <span className="flex items-center gap-2 text-xs text-fg-faint">
            <span title={formatDateTime(escalation.createdAt)}>
              {relativeTime(escalation.createdAt)}
            </span>
            {showRunLink && (
              <Link
                to={`/projects/${projectId}/runs/${escalation.runId}`}
                className="text-accent hover:underline"
              >
                view run
              </Link>
            )}
          </span>
        }
      />
      {/* One dispatch on the presentation sum; each variant owns its whole card body. */}
      {presentation.kind === "form" ? (
        <FormBody
          projectId={projectId}
          escalation={escalation}
          answerSchema={presentation.answerSchema}
        />
      ) : (
        <OauthBody
          projectId={projectId}
          escalationId={escalation.id}
          name={presentation.name}
          url={presentation.url}
        />
      )}
    </Card>
  );
}

/** The schema-driven answer form: the question, then a form built from the request's answer schema
 *  (raw-JSON editor for schemaless requests), or a badge for `never`-typed requests that can only be
 *  resolved by cancelling the run. */
function FormBody({
  projectId,
  escalation,
  answerSchema,
}: {
  projectId: string;
  escalation: Escalation;
  answerSchema: JsonSchema | null;
}) {
  const toast = useToast();
  const answerMutation = useAnswerEscalation(projectId);
  const [answer, setAnswer] = useState<Json | undefined>(undefined);
  const snapshotId = useRunSnapshot(projectId, escalation.runId);

  const unanswerable = isNeverSchema(answerSchema);

  const submit = () => {
    answerMutation.mutate(
      { escalationId: escalation.id, value: answer ?? null },
      {
        onSuccess: () => toast("Answer sent."),
        onError: (error) => toast(error.message, "error"),
      },
    );
  };

  return (
    <CardBody className="flex flex-col gap-4">
      <div>
        <SectionLabel text="Question" />
        <ValueBlock value={escalation.argument} projectId={projectId} />
      </div>
      <div>
        <SectionLabel text="Answer" />
        {unanswerable ? (
          <Badge tone="danger">unanswerable (never) — cancel the run to resolve it</Badge>
        ) : (
          <div className="flex flex-col gap-3">
            <SchemaForm
              schema={answerSchema ?? {}}
              value={answer}
              onChange={setAnswer}
              context={FormContextForRun(projectId, snapshotId)}
            />
            <Button
              variant="primary"
              className="self-start"
              loading={answerMutation.isPending}
              onClick={submit}
            >
              Send answer
            </Button>
          </div>
        )}
      </div>
    </CardBody>
  );
}

/** Where the hand-off to the authorization window stands. `waiting` keeps the popup handle so the
 *  hint can clear itself when the user abandons the window; `blocked` keeps the minted URL so the
 *  user can follow it with a direct anchor click, which browsers never popup-block. */
type OauthHandoff =
  | { kind: "idle" }
  | { kind: "waiting"; popup: Window }
  | { kind: "blocked"; authorizationUrl: string };

/** The OAuth authorization variant: the credential that needs authorizing (and its server, when the
 *  credential names one — an mcp credential; a configured credential has a null url and shows only the
 *  name) and an Authorize button that hands off to the runtime-hosted flow. The runtime answers the
 *  escalation from its OAuth callback once the user completes the flow, so there is nothing to submit
 *  here — the card drops on the next inbox refetch. */
function OauthBody({
  projectId,
  escalationId,
  name,
  url,
}: {
  projectId: string;
  escalationId: string;
  name: string;
  url: string | null;
}) {
  const toast = useToast();
  const startFlow = useStartOauthFlow(projectId);
  const [handoff, setHandoff] = useState<OauthHandoff>({ kind: "idle" });

  // Clear the waiting hint when the user closes the authorization window without finishing: on
  // success the card disappears through the inbox refetch, so only abandonment needs this poll.
  useEffect(() => {
    if (handoff.kind !== "waiting") return;
    const interval = window.setInterval(() => {
      if (handoff.popup.closed) setHandoff({ kind: "idle" });
    }, 1000);
    return () => window.clearInterval(interval);
  }, [handoff]);

  const authorize = () => {
    // Open the popup synchronously inside the click so the browser attributes it to the user gesture;
    // a window opened only after the async POST resolves would be caught by the popup blocker. The
    // blank window then navigates to the authorization URL once the runtime has minted it. (No
    // `noopener` here — that would make `window.open` return null and we could not steer the window.)
    const popup = window.open("", "_blank");
    startFlow.mutate(escalationId, {
      onSuccess: ({ authorizationUrl }) => {
        if (popup === null) {
          // The browser blocked the popup despite the gesture. Never navigate the console itself to
          // the IdP — the round-trip would strand the user on the callback page with the console
          // gone. Instead surface the URL as an anchor: a direct click on it is a genuine user
          // gesture on a navigation, which no popup blocker intercepts.
          setHandoff({ kind: "blocked", authorizationUrl });
          return;
        }
        popup.location.href = authorizationUrl;
        setHandoff({ kind: "waiting", popup });
      },
      onError: (error) => {
        popup?.close();
        setHandoff({ kind: "idle" });
        toast(error.message, "error");
      },
    });
  };

  return (
    <CardBody className="flex flex-col gap-4">
      <div>
        <SectionLabel text="Authorization required" />
        <p className="text-sm text-fg-muted">
          This credential needs you to authorize access before the run can continue.
        </p>
      </div>
      <KeyValueList>
        <KeyValueRow label="Credential">
          <span className="font-mono">{name}</span>
        </KeyValueRow>
        {/* A configured credential names no server (url is null) — show the Server row only when present. */}
        {url !== null && (
          <KeyValueRow label="Server">
            <span className="font-mono break-all">{url}</span>
          </KeyValueRow>
        )}
      </KeyValueList>
      <div className="flex items-center gap-3">
        <Button
          variant="primary"
          className="self-start"
          loading={startFlow.isPending}
          onClick={authorize}
        >
          <KeyRound className="size-3.5" />
          {handoff.kind === "idle" ? "Authorize" : "Re-authorize"}
        </Button>
        {/* Restarting the flow is always safe, so the button stays live in every hand-off state; the
            hint beside it says what the last attempt is waiting on. */}
        {handoff.kind === "waiting" && !startFlow.isPending && (
          <span className="inline-flex items-center gap-1.5 text-xs text-fg-faint">
            <Spinner className="size-3" />
            waiting for authorization…
          </span>
        )}
        {handoff.kind === "blocked" && !startFlow.isPending && (
          <span className="text-xs text-fg-faint">
            popup was blocked — open the{" "}
            <a
              href={handoff.authorizationUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="text-accent hover:underline"
            >
              authorization page
            </a>
          </span>
        )}
      </div>
    </CardBody>
  );
}

function SectionLabel({ text }: { text: string }) {
  return <p className="pb-1.5 text-xs font-medium text-fg-faint uppercase">{text}</p>;
}

function isNeverSchema(schema: JsonSchema | null): boolean {
  // `never` canonicalises to an unsatisfiable schema ({"not": {}} or false-like shapes).
  if (schema === null) return false;
  return "not" in schema && JSON.stringify(schema.not) === "{}";
}
