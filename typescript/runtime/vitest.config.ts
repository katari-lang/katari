import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // The runtime requires `KATARI_SECRET_KEY` at boot (it encrypts secret values at rest). Provide a fixed,
    // throwaway 32-byte base64 key so any suite that loads `config` has one — this is not a real secret.
    env: {
      KATARI_SECRET_KEY: "r75FbGEeJdHhNknc0999YH3+Kzggi0MExVVFU9TSi7U=",
    },
  },
});
