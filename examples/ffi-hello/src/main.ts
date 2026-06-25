import { katari } from "@katari-lang/port";

// The FFI implementation of `external agent greet` (declared in main.ktr — same module path `main`, so
// this registers under the key `main.greet` the runtime dispatches to). It receives the call's argument
// as plain JSON (`{ name }`) and returns plain JSON; the runtime converts to/from its value model.
katari.agent("greet", (argument) => {
  const name =
    typeof argument === "object" &&
    argument !== null &&
    !Array.isArray(argument) &&
    typeof argument.name === "string"
      ? argument.name
      : "stranger";
  return `Hello, ${name}!`;
});
