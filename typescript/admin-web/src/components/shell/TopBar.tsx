import { Settings } from "lucide-react";
import { Link, useParams } from "react-router-dom";
import { Logo } from "./Logo";
import { ProjectSwitcher } from "./ProjectSwitcher";
import { ThemeToggle } from "./ThemeToggle";

export function TopBar() {
  const { projectId } = useParams();
  return (
    <header className="flex items-center justify-between bg-surface/50 backdrop-blur-sm px-4 h-14 min-h-14">
      <div className="flex items-center gap-3">
        <Link
          to="/projects"
          className="transition-opacity hover:opacity-80 flex items-center"
        >
          <Logo />
        </Link>
        {projectId !== undefined && (
          <ProjectSwitcher currentProjectId={projectId} />
        )}
      </div>
      <div className="flex items-center gap-1">
        <ThemeToggle />
        <Link
          to="/settings"
          title="Settings"
          className="p-2 text-fg-muted transition-colors hover:bg-sunken hover:text-fg"
        >
          <Settings className="size-4" />
        </Link>
      </div>
    </header>
  );
}
