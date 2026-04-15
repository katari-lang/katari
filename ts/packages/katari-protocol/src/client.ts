import type { OutgoingMessage, DelegateResponse } from "./types.js";
import type { KatariLogger } from "./logger.js";

// ===========================================================================
// Result types
// ===========================================================================

export interface DelegateResult {
  delegationId: string;
  agentRef: { id: string; endpoint: string };
}

export interface SendResult {
  delegateResults: DelegateResult[];
  failures: SendFailure[];
}

export interface SendFailure {
  message: OutgoingMessage;
  error: string;
}

// ===========================================================================
// Send outgoing messages
// ===========================================================================

export async function sendOutgoingMessages(
  messages: OutgoingMessage[],
  logger?: KatariLogger
): Promise<SendResult> {
  const delegateResults: DelegateResult[] = [];
  const failures: SendFailure[] = [];
  const fireAndForget: Promise<void>[] = [];

  for (const msg of messages) {
    const kind = msg.kind;

    if (kind.type === "Delegate") {
      // Delegate must be awaited to get the agent ref
      logger?.protocolSend("delegate", msg.toEndpoint, {
        agent_def: kind.body.agent_def_ref.id,
        delegation: kind.delegationId,
      });
      try {
        const res = await fetch(`${msg.toEndpoint}/delegate`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(kind.body),
        });
        if (res.ok) {
          const data = (await res.json()) as DelegateResponse;
          delegateResults.push({
            delegationId: kind.delegationId,
            agentRef: data.agent_ref,
          });
        } else {
          const text = await res.text();
          const err = `Delegate failed: ${res.status} ${text}`;
          logger?.log("error", err);
          failures.push({ message: msg, error: err });
        }
      } catch (e) {
        const err = `Delegate request failed: ${e}`;
        logger?.log("error", err);
        failures.push({ message: msg, error: err });
      }
    } else {
      // All other message types are fire-and-forget
      const path =
        kind.type === "DelegateAck" ? "/delegate_ack"
        : kind.type === "Escalate" ? "/escalate"
        : kind.type === "EscalateAck" ? "/escalate_ack"
        : kind.type === "Terminate" ? "/terminate"
        : kind.type === "TerminateAck" ? "/terminate_ack"
        : "/throw";

      logger?.protocolSend(kind.type, msg.toEndpoint);

      fireAndForget.push(
        fetch(`${msg.toEndpoint}${path}`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(kind.body),
        })
          .then(() => {})
          .catch((e) => logger?.log("error", `Outgoing ${kind.type} failed: ${e}`))
      );
    }
  }

  await Promise.allSettled(fireAndForget);
  return { delegateResults, failures };
}
