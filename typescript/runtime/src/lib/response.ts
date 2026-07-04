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

export const failure = (code: string, message: string): ErrorBody => ({
  ok: false,
  error: { code, message },
});
