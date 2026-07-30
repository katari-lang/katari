import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // The runtime requires `KATARI_SECRET_KEY` (at-rest encryption) and `KATARI_API_KEY` (the API bearer
    // token) at boot. Provide fixed, throwaway values so any suite that loads `config` has them — not real
    // secrets.
    env: {
      KATARI_SECRET_KEY: "r75FbGEeJdHhNknc0999YH3+Kzggi0MExVVFU9TSi7U=",
      // A retired key is configured throughout so the rotation path (decrypt with an older key, encrypt with
      // the newest) is exercised by the suite rather than only by the one test that names it.
      KATARI_SECRET_KEY_PREVIOUS: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
      // At least 32 characters, matching the floor the schema enforces on a real deployment.
      KATARI_API_KEY: "test-api-key-0000000000000000000000",
    },
  },
});
