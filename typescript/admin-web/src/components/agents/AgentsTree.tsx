// Hierarchical agent listing: qualified names grouped by module prefix, so `shop.tools.fetch`
// nests under `shop.tools`. The stdlib (`prelude.*`) is hidden unless asked for.

import { FunctionSquare } from "lucide-react";
import { Link } from "react-router-dom";
import type { AgentEntry } from "../../api/types";

export function AgentsTree({
  projectId,
  agents,
  snapshotId,
}: {
  projectId: string;
  agents: AgentEntry[];
  snapshotId?: string;
}) {
  const byModule = new Map<string, AgentEntry[]>();
  for (const agent of agents) {
    const lastDot = agent.qualifiedName.lastIndexOf(".");
    const moduleName = lastDot === -1 ? "" : agent.qualifiedName.slice(0, lastDot);
    byModule.set(moduleName, [...(byModule.get(moduleName) ?? []), agent]);
  }
  const query = snapshotId === undefined ? "" : `?snapshot=${snapshotId}`;
  return (
    <div className="flex flex-col gap-4">
      {[...byModule.entries()].map(([moduleName, members]) => (
        <div key={moduleName}>
          <p className="pb-1 font-mono text-xs text-fg-faint">{moduleName}</p>
          <ul className="flex flex-col border-l border-edge">
            {members.map((agent) => (
              <li key={agent.qualifiedName}>
                <Link
                  to={`/projects/${projectId}/agents/${encodeURIComponent(agent.qualifiedName)}${query}`}
                  className="flex items-center gap-2 rounded-r-md px-3 py-1.5 text-sm text-fg transition-colors hover:bg-sunken"
                >
                  <FunctionSquare className="size-3.5 text-accent" />
                  <span className="font-mono">
                    {agent.qualifiedName.slice(moduleName.length + 1)}
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </div>
  );
}

/** Whether an entry belongs to the wired-in stdlib rather than the user's program. */
export function isStdlibAgent(agent: AgentEntry): boolean {
  return agent.qualifiedName === "prelude" || agent.qualifiedName.startsWith("prelude.");
}
