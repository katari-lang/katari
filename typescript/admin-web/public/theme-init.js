// Apply the stored theme before first paint so a dark preference never flashes light.
//
// This lives in its own file rather than inline in `index.html` so the runtime can serve the console under a
// strict `script-src 'self'` Content-Security-Policy. An inline script would need either `'unsafe-inline'`
// (which would defeat the policy) or a hash that has to be kept in step with this code by hand.
const stored = localStorage.getItem("katari-console.theme");
const dark =
  stored === "dark" ||
  ((stored === null || stored === "system") &&
    window.matchMedia("(prefers-color-scheme: dark)").matches);
document.documentElement.dataset.theme = dark ? "dark" : "light";
