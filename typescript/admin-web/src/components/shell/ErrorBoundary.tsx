import { Component, type ReactNode } from "react";

/** Catches a page's render crash so the shell (navigation, other pages) stays usable. */
export class ErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  render() {
    if (this.state.error !== null) {
      return (
        <div className="rounded-xl border border-danger bg-danger-soft p-5">
          <p className="text-sm font-semibold text-danger">This page failed to render.</p>
          <pre className="overflow-x-auto pt-2 font-mono text-xs whitespace-pre-wrap text-danger">
            {this.state.error.message}
          </pre>
        </div>
      );
    }
    return this.props.children;
  }
}
