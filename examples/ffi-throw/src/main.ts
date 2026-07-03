import { katari, KatariData } from "@katari-lang/port";

// The FFI implementation of `external agent parse_port` (declared in main.ktr). A malformed input fails
// with a TYPED error: `katari.throw` raises `prelude.throw[main.parse_error]`, which the katari-side
// handler in main.ktr catches like any stdlib throw — while any other JS error would stay a panic.
katari.agent<{ text: string }>("parse_port", ({ text }) => {
  const port = Number.parseInt(text, 10);
  if (Number.isNaN(port)) {
    katari.throw(new KatariData("main.parse_error", { message: `not a number: ${text}` }));
  }
  return port;
});
