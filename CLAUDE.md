# KATARI project

## NOTE

This project is under development phase, so you can change anything; architecture, design, API, etc. You don't need to worry about backward compatibility or breaking changes.

## Overview

- Katari is Language to write orchestration logic for AI agents
- User writes a Katari program, which is then compiled to a IR and executed by the Katari runtime
- Katari runtime is a continuasly running server that can upload, execute and manage Katari programs
- Katari runtime persists the state of the program execution, allowing for long-running programs and recovery from failures
- In katari, parallel execution and concurrency are first-class citizens, allowing for efficient orchestration of multiple agents and tasks

## Domain Knowledge

- Agent: In katari, an agent is like "function" in traditional programming languages. It is a unit of execution that can perform tasks.
- Schema: Each agent has a Json schema that defines the structure of the input and output of the agent. AI agents can use this schema to understand how to interact with the agent. (as tool)
- Request: A request is "effect definition" in traditional programming languages. It defines an effect that an agent can perform.
- Effect: Each agent can perform requests. An effect is an set of requests that an agent can perform.
- Handler: A handler is a implementation of a request. It defines how to perform a request.
- IR: Intermediate Representation, which is the output of the Katari compiler and the input of the Katari runtime. It is a mid-level representation of the Katari program that can be executed by the runtime.
- Block: A block is a component of the IR that represents a definition of thread.
- Thread: A thread is a running instance of a block. Each thread has its own state.
- Delegation: In katari runtime, calling another agent is called "delegation".
- Escalation: In katari runtime, performing a request is called "escalation".
- Project: Katari users can manage their Katari programs and dependencies using a project configuration file.
- Snapshot: When uploading a Katari IR, the runtime will create a snapshot of the IR, which is an immutable version of the IR that can be executed. This allows for efficient execution and easy rollback to previous versions of the IR.

## Development

### Project structure

- `haskell`: Dependency: compiler <- project <- lsp, cli
  - `compiler`: Katari compiler, which compiles Katari source code to IR
  - `lsp`: Language Server Protocol implementation for Katari, providing editor features like aut
  - `cli`: Command Line Interface for Katari, allowing users to interact with the Katari runtime and manage their programs
  - `project`: Project management library for Katari, handling project configuration and dependencies
- `typescript`
  - `cli`: Wrapper for katari cli (haskell)
  - `runtime`: Katari runtime, which executes the compiled IR and manages program state
  - `port`: Katari user can use this library in FFI to interact with the Katari runtime.
  - `bundle`: Bundler for bundle FFI code (haskell cli uses this to bundle the FFI code)
  - `vscode`: VSCode extension for Katari
  - `admin-web`: Web interface for managing Katari runtime
  - `types`: Shared types
- `docs`: Documentation for Katari, including design documents, user guides and API references

### Tools

- Stack: Haskell build tool
- Pnpm: JavaScript package manager
- Ormolu: Haskell code formatter
- Hlint: Haskell linter
- Biome: JavaScript linter and formatter
- Tsc: TypeScript type checker
- Lefthook: Git hooks manager

### Commands

- `pnpm run build`: Build both haskell and typescript code
- `pnpm run build:haskell`: Build haskell code
- `pnpm run build:typescript`: Build typescript code
- `pnpm run test`: Run tests for both haskell and typescript code
- `pnpm run test:haskell`: Run tests for haskell code
- `pnpm run test:typescript`: Run tests for typescript code
- `pnpm run format`: Format both haskell and typescript code
- `pnpm run format:haskell`: Format haskell code using ormolu
- `pnpm run format:typescript`: Format typescript code using biome
- `pnpm run typecheck`: Typecheck both haskell and typescript code
- `pnpm run typecheck:haskell`: Typecheck haskell code using stack
- `pnpm run typecheck:typescript`: Typecheck typescript code using tsc
- `pnpm run lint`: Lint both haskell and typescript code
- `pnpm run lint:haskell`: Lint haskell code using hlint
- `pnpm run lint:typescript`: Lint typescript code using biome check

Github CI will run `pnpm run typecheck` and `pnpm run lint` on every push and pull request to ensure code quality and catch errors early.

### Coding Rules

- Do not use abbreviations in variable and function names. Exception: `id` only

- Haskell
  - Do not use partial functions (e.g. head, tail, fromJust, etc.)
  - Use `Record` syntax for data types with multiple fields
    - name duplication is allowed in difference data types (Language Extension: DuplicateRecordFields, NoFieldSelectors, OverloadedRecordDot,...) so you can simply name the fields as `input` and `output`, without prefixing them with the data type name.
  - Use `List` for list data types, not `[T]`
  - Use `Text` for string data types, not `String`
  - Use `case` for pattern matching, not function definitions with multiple equations
    - ex)

      ```haskell
      -- bad
      myFunction (MyTypeA n) = ...
      myFunction (MyTypeB s) = ...

      myFunction x = case x of
        MyTypeA n -> ...
        MyTypeB s -> ...
      ```

- TypeScript
  - Do not use `any`
  - Do not use `as` (as possible)
