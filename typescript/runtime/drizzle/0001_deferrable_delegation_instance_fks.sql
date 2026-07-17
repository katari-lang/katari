-- The instances <-> delegations foreign keys form a cycle (instances.delegation_id -> delegations.id,
-- delegations.caller_instance_id -> instances.id), and turn batching can fold a whole causal chain --
-- caller instance, its delegation, the callee instance that delegation summoned -- into one commit.
-- No fixed per-table insert order satisfies both edges of the cycle across reactors, so the references
-- are checked at commit time instead of statement time. Referential ACTIONS (cascade / set null) are
-- unaffected by deferral; only the existence check moves to the commit boundary.
--
-- This lives in a hand-written migration (drizzle-kit --custom) because the drizzle schema DSL cannot
-- express DEFERRABLE; regenerating 0000 from src/db/tables/ will never recreate it. If the squash is
-- ever redone, this file must survive it.
ALTER TABLE "instances" ALTER CONSTRAINT "instances_delegation_id_delegations_id_fk" DEFERRABLE INITIALLY DEFERRED;--> statement-breakpoint
ALTER TABLE "delegations" ALTER CONSTRAINT "delegations_caller_instance_id_instances_id_fk" DEFERRABLE INITIALLY DEFERRED;
