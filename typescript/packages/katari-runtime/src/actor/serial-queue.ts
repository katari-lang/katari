// SerialQueue — a minimal per-project serialization primitive.
//
// The project actor runs each quantum (an external trigger drained to
// quiescence) under this queue so two concurrent triggers for the same project
// never interleave their feeds — keeping the warm module caches (CORE shards +
// index, FFI lanes, ENV relay map) consistent without any per-cache locking.
//
// Per-shard concurrency is a later change: it only swaps this single per-project
// queue for a per-shard keyed set of queues (a mutex-granularity change, as the
// design notes), with no module-internal changes.
//
// Tasks run in submission order. A task that rejects does not stall the queue:
// the next task still runs (each task's result is surfaced to its own caller).

export class SerialQueue {
  private tail: Promise<unknown> = Promise.resolve();

  /** Enqueue `task`; it runs after every previously-enqueued task settles. */
  run<T>(task: () => Promise<T>): Promise<T> {
    // Chain off `tail` regardless of whether it resolved or rejected, so one
    // failed task can't poison the queue for the next.
    const result = this.tail.then(task, task);
    // Keep the chain alive but swallow errors on the internal tail so an
    // unhandled rejection here never crashes the process; the real result
    // (including rejection) is returned to the caller above.
    this.tail = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }
}
