import { ConflictError, NotFoundError } from "../../lib/errors.js";
import { usersRepository } from "./users.repository.js";
import type { CreateUserInput, ListUsersQuery, UpdateUserInput, User } from "./users.schema.js";

/**
 * Business logic layer. Owns invariants (e.g. unique email) and translates
 * "not found" into domain errors. HTTP concerns live in the routes; data
 * access lives in the repository.
 */
export const usersService = {
  list(query: ListUsersQuery) {
    return usersRepository.list(query);
  },

  async get(id: string): Promise<User> {
    const user = await usersRepository.findById(id);
    if (!user) throw new NotFoundError(`User '${id}' not found`);
    return user;
  },

  async create(input: CreateUserInput): Promise<User> {
    const existing = await usersRepository.findByEmail(input.email);
    if (existing) {
      throw new ConflictError(`Email '${input.email}' is already in use`);
    }
    return usersRepository.create(input);
  },

  async update(id: string, patch: UpdateUserInput): Promise<User> {
    if (patch.email) {
      const owner = await usersRepository.findByEmail(patch.email);
      if (owner && owner.id !== id) {
        throw new ConflictError(`Email '${patch.email}' is already in use`);
      }
    }
    const updated = await usersRepository.update(id, patch);
    if (!updated) throw new NotFoundError(`User '${id}' not found`);
    return updated;
  },

  async remove(id: string): Promise<void> {
    const deleted = await usersRepository.delete(id);
    if (!deleted) throw new NotFoundError(`User '${id}' not found`);
  },
};
