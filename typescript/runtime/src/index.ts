import { createApp } from "./app.js";

/** A ready-to-serve app instance (used by the bin entry and by tests). */
export const app = createApp();

export type { AppType } from "./app.js";
export { createApp } from "./app.js";
export { config } from "./config/index.js";
export type { ApiResponse, ErrorBody, SuccessBody } from "./lib/response.js";
