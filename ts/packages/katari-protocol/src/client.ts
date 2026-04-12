import type { OutgoingMessage, SpawnAgentResponse } from "./types.js";

export interface SpawnResult {
  parentAgentId: string;
  provisionalChildId: string;
  actualAgentId: string;
  actualAgentWhere: string;
}

export async function sendOutgoingMessages(
  messages: OutgoingMessage[]
): Promise<SpawnResult[]> {
  const spawnResults: SpawnResult[] = [];
  const fireAndForget: Promise<void>[] = [];

  for (const msg of messages) {
    if (msg.kind.type === "Spawn") {
      // Spawn must be awaited to get the actual agent ID
      const kind = msg.kind;
      try {
        const res = await fetch(`${msg.toUrl}/agent`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(kind.body),
        });
        if (res.ok) {
          const data = (await res.json()) as SpawnAgentResponse;
          spawnResults.push({
            parentAgentId: kind.parentAgentId,
            provisionalChildId: kind.provisionalChildId,
            actualAgentId: data.agent_id,
            actualAgentWhere: data.agent_where,
          });
        } else {
          console.error(
            `Spawn failed: ${res.status} ${await res.text()}`
          );
        }
      } catch (e) {
        console.error(`Spawn request failed:`, e);
      }
    } else {
      // Fire-and-forget for all other message types
      const path =
        msg.kind.type === "Reply"
          ? "/agent/reply"
          : msg.kind.type === "Request"
            ? "/agent/request"
            : msg.kind.type === "Return"
              ? "/agent/return"
              : msg.kind.type === "Terminate"
                ? "/agent/terminate"
                : "/agent/terminate_ack";

      fireAndForget.push(
        fetch(`${msg.toUrl}${path}`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(msg.kind.body),
        })
          .then(() => {})
          .catch((e) => console.error(`Outgoing ${msg.kind.type} failed:`, e))
      );
    }
  }

  await Promise.allSettled(fireAndForget);
  return spawnResults;
}
