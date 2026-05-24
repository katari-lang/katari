import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { useTheme } from "next-themes";
import Editor from "@monaco-editor/react";
import toast from "react-hot-toast";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { Dialog, DialogFooter } from "@/components/ui/Dialog";
import { Button } from "@/components/ui/Button";
import type { EscalationWire } from "@/api/types";
import type { RawValue } from "@katari-lang/runtime";
import { ValueViewer } from "./ValueViewer";

type Props = {
  escalation: EscalationWire | null;
  open: boolean;
  onClose: () => void;
};

const DEFAULT_TEMPLATE = `{
  "kind": "string",
  "value": ""
}`;

export function EscalationAnswerDialog({ escalation, open, onClose }: Props) {
  const client = useApiClient();
  const queryClient = useQueryClient();
  const { resolvedTheme } = useTheme();
  const [text, setText] = useState(DEFAULT_TEMPLATE);
  const [error, setError] = useState<string | null>(null);

  const answer = useMutation({
    mutationFn: async () => {
      if (escalation === null) throw new Error("No escalation");
      let parsed: unknown;
      try {
        parsed = JSON.parse(text);
      } catch (e) {
        throw new Error(e instanceof Error ? e.message : "Invalid JSON");
      }
      await client.answerEscalation(escalation.escalationId, parsed as RawValue);
    },
    onSuccess: () => {
      toast.success("Escalation answered");
      void queryClient.invalidateQueries({ queryKey: ["escalations"] });
      onClose();
      setText(DEFAULT_TEMPLATE);
    },
    onError: (err) => {
      toast.error(err instanceof Error ? err.message : "Failed.");
    },
  });

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title="Answer escalation"
      description={
        escalation !== null ? (
          <span className="font-mono">{escalation.agentDefId}</span>
        ) : null
      }
      size="lg"
    >
      {escalation !== null && (
        <div className="space-y-4">
          <div>
            <h3 className="mb-2 text-xs uppercase tracking-wider text-subtle-foreground">
              Args sent by the agent
            </h3>
            <ValueViewer value={escalation.args} className="max-h-40" />
          </div>
          <div>
            <h3 className="mb-2 text-xs uppercase tracking-wider text-subtle-foreground">
              Your answer (raw JSON Value)
            </h3>
            <div className="overflow-hidden  border border-border-strong ">
              <Editor
                height="220px"
                defaultLanguage="json"
                theme={resolvedTheme === "dark" ? "vs-dark" : "light"}
                value={text}
                options={{
                  minimap: { enabled: false },
                  fontSize: 13,
                  scrollBeyondLastLine: false,
                  wordWrap: "on",
                }}
                onChange={(next) => {
                  const v = next ?? "";
                  setText(v);
                  try {
                    JSON.parse(v);
                    setError(null);
                  } catch (e) {
                    setError(e instanceof Error ? e.message : "Invalid JSON");
                  }
                }}
              />
            </div>
            {error !== null && <p className="mt-1 text-xs text-danger">{error}</p>}
            <p className="mt-2 text-xs text-subtle-foreground">
              Provide a runtime Value (e.g. <code className="font-mono">{`{"kind":"string","value":"hello"}`}</code>) matching the response type the agent expects.
            </p>
          </div>
        </div>
      )}
      <DialogFooter>
        <Button variant="secondary" onClick={onClose}>
          Cancel
        </Button>
        <Button
          variant="primary"
          onClick={() => answer.mutate()}
          loading={answer.isPending}
          disabled={error !== null}
        >
          Submit answer
        </Button>
      </DialogFooter>
    </Dialog>
  );
}
