ALTER TABLE "mcp_instances" ADD COLUMN "snapshot_id" uuid;--> statement-breakpoint
ALTER TABLE "mcp_instances" ADD COLUMN "serve_token" text;--> statement-breakpoint
ALTER TABLE "mcp_instances" ADD COLUMN "serve_tools" jsonb;--> statement-breakpoint
ALTER TABLE "mcp_instances" ADD COLUMN "relays" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "mcp_instances" ADD COLUMN "inner_calls" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "mcp_instances" ADD CONSTRAINT "mcp_instances_snapshot_id_snapshots_id_fk" FOREIGN KEY ("snapshot_id") REFERENCES "public"."snapshots"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "mcp_instances_serve_token_idx" ON "mcp_instances" USING btree ("serve_token");