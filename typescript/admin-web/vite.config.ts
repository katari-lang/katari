import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// The dev server proxies /api to a locally running katari runtime, so the app can use same-origin
// relative URLs in both dev and a deployed setup (where the console sits behind the same host).
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    proxy: {
      "/api": {
        target: process.env.KATARI_API_URL ?? "http://localhost:3000",
        changeOrigin: true,
      },
    },
  },
});
