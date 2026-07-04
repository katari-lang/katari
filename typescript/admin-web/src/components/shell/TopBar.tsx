import { Link, useParams } from "react-router-dom";
import { Logo } from "./Logo";
import { ProjectSwitcher } from "./ProjectSwitcher";
import { ThemeToggle } from "./ThemeToggle";
import { UserMenu } from "./UserMenu";

export function TopBar() {
  const { projectId } = useParams();
  return (
    <header className="relative z-40 flex items-center justify-between bg-surface/50 backdrop-blur-sm px-4 h-14 min-h-14">
      <div className="flex items-center gap-3">
        <Link to="/projects" className="transition-opacity hover:opacity-80 flex items-center">
          <Logo />
        </Link>
        {projectId !== undefined && <ProjectSwitcher currentProjectId={projectId} />}
      </div>
      <div className="flex items-center gap-1">
        <ThemeToggle />
        <UserMenu />
      </div>
    </header>
  );
}
