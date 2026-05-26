import { Component, type ErrorInfo, type ReactNode } from "react";

type Props = {
  children: ReactNode;
};

type State = {
  error: Error | null;
};

export class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  override componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("[ErrorBoundary]", error, info.componentStack);
  }

  override render() {
    const { error } = this.state;
    if (error === null) {
      return this.props.children;
    }
    return (
      <div className="flex min-h-screen flex-col items-center justify-center bg-background px-6 text-foreground">
        <h1 className="text-lg font-semibold">Something went wrong</h1>
        <p className="mt-3 max-w-lg border border-border bg-muted px-4 py-3 font-mono text-sm">
          {error.message}
        </p>
        <button
          type="button"
          onClick={() => window.location.reload()}
          className="mt-6 border border-border px-4 py-2 text-sm text-foreground transition-colors hover:bg-muted hover:cursor-pointer"
        >
          Reload
        </button>
      </div>
    );
  }
}
