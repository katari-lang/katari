import { IRModule } from "../ir/types.js";
import { MachineState } from "./types/state.js";

export function makeMachineState(irModule: IRModule): MachineState {
  return {
    irModule,
    threads: new Map(),
    scopes: new Map(),
  };
}
