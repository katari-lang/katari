import { Link } from "react-router-dom";
import { Logo } from "./Logo";
import { ThemeToggle } from "./ThemeToggle";
import { UserMenu } from "./UserMenu";

export function TopBar() {
  return (
    <header className="sticky top-0 z-30 flex h-14 w-full items-center bg-background/80 backdrop-blur-sm">
      <div className="flex w-full items-center gap-4 px-6">
        <Link
          to="/"
          className="flex items-center transition-opacity hover:opacity-80"
        >
          <Logo size="md" />
        </Link>
        <div className="ml-auto flex items-center gap-2">
          <ThemeToggle />
          <UserMenu />
        </div>
      </div>
    </header>
  );
}
