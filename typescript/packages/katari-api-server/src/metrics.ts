// Lightweight in-process metrics, served as Prometheus text format on
// `/metrics`. We deliberately don't pull in `prom-client` — the few
// gauges/counters/histograms we currently need fit in <100 lines, and
// avoiding the dependency keeps the deploy slim.
//
// If the surface ever needs labels, exemplars, or push-gateway support,
// swap this module out for prom-client without touching the rest of the
// codebase.

export class Counter {
  constructor(
    readonly name: string,
    readonly help: string,
  ) {}
  private value = 0;

  inc(by: number = 1): void {
    this.value += by;
  }

  render(): string {
    return [
      `# HELP ${this.name} ${this.help}`,
      `# TYPE ${this.name} counter`,
      `${this.name} ${this.value}`,
    ].join("\n");
  }
}

export class Gauge {
  constructor(
    readonly name: string,
    readonly help: string,
  ) {}
  private value = 0;

  set(v: number): void {
    this.value = v;
  }

  inc(by: number = 1): void {
    this.value += by;
  }

  dec(by: number = 1): void {
    this.value -= by;
  }

  render(): string {
    return [
      `# HELP ${this.name} ${this.help}`,
      `# TYPE ${this.name} gauge`,
      `${this.name} ${this.value}`,
    ].join("\n");
  }
}

/**
 * Histogram with caller-supplied bucket boundaries (in seconds).
 * Buckets are cumulative — the count for `le="0.5"` includes everything
 * `<= 0.5s` AND everything `<= 0.25s` etc.
 */
export class Histogram {
  private readonly counts: number[];
  private sum = 0;
  private observations = 0;

  constructor(
    readonly name: string,
    readonly help: string,
    readonly buckets: number[],
  ) {
    this.counts = new Array(buckets.length).fill(0);
  }

  observe(seconds: number): void {
    this.sum += seconds;
    this.observations += 1;
    for (let i = 0; i < this.buckets.length; i++) {
      if (seconds <= this.buckets[i]!) {
        this.counts[i]! += 1;
      }
    }
  }

  render(): string {
    const lines: string[] = [`# HELP ${this.name} ${this.help}`, `# TYPE ${this.name} histogram`];
    for (let i = 0; i < this.buckets.length; i++) {
      lines.push(`${this.name}_bucket{le="${this.buckets[i]}"} ${this.counts[i]}`);
    }
    lines.push(`${this.name}_bucket{le="+Inf"} ${this.observations}`);
    lines.push(`${this.name}_sum ${this.sum}`);
    lines.push(`${this.name}_count ${this.observations}`);
    return lines.join("\n");
  }
}

/** Registry: holds the metric instances and renders them all. */
export class MetricRegistry {
  private readonly metrics: Array<Counter | Gauge | Histogram> = [];

  register<M extends Counter | Gauge | Histogram>(metric: M): M {
    this.metrics.push(metric);
    return metric;
  }

  render(): string {
    return `${this.metrics.map((m) => m.render()).join("\n")}\n`;
  }
}

/**
 * The set of metrics the api-server exposes. Centralized so route handlers
 * and services share one registry instance. New code that needs a metric
 * should add it here rather than spinning up its own registry — single
 * `/metrics` endpoint is much easier for ops to consume.
 */
export type AppMetrics = {
  registry: MetricRegistry;
  /** Total `/agent` POSTs (success + failure). */
  agentStartTotal: Counter;
  /** Total `/agent/:id/cancel` POSTs (success + failure). */
  agentCancelTotal: Counter;
  /** Currently-loaded machines in the registry. */
  machinesLoaded: Gauge;
  /** End-to-end duration of a single `applyEvent`-bracketed mutex section. */
  applyEventDuration: Histogram;
};

export function buildMetrics(): AppMetrics {
  const registry = new MetricRegistry();
  return {
    registry,
    agentStartTotal: registry.register(
      new Counter("katari_agent_start_total", "Number of agent start requests."),
    ),
    agentCancelTotal: registry.register(
      new Counter("katari_agent_cancel_total", "Number of agent cancel requests."),
    ),
    machinesLoaded: registry.register(
      new Gauge("katari_machines_loaded", "Number of live sidecar processes (per snapshot)."),
    ),
    applyEventDuration: registry.register(
      new Histogram(
        "katari_apply_event_duration_seconds",
        "Wall-clock duration of an applyEvent + DB transaction section, in seconds.",
        [0.001, 0.01, 0.05, 0.1, 0.5, 1, 5],
      ),
    ),
  };
}
