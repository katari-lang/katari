import { MutationCache, QueryCache, QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { App } from "./App";
import { ApiError } from "./api/client";
import { AuthGate } from "./components/auth/AuthGate";
import { reportUnauthorized } from "./lib/auth";
import { ThemeProvider } from "./lib/theme";
import { ToastProvider } from "./lib/toast";
import "./styles/globals.css";

// Any 401 (a request the runtime rejected for a missing / wrong API key) trips the auth gate's login
// screen — from a query poll or a mutation alike.
const onError = (error: unknown) => {
  if (error instanceof ApiError && error.status === 401) reportUnauthorized();
};

const queryClient = new QueryClient({
  queryCache: new QueryCache({ onError }),
  mutationCache: new MutationCache({ onError }),
  defaultOptions: {
    queries: {
      // Re-authenticating is the user's job; retrying a 401 only delays the login prompt.
      retry: (count, error) => !(error instanceof ApiError && error.status === 401) && count < 1,
      // The polling hooks own their freshness; background refocus refetches would double up on them.
      refetchOnWindowFocus: false,
    },
  },
});

const container = document.getElementById("root");
if (container === null) throw new Error("missing #root");

createRoot(container).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <ThemeProvider>
        <ToastProvider>
          <BrowserRouter>
            <AuthGate>
              <App />
            </AuthGate>
          </BrowserRouter>
        </ToastProvider>
      </ThemeProvider>
    </QueryClientProvider>
  </StrictMode>,
);
