CREATE TABLE "credentials" (
	"project_id" uuid NOT NULL,
	"name" text NOT NULL,
	"value" text NOT NULL,
	"generation" bigint NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "credentials_project_id_name_pk" PRIMARY KEY("project_id","name")
);
--> statement-breakpoint
ALTER TABLE "credentials" ADD CONSTRAINT "credentials_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
-- Carry every live credential over verbatim. The sealed value is AES-GCM ciphertext the SQL layer cannot
-- open, so the "mcp" profile tag is stamped at DECODE time: a stored value with no `profile` field decodes
-- as the migrated triple (see runtime/external/credentials.ts, decodeStoredCredential). The generation is
-- preserved so the compare-and-set lifetime rule holds unbroken across the copy.
INSERT INTO "credentials" ("project_id", "name", "value", "generation", "updated_at")
SELECT "project_id", "name", "value", "generation", "updated_at" FROM "mcp_credentials";--> statement-breakpoint
DROP TABLE "mcp_credentials" CASCADE;--> statement-breakpoint
-- The authorize escalation generalized its request name (prelude.mcp.authorize → prelude.oauth.authorize).
-- A run parked on an authorize escalation at upgrade time must reload and resume exactly as before, so the
-- LIVE faces of the name are rewritten: the open escalation rows, and any escalate produced but not yet
-- consumed in the outbox. (A parked call's extension document keeps its shipped `parked` shape — nothing to
-- rewrite there.) The run trace (`run_events`) intentionally keeps the historical name: it is an
-- append-only record of what happened, not something the runtime dispatches on — like the
-- answered-escalation audit, which stores no request name at all.
UPDATE "escalations" SET "request" = 'prelude.oauth.authorize' WHERE "request" = 'prelude.mcp.authorize';--> statement-breakpoint
UPDATE "outbox"
SET "event" = jsonb_set("event", '{ask,request}', '"prelude.oauth.authorize"')
WHERE "event"->'ask'->>'request' = 'prelude.mcp.authorize';
