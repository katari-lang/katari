CREATE TABLE "capability_routes" (
	"token" text PRIMARY KEY NOT NULL,
	"project_id" uuid NOT NULL,
	"instance_id" uuid NOT NULL
);
--> statement-breakpoint
CREATE TABLE "external_call_instances" (
	"instance_id" uuid PRIMARY KEY NOT NULL,
	"status" text NOT NULL,
	"extension" jsonb NOT NULL
);
--> statement-breakpoint
ALTER TABLE "capability_routes" ADD CONSTRAINT "capability_routes_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "capability_routes" ADD CONSTRAINT "capability_routes_instance_id_instances_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "external_call_instances" ADD CONSTRAINT "external_call_instances_instance_id_instances_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "capability_routes_instance_id_idx" ON "capability_routes" USING btree ("instance_id");--> statement-breakpoint
-- Copy every live per-kind row into the one external-call table before dropping the old tables (the
-- extension documents below are exactly what each reactor's codec writes for a fresh call). Sealed
-- subtrees ($sealed nodes inside callback / tools / descriptor / continuation / operation / parked call
-- columns) ride along unchanged — the whole-document unseal finds them wherever they sit.
INSERT INTO "external_call_instances" ("instance_id", "status", "extension")
SELECT f."instance_id", f."status",
	jsonb_build_object('snapshotId', f."snapshot_id", 'key', f."key", 'relays', f."relays", 'innerCalls', f."inner_calls")
FROM "ffi_instances" f;--> statement-breakpoint
INSERT INTO "external_call_instances" ("instance_id", "status", "extension")
SELECT h."instance_id", h."status", '{}'::jsonb
FROM "http_instances" h;--> statement-breakpoint
INSERT INTO "external_call_instances" ("instance_id", "status", "extension")
SELECT w."instance_id", w."status",
	jsonb_build_object('snapshotId', w."snapshot_id", 'token', w."token", 'callback', w."callback", 'relays', w."relays", 'innerCalls', w."inner_calls")
FROM "webhook_instances" w;--> statement-breakpoint
INSERT INTO "external_call_instances" ("instance_id", "status", "extension")
SELECT t."instance_id", t."status",
	jsonb_build_object('snapshotId', t."snapshot_id", 'operation', t."operation", 'relays', t."relays", 'innerCalls', t."inner_calls")
FROM "time_instances" t;--> statement-breakpoint
-- The mcp subtype tables (at most one row per call) fold into the extension's one-tag sum.
INSERT INTO "external_call_instances" ("instance_id", "status", "extension")
SELECT m."instance_id", m."status",
	CASE
		WHEN s."instance_id" IS NOT NULL THEN jsonb_build_object('kind', 'serve', 'snapshotId', s."snapshot_id", 'token', s."serve_token", 'tools', s."serve_tools", 'relays', s."relays", 'innerCalls', s."inner_calls")
		WHEN p."instance_id" IS NOT NULL THEN jsonb_build_object('kind', 'provide', 'snapshotId', p."snapshot_id", 'scopeId', p."scope_id", 'descriptor', p."descriptor", 'continuation', p."continuation", 'relays', p."relays", 'innerCalls', p."inner_calls")
		WHEN k."instance_id" IS NOT NULL THEN jsonb_build_object('kind', 'parked', 'call', k."call")
		ELSE jsonb_build_object('kind', 'transport')
	END
FROM "mcp_instances" m
LEFT JOIN "mcp_serve_instances" s ON s."instance_id" = m."instance_id"
LEFT JOIN "mcp_provide_instances" p ON p."instance_id" = m."instance_id"
LEFT JOIN "mcp_parked_instances" k ON k."instance_id" = m."instance_id";--> statement-breakpoint
-- The live capability tokens (webhook + mcp serve) project into the routing index, so cold inbound
-- delivery keeps working across the upgrade.
INSERT INTO "capability_routes" ("token", "project_id", "instance_id")
SELECT w."token", i."project_id", w."instance_id"
FROM "webhook_instances" w JOIN "instances" i ON i."id" = w."instance_id";--> statement-breakpoint
INSERT INTO "capability_routes" ("token", "project_id", "instance_id")
SELECT s."serve_token", i."project_id", s."instance_id"
FROM "mcp_serve_instances" s JOIN "instances" i ON i."id" = s."instance_id";--> statement-breakpoint
DROP TABLE "ffi_instances" CASCADE;--> statement-breakpoint
DROP TABLE "http_instances" CASCADE;--> statement-breakpoint
DROP TABLE "mcp_instances" CASCADE;--> statement-breakpoint
DROP TABLE "mcp_parked_instances" CASCADE;--> statement-breakpoint
DROP TABLE "mcp_provide_instances" CASCADE;--> statement-breakpoint
DROP TABLE "mcp_serve_instances" CASCADE;--> statement-breakpoint
DROP TABLE "time_instances" CASCADE;--> statement-breakpoint
DROP TABLE "webhook_instances" CASCADE;
