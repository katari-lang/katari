// Generic placeholder for routes not yet implemented. Used by Phase D-1
// to keep the router happy until the real pages land.
import { motion } from "framer-motion";
import { Construction } from "lucide-react";

export function PlaceholderPage({ title, hint }: { title: string; hint?: string }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 6 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.2 }}
      className="flex h-full flex-col items-center justify-center gap-3 p-12 text-center"
    >
      <Construction className="size-10 text-subtle-foreground" />
      <h1 className="text-2xl font-semibold text-foreground">{title}</h1>
      {hint !== undefined && <p className="max-w-md text-sm text-muted-foreground">{hint}</p>}
    </motion.div>
  );
}
