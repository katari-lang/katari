ALTER TABLE "instances" ALTER COLUMN "target" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "instances" ALTER COLUMN "snapshot_id" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "instances" ADD COLUMN "kind" text NOT NULL;--> statement-breakpoint
ALTER TABLE "instances" ADD CONSTRAINT "instances_kind_check" CHECK ("instances"."kind" in ('core', 'api'));