import { asc, eq, sql } from "drizzle-orm";
import { db } from "../../db/client.js";
import type { CreateUserInput, ListUsersQuery, UpdateUserInput, User } from "./users.schema.js";
import { type UserRow, users } from "./users.table.js";

/**
 * Data access for users, backed by Postgres via Drizzle. Rows are mapped to
 * the domain `User` shape (e.g. `createdAt` as an ISO string) so the service
 * and HTTP layers never see database-specific types.
 */
const toUser = (row: UserRow): User => ({
  id: row.id,
  name: row.name,
  email: row.email,
  role: row.role,
  createdAt: row.createdAt.toISOString(),
});

export interface ListResult {
  items: User[];
  total: number;
}

async function list(query: ListUsersQuery): Promise<ListResult> {
  const where = query.role ? eq(users.role, query.role) : undefined;
  const [rows, counted] = await Promise.all([
    db
      .select()
      .from(users)
      .where(where)
      .orderBy(asc(users.createdAt))
      .limit(query.limit)
      .offset(query.offset),
    db.select({ count: sql<number>`count(*)::int` }).from(users).where(where),
  ]);
  return { items: rows.map(toUser), total: counted[0]?.count ?? 0 };
}

async function findById(id: string): Promise<User | null> {
  const [row] = await db.select().from(users).where(eq(users.id, id)).limit(1);
  return row ? toUser(row) : null;
}

async function findByEmail(email: string): Promise<User | null> {
  const [row] = await db.select().from(users).where(eq(users.email, email)).limit(1);
  return row ? toUser(row) : null;
}

async function create(input: CreateUserInput): Promise<User> {
  const [row] = await db
    .insert(users)
    .values({ name: input.name, email: input.email, role: input.role })
    .returning();
  if (!row) throw new Error("Insert returned no row");
  return toUser(row);
}

async function update(id: string, patch: UpdateUserInput): Promise<User | null> {
  // Drizzle rejects an empty `set`, so a no-op patch just re-reads the row.
  if (Object.keys(patch).length === 0) return findById(id);
  const [row] = await db.update(users).set(patch).where(eq(users.id, id)).returning();
  return row ? toUser(row) : null;
}

async function remove(id: string): Promise<boolean> {
  const deleted = await db.delete(users).where(eq(users.id, id)).returning({ id: users.id });
  return deleted.length > 0;
}

export const usersRepository = {
  list,
  findById,
  findByEmail,
  create,
  update,
  delete: remove,
};
