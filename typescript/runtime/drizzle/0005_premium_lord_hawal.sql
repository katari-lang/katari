ALTER TABLE "delegations" DROP CONSTRAINT "delegations_state_check";--> statement-breakpoint
ALTER TABLE "delegations" ADD COLUMN "error_message" text;--> statement-breakpoint
ALTER TABLE "delegations" ADD CONSTRAINT "delegations_state_check" CHECK ("delegations"."state" in ('running', 'cancelling', 'done', 'gone', 'failed'));