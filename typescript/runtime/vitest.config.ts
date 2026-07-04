import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // The runtime requires `KATARI_SECRET_KEY` (at-rest encryption) and `KATARI_API_KEY` (the API bearer
    // token) at boot. Provide fixed, throwaway values so any suite that loads `config` has them — not real
    // secrets.
    env: {
      KATARI_SECRET_KEY: "r75FbGEeJdHhNknc0999YH3+Kzggi0MExVVFU9TSi7U=",
      KATARI_API_KEY: "test-api-key",
    },
  },
});
