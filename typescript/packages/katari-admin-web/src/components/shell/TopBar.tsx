import { Menu } from "lucide-react";
import { Link } from "react-router-dom";
import { Logo } from "./Logo";
import { ThemeToggle } from "./ThemeToggle";
import { UserMenu } from "./UserMenu";

type TopBarProps = {
  onMenuToggle: () => void;
};

export function TopBar({ onMenuToggle }: TopBarProps) {
  return (
    <header className="sticky top-0 z-30 flex h-14 w-full items-center bg-background/80 backdrop-blur-sm">
      <div className="flex w-full items-center gap-4 px-6">
        <button
          type="button"
          onClick={onMenuToggle}
          className="inline-flex h-9 w-9 items-center justify-center text-muted-foreground transition-colors hover:bg-muted hover:text-foreground hover:cursor-pointer md:hidden"
          aria-label="Toggle sidebar"
        >
          <Menu className="size-5" />
        </button>
        <Link to="/" className="flex items-center transition-opacity hover:opacity-80">
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
