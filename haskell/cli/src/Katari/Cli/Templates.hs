{-# LANGUAGE TemplateHaskell #-}

-- | The files @katari init@ scaffolds, embedded from @templates\/@ at build time (the same
-- mechanism as the compiler's wired-in stdlib) so they are maintained as real files — editable,
-- reviewable, syntax-highlighted — rather than string literals, while the shipped binary stays
-- self-contained.
--
-- Dotfiles are stored without their leading dot (@gitignore@, @env.example@): a literal
-- @templates\/.gitignore@ would be read by git as ignore rules /for/ the templates directory. The
-- table below maps each embedded file to its scaffolded destination and says whether the project
-- name interpolates into it.
module Katari.Cli.Templates
  ( ScaffoldFile (..),
    scaffoldFiles,
    interpolate,
    interpolateDestination,
  )
where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir, makeRelativeToProject)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import GHC.List (List)

-- | One file to scaffold: where it lands relative to the project root, and its contents (still
-- holding @{{name}}@ placeholders; the caller interpolates).
data ScaffoldFile = ScaffoldFile
  { destination :: FilePath,
    contents :: Text
  }
  deriving stock (Show)

-- | Every scaffolded file, in the order @init@ writes them. Resolved through 'destinationOf' so an
-- embedded file the table does not know is a loud build-order mistake (it scaffolds under its raw
-- template name and the idempotency test catches it) rather than a silent drop.
scaffoldFiles :: List ScaffoldFile
scaffoldFiles =
  [ ScaffoldFile {destination = destinationOf path, contents = decodeTemplate raw}
    | (path, raw) <- embeddedTemplateFiles
  ]

-- | Template path -> scaffolded path. The identity for most; dotfiles gain their dot back.
destinationOf :: FilePath -> FilePath
destinationOf path = case path of
  "gitignore" -> ".gitignore"
  "env.example" -> ".env.example"
  other -> other

embeddedTemplateFiles :: List (FilePath, ByteString)
embeddedTemplateFiles = $(makeRelativeToProject "templates" >>= embedDir)

-- | Decode an embedded template as UTF-8, totally ('lenientDecode') — a malformed wired-in file
-- should scaffold something visibly wrong, not crash @init@.
decodeTemplate :: ByteString -> Text
decodeTemplate = decodeUtf8With lenientDecode

-- | Fill a template's placeholders: @{{name}}@ with the project's name, @{{version}}@ with the CLI
-- version (so a scaffolded @compose.yaml@ pins the runtime image tag that matches this CLI).
interpolate :: Text -> Text -> Text -> Text
interpolate name version = Text.replace "{{version}}" version . Text.replace "{{name}}" name

-- | Fill only the @{{name}}@ placeholder in a scaffold destination path (@src/{{name}}.ktr@ ->
-- @src/demo.ktr@), so a scaffolded module lands inside the package's own namespace — the module name
-- a file contributes is its path under @src@, which must be the package name or a @\<name>.@ descendant.
-- The @{{name}}@ literal lives here, next to 'interpolate', so the placeholder syntax has one home.
interpolateDestination :: Text -> FilePath -> FilePath
interpolateDestination name = Text.unpack . Text.replace "{{name}}" name . Text.pack
