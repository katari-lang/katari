/**
 * Uniform response envelope. Every endpoint returns either `{ ok: true, data }`
 * or `{ ok: false, error }`, which keeps clients and the typed RPC client simple.
 */
export interface SuccessBody<T> {
  ok: true;
  data: T;
}

export interface ErrorBody {
  ok: false;
  error: {
    code: string;
    message: string;
    details?: unknown;
  };
}

export type ApiResponse<T> = SuccessBody<T> | ErrorBody;

export const success = <T>(data: T): SuccessBody<T> => ({ ok: true, data });

/** The slice of a Hono context the paged-list envelope writes through, kept structural so this module
 *  stays framework-free like the rest of the envelope helpers. */
interface HeaderWriter {
  header(name: string, value: string): void;
}

/** Envelope one page of a listing: `data` stays the bare item array (the CLI decodes it as such) while
 *  the filtered `total` rides on the `X-Total-Count` header, which the console's pager reads and other
 *  clients ignore. The route passes the result straight to `c.json`. */
export const pagedList = <T>(
  context: HeaderWriter,
  page: { items: T[]; total: number },
): SuccessBody<T[]> => {
  context.header("X-Total-Count", String(page.total));
  return success(page.items);
};

export const failure = (code: string, message: string): ErrorBody => ({
  ok: false,
  error: { code, message },
});
