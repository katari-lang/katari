ALTER TABLE "runs" ADD COLUMN "state" text DEFAULT 'running' NOT NULL;--> statement-breakpoint
ALTER TABLE "runs" ADD COLUMN "result" jsonb;--> statement-breakpoint
ALTER TABLE "runs" ADD COLUMN "error_message" text;--> statement-breakpoint
ALTER TABLE "runs" ADD COLUMN "completed_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "runs" ADD CONSTRAINT "runs_state_check" CHECK ("runs"."state" in ('running', 'cancelling', 'done', 'error', 'cancelled'));