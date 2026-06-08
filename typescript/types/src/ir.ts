export type QualifiedName = string & { readonly __brand: unique symbol };

export function createAgentName(name: string): QualifiedName {
  return name as QualifiedName;
}
