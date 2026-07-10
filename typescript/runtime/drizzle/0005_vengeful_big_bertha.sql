CREATE TABLE "mcp_serve_instances" (
	"instance_id" uuid PRIMARY KEY NOT NULL,
	"snapshot_id" uuid NOT NULL,
	"serve_token" text NOT NULL,
	"serve_tools" jsonb NOT NULL,
	"relays" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"inner_calls" jsonb DEFAULT '[]'::jsonb NOT NULL
);
--> statement-breakpoint
ALTER TABLE "mcp_instances" DROP CONSTRAINT "mcp_instances_snapshot_id_snapshots_id_fk";
--> statement-breakpoint
DROP INDEX "mcp_instances_serve_token_idx";--> statement-breakpoint
ALTER TABLE "mcp_serve_instances" ADD CONSTRAINT "mcp_serve_instances_instance_id_mcp_instances_instance_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."mcp_instances"("instance_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "mcp_serve_instances" ADD CONSTRAINT "mcp_serve_instances_snapshot_id_snapshots_id_fk" FOREIGN KEY ("snapshot_id") REFERENCES "public"."snapshots"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "mcp_serve_instances_serve_token_idx" ON "mcp_serve_instances" USING btree ("serve_token");--> statement-breakpoint
ALTER TABLE "mcp_instances" DROP COLUMN "snapshot_id";--> statement-breakpoint
ALTER TABLE "mcp_instances" DROP COLUMN "serve_token";--> statement-breakpoint
ALTER TABLE "mcp_instances" DROP COLUMN "serve_tools";--> statement-breakpoint
ALTER TABLE "mcp_instances" DROP COLUMN "relays";--> statement-breakpoint
ALTER TABLE "mcp_instances" DROP COLUMN "inner_calls";