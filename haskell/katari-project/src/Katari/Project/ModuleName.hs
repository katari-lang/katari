-- | Map an on-disk @.ktr@ file path to its Katari module name.
--
-- The convention is: directory separators in the path /relative to the
-- project source root/ become dots, and the trailing @.ktr@ extension is
-- dropped:
--
-- @
-- moduleNameFromRelativePath "main.ktr"      == "main"
-- moduleNameFromRelativePath "foo/bar.ktr"   == "foo.bar"
-- moduleNameFromRelativePath "a/b/c.ktr"     == "a.b.c"
-- @
--
-- Callers with an absolute path must relativize it first
-- ('System.FilePath.makeRelative').
module Katari.Project.ModuleName
  ( moduleNameFromRelativePath,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import System.FilePath (dropExtension, splitDirectories)

moduleNameFromRelativePath :: FilePath -> Text
moduleNameFromRelativePath path =
  let withoutExt = dropExtension path
      parts = splitDirectories withoutExt
   in Text.intercalate "." (map Text.pack parts)
