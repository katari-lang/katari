CREATE TABLE "core_instances" (
	"instance_id" uuid PRIMARY KEY NOT NULL,
	"target" jsonb NOT NULL,
	"snapshot_id" uuid NOT NULL,
	"ambient_generics" jsonb,
	"engine_state" jsonb NOT NULL
);
--> statement-breakpoint
CREATE TABLE "ffi_instances" (
	"instance_id" uuid PRIMARY KEY NOT NULL,
	"snapshot_id" uuid NOT NULL,
	"key" text NOT NULL,
	"argument" jsonb,
	"caller_reactor" text NOT NULL,
	"status" text NOT NULL
);
--> statement-breakpoint
ALTER TABLE "ffi_calls" DISABLE ROW LEVEL SECURITY;--> statement-breakpoint
DROP TABLE "ffi_calls" CASCADE;--> statement-breakpoint
ALTER TABLE "instances" DROP CONSTRAINT "instances_kind_check";--> statement-breakpoint
ALTER TABLE "instances" DROP CONSTRAINT "instances_snapshot_id_snapshots_id_fk";
--> statement-breakpoint
ALTER TABLE "core_instances" ADD CONSTRAINT "core_instances_instance_id_instances_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "core_instances" ADD CONSTRAINT "core_instances_snapshot_id_snapshots_id_fk" FOREIGN KEY ("snapshot_id") REFERENCES "public"."snapshots"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ffi_instances" ADD CONSTRAINT "ffi_instances_instance_id_instances_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ffi_instances" ADD CONSTRAINT "ffi_instances_snapshot_id_snapshots_id_fk" FOREIGN KEY ("snapshot_id") REFERENCES "public"."snapshots"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "instances" DROP COLUMN "target";--> statement-breakpoint
ALTER TABLE "instances" DROP COLUMN "snapshot_id";--> statement-breakpoint
ALTER TABLE "instances" DROP COLUMN "ambient_generics";--> statement-breakpoint
ALTER TABLE "instances" DROP COLUMN "engine_state";--> statement-breakpoint
ALTER TABLE "instances" ADD CONSTRAINT "instances_kind_check" CHECK ("instances"."kind" in ('core', 'api', 'ffi'));