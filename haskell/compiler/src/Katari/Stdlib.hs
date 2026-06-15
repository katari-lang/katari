{-# LANGUAGE TemplateHaskell #-}

-- | The compiler-blessed stdlib sources, embedded into the binary at build time so a single
-- self-contained executable ships them. These are ordinary Katari modules (the @primitive@ root and
-- any submodules under @stdlib/@); the compiler runs them through the usual pipeline like user code.
-- The driver splices them into every compile and default-imports the 'defaultImports' roots (see
-- 'Katari.Compile.compile').
--
-- Embedding (rather than reading at runtime) keeps the compiler IO-free: 'stdlibSources' is a
-- compile-time constant. The @stdlib/@ file layout maps to module names by dropping the @.ktr@
-- extension and joining path segments with dots — @stdlib/primitive.ktr@ -> @primitive@,
-- @stdlib/primitive/array.ktr@ -> @primitive.array@ — matching the project-wide module-name rule, so a
-- new stdlib module is added by dropping in a @.ktr@ file with no code change.
module Katari.Stdlib where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir, makeRelativeToProject)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import GHC.List (List)
import Katari.Data.ModuleName (ModuleName, covers, moduleNameFromSegments)
import Katari.Primitive (primitiveModuleName)
import System.FilePath (dropExtension, splitDirectories, takeExtension)

-- | Every embedded stdlib source, keyed by the module name it is spliced under.
stdlibSources :: Map ModuleName Text
stdlibSources =
  Map.fromList [(filePathToModuleName path, decodeStdlib contents) | (path, contents) <- embeddedFiles]

-- | The raw embedded files: @(relative path under @stdlib/@, file contents)@, fixed at build time.
-- Only @.ktr@ files are kept: 'embedDir' embeds /everything/ under the directory (editor swap files,
-- @.DS_Store@, generated artifacts), so without this filter a stray file would be spliced in and
-- parsed as Katari source on every compile.
embeddedFiles :: List (FilePath, ByteString)
embeddedFiles = filter (\(path, _) -> takeExtension path == ".ktr") allEmbeddedFiles

allEmbeddedFiles :: List (FilePath, ByteString)
allEmbeddedFiles = $(makeRelativeToProject "stdlib" >>= embedDir)

-- | Decode an embedded source as UTF-8. Total (invalid bytes become U+FFFD) rather than the partial
-- strict @decodeUtf8@: a malformed wired-in file should surface as a parse diagnostic, never an
-- imprecise exception that takes down every compile.
decodeStdlib :: ByteString -> Text
decodeStdlib = decodeUtf8With lenientDecode

-- | @"primitive/array.ktr"@ -> @primitive.array@; @"primitive.ktr"@ -> @primitive@.
filePathToModuleName :: FilePath -> ModuleName
filePathToModuleName path = moduleNameFromSegments (Text.pack <$> splitDirectories (dropExtension path))

-- | The default-import roots spliced into every user module's scope (see
-- 'Katari.Identifier.defaultImportScope'). Currently just the @primitive@ root, which covers it and
-- every @primitive.*@ submodule.
defaultImports :: List ModuleName
defaultImports = [primitiveModuleName]

-- | Whether a module name is reserved by the compiler: an embedded stdlib module, or anything under a
-- default-import root (the @primitive.*@ namespace). The driver rejects a user module on a reserved
-- name (see 'Katari.Compile.compile') instead of letting it silently shadow the stdlib (an exact
-- clash) or be globally default-imported (a name under a reserved root). Module names come from file
-- paths, not the lexer, so the @primitive@ keyword does not protect the namespace — this does.
isReservedModuleName :: ModuleName -> Bool
isReservedModuleName moduleName =
  Map.member moduleName stdlibSources || any (`covers` moduleName) defaultImports
