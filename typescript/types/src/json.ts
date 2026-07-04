/** An arbitrary JSON value. The leaf type for IR schemas and runtime values. */
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
