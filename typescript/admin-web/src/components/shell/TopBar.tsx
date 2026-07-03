import { Settings } from "lucide-react";
import { Link, useParams } from "react-router-dom";
import { ProjectSwitcher } from "./ProjectSwitcher";
import { ThemeToggle } from "./ThemeToggle";

export function TopBar() {
  const { projectId } = useParams();
  return (
    <header className="flex items-center justify-between border-b border-edge bg-raised px-4 py-2">
      <div className="flex items-center gap-3">
        <Link to="/projects" className="text-sm font-bold tracking-wide text-fg">
          KATARI<span className="pl-1.5 font-normal text-fg-faint">console</span>
        </Link>
        {projectId !== undefined && <ProjectSwitcher currentProjectId={projectId} />}
      </div>
      <div className="flex items-center gap-1">
        <ThemeToggle />
        <Link
          to="/settings"
          title="Settings"
          className="rounded-md p-2 text-fg-muted transition-colors hover:bg-sunken hover:text-fg"
        >
          <Settings className="size-4" />
        </Link>
      </div>
    </header>
  );
}
