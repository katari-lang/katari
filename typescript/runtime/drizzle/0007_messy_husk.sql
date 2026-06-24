ALTER TABLE "runs" DROP CONSTRAINT "runs_state_check";--> statement-breakpoint
ALTER TABLE "runs" DROP CONSTRAINT "runs_instance_id_instances_id_fk";
--> statement-breakpoint
ALTER TABLE "runs" ALTER COLUMN "id" DROP DEFAULT;--> statement-breakpoint
ALTER TABLE "runs" DROP COLUMN "instance_id";--> statement-breakpoint
ALTER TABLE "runs" DROP COLUMN "state";--> statement-breakpoint
ALTER TABLE "runs" DROP COLUMN "result";--> statement-breakpoint
ALTER TABLE "runs" DROP COLUMN "error_message";--> statement-breakpoint
ALTER TABLE "runs" DROP COLUMN "updated_at";--> statement-breakpoint
ALTER TABLE "runs" DROP COLUMN "completed_at";