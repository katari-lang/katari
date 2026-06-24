ALTER TABLE "outbox" DROP CONSTRAINT "outbox_instance_id_instances_id_fk";
--> statement-breakpoint
ALTER TABLE "outbox" ALTER COLUMN "instance_id" SET NOT NULL;