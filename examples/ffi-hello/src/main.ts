import { katari } from "@katari-lang/port";

// The FFI implementation of `external agent greet` (declared in main.ktr — same module path `main`, so
// this registers under the key `main.greet` the runtime dispatches to). The argument is assumed to match
// the declared schema (`greet(name: string)`), so the handler is written directly against its type.
katari.agent<{ name: string }>("greet", ({ name }) => `Hello, ${name}!`);
