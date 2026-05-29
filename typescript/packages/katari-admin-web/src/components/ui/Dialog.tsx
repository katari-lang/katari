import * as DialogPrimitive from "@radix-ui/react-dialog";
import { X } from "lucide-react";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

type DialogProps = {
  open: boolean;
  onClose: () => void;
  title?: ReactNode;
  description?: ReactNode;
  children: ReactNode;
  className?: string;
  size?: "sm" | "md" | "lg";
};

const sizeClasses = {
  sm: "max-w-md",
  md: "max-w-lg",
  lg: "max-w-2xl",
};

export function Dialog({
  open,
  onClose,
  title,
  description,
  children,
  className,
  size = "md",
}: DialogProps) {
  return (
    <DialogPrimitive.Root
      open={open}
      onOpenChange={(isOpen) => {
        if (!isOpen) onClose();
      }}
    >
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay className="fixed inset-0 z-50 bg-katari-950/30 backdrop-blur-sm data-[state=open]:animate-in data-[state=open]:fade-in-0 data-[state=closed]:animate-out data-[state=closed]:fade-out-0" />
        <DialogPrimitive.Content
          className={cn(
            "fixed top-1/2 left-1/2 z-50 w-full -translate-x-1/2 -translate-y-1/2",
            "overflow-hidden border border-border-strong bg-background",
            "data-[state=open]:animate-in data-[state=open]:fade-in-0 data-[state=open]:zoom-in-[0.96] data-[state=open]:slide-in-from-left-1/2 data-[state=open]:slide-in-from-top-[48%]",
            "data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=closed]:zoom-out-[0.96] data-[state=closed]:slide-out-to-left-1/2 data-[state=closed]:slide-out-to-top-[48%]",
            sizeClasses[size],
            className,
          )}
        >
          {(title !== undefined || description !== undefined) && (
            <div className="flex items-start gap-2 p-5">
              <div className="flex-1">
                {title !== undefined && (
                  <DialogPrimitive.Title className="text-lg font-semibold text-foreground">
                    {title}
                  </DialogPrimitive.Title>
                )}
                {description !== undefined && (
                  <DialogPrimitive.Description className="mt-1 text-sm text-muted-foreground">
                    {description}
                  </DialogPrimitive.Description>
                )}
              </div>
              <DialogPrimitive.Close
                className="inline-flex h-8 w-8 items-center justify-center text-muted-foreground transition-colors hover:bg-muted hover:text-foreground hover:cursor-pointer"
                aria-label="Close dialog"
              >
                <X className="size-4" />
              </DialogPrimitive.Close>
            </div>
          )}
          {title === undefined && description === undefined && (
            <DialogPrimitive.Title className="sr-only">Dialog</DialogPrimitive.Title>
          )}
          <div className="p-5">{children}</div>
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}

export function DialogFooter({ children }: { children: ReactNode }) {
  return <div className="mt-4 flex items-center justify-end gap-2">{children}</div>;
}
