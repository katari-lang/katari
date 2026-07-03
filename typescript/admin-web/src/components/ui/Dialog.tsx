import { type ReactNode, useEffect, useRef } from "react";
import { Button } from "./Button";

/** Modal on the native <dialog> element: focus trapping, Escape, and ::backdrop for free. */
export function Dialog({
  open,
  onClose,
  title,
  children,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = ref.current;
    if (dialog === null) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);

  return (
    <dialog
      ref={ref}
      onClose={onClose}
      onClick={(event) => {
        // A click on the backdrop (the dialog element itself, not its children) dismisses.
        if (event.target === ref.current) onClose();
      }}
      onKeyDown={(event) => {
        // The native dialog already closes on Escape; handling it here too keeps the dismiss
        // affordance explicit for the keyboard path.
        if (event.key === "Escape") onClose();
      }}
      className="m-auto w-full max-w-lg rounded-xl border border-edge bg-raised text-fg shadow-xl backdrop:bg-black/40"
    >
      <div className="p-5">
        <h2 className="pb-3 text-base font-semibold">{title}</h2>
        {children}
      </div>
    </dialog>
  );
}

/** Confirmation combo over Dialog for destructive actions. */
export function ConfirmDialog({
  open,
  onClose,
  onConfirm,
  title,
  description,
  confirmLabel,
  busy = false,
}: {
  open: boolean;
  onClose: () => void;
  onConfirm: () => void;
  title: string;
  description: string;
  confirmLabel: string;
  busy?: boolean;
}) {
  return (
    <Dialog open={open} onClose={onClose} title={title}>
      <p className="text-sm text-fg-muted">{description}</p>
      <div className="flex justify-end gap-2 pt-4">
        <Button onClick={onClose}>Cancel</Button>
        <Button variant="danger" onClick={onConfirm} loading={busy}>
          {confirmLabel}
        </Button>
      </div>
    </Dialog>
  );
}
