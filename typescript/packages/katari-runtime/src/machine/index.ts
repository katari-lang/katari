import { MachineEvent, ManagementEvent } from "./types/events.js";
import { MachineState } from "./types/state.js";

// applyEvent signature (implementation deferred):
export function applyEvent(
  mutableState: MachineState,
  inboundEvent: MachineEvent,
) {
  return;
}

export function applyManagementEvent(
  mutableState: MachineState,
  inboundEvent: ManagementEvent,
) {
  return;
}
