import { defineConfig } from "drizzle-kit";

const url = process.env.DATABASE_URL ?? "postgres://katari:katari@localhost:5432/katari";

export default defineConfig({
  schema: "./src/modules/**/*.table.ts",
  out: "./drizzle",
  dialect: "postgresql",
  dbCredentials: { url },
  verbose: true,
  strict: true,
});
