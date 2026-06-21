ALTER TABLE "threads" DROP CONSTRAINT "threads_kind_check";--> statement-breakpoint
ALTER TABLE "instances" ADD COLUMN "engine_state" jsonb;--> statement-breakpoint
ALTER TABLE "threads" ADD CONSTRAINT "threads_kind_check" CHECK ("threads"."kind" in ('agent', 'sequence', 'primitive', 'construct', 'request', 'match', 'for', 'handle', 'parallel', 'delegate', 'external'));