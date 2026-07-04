import {
  Bell,
  Camera,
  FileIcon,
  FunctionSquare,
  KeyRound,
  LayoutDashboard,
  Play,
} from "lucide-react";
import { NavLink, useParams } from "react-router-dom";
import { useEscalations } from "../../api/queries";
import { cn } from "../../lib/cn";
import { Badge } from "../ui/Badge";

const links = [
  { to: "", icon: LayoutDashboard, label: "Dashboard", end: true },
  { to: "runs", icon: Play, label: "Runs" },
  { to: "agents", icon: FunctionSquare, label: "Agents" },
  { to: "escalations", icon: Bell, label: "Escalations" },
  { to: "snapshots", icon: Camera, label: "Snapshots" },
  { to: "files", icon: FileIcon, label: "Files" },
  { to: "env", icon: KeyRound, label: "Env" },
];

export function Sidebar() {
  const { projectId } = useParams();
  if (projectId === undefined) return null;
  return (
    <nav className="flex w-52 shrink-0 flex-col bg-surface p-3">
      {links.map(({ to, icon: Icon, label, end }) => (
        <NavLink
          key={label}
          to={`/projects/${projectId}/${to}`}
          end={end}
          className={({ isActive }) =>
            cn(
              "flex items-center gap-2.5 px-2.5 py-2 text-sm text-fg-muted transition-colors hover:bg-sunken hover:text-fg",
              isActive &&
                "bg-reversed text-accent-fg hover:bg-reversed-hover hover:text-accent-fg",
            )
          }
        >
          <Icon className="size-4" />
          <span className="grow">{label}</span>
          {label === "Escalations" && (
            <OpenEscalationCount projectId={projectId} />
          )}
        </NavLink>
      ))}
    </nav>
  );
}

/** The inbox signal: how many escalations wait on a human right now. */
function OpenEscalationCount({ projectId }: { projectId: string }) {
  const escalations = useEscalations(projectId);
  const count = escalations.data?.length ?? 0;
  if (count === 0) return null;
  return <Badge tone="warning">{count}</Badge>;
}
