CREATE TABLE "mcp_provide_instances" (
	"instance_id" uuid PRIMARY KEY NOT NULL,
	"snapshot_id" uuid NOT NULL,
	"scope_id" text NOT NULL,
	"descriptor" jsonb NOT NULL,
	"continuation" jsonb,
	"relays" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"inner_calls" jsonb DEFAULT '[]'::jsonb NOT NULL
);
--> statement-breakpoint
ALTER TABLE "mcp_provide_instances" ADD CONSTRAINT "mcp_provide_instances_instance_id_mcp_instances_instance_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."mcp_instances"("instance_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "mcp_provide_instances" ADD CONSTRAINT "mcp_provide_instances_snapshot_id_snapshots_id_fk" FOREIGN KEY ("snapshot_id") REFERENCES "public"."snapshots"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "mcp_provide_instances_scope_id_idx" ON "mcp_provide_instances" USING btree ("scope_id");