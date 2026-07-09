CREATE TABLE "webhook_instances" (
	"instance_id" uuid PRIMARY KEY NOT NULL,
	"snapshot_id" uuid NOT NULL,
	"token" text NOT NULL,
	"callback" jsonb NOT NULL,
	"status" text NOT NULL,
	"relays" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"inner_calls" jsonb DEFAULT '[]'::jsonb NOT NULL
);
--> statement-breakpoint
ALTER TABLE "instances" DROP CONSTRAINT "instances_kind_check";--> statement-breakpoint
ALTER TABLE "webhook_instances" ADD CONSTRAINT "webhook_instances_instance_id_instances_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "webhook_instances" ADD CONSTRAINT "webhook_instances_snapshot_id_snapshots_id_fk" FOREIGN KEY ("snapshot_id") REFERENCES "public"."snapshots"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "webhook_instances_token_idx" ON "webhook_instances" USING btree ("token");--> statement-breakpoint
ALTER TABLE "instances" ADD CONSTRAINT "instances_kind_check" CHECK ("instances"."kind" in ('core', 'api', 'ffi', 'http', 'webhook'));