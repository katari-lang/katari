-- | Schema-driven interactive prompts.
--
-- Two helpers:
--
--   * 'pickFromList' — numbered menu (= picker UX).
--   * 'promptForSchema' — walk a JSON Schema and ask for one value
--     per leaf type. Objects recurse on their @properties@; arrays
--     ask for length and recurse @N@ times.
--
-- All prompts read line-by-line from stdin and re-ask on invalid
-- input rather than crashing. The output is an Aeson 'Value' shaped
-- to match the schema, suitable for passing to the runtime as
-- @startAgent.args@.
module Katari.Cli.Prompt
  ( pickFromList,
    promptForSchema,
    promptYesNo,
    confirmAndProceed,
  )
where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Encode.Pretty as Pretty
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as AesonKM
import qualified Data.ByteString.Lazy.Char8 as LC8
import qualified Data.Scientific as Scientific
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import System.IO (hFlush, stdout)
import Text.Read (readMaybe)

-- ---------------------------------------------------------------------------
-- Picker
-- ---------------------------------------------------------------------------

-- | Numbered menu. Returns the selected element. Re-prompts on invalid
-- input. Empty list returns 'Nothing' (so callers can branch on the
-- "nothing to pick from" case).
pickFromList :: Text -> [a] -> (a -> Text) -> IO (Maybe a)
pickFromList title items render = case items of
  [] -> do
    putStrLn (Text.unpack title <> ": (nothing to choose from)")
    pure Nothing
  _ -> do
    putStrLn (Text.unpack title)
    let indexed = zip [1 :: Int ..] items
    mapM_ (\(i, x) -> putStrLn ("  " <> show i <> ". " <> Text.unpack (render x))) indexed
    Just <$> loop indexed
  where
    loop indexed = do
      putStr "> "
      hFlush stdout
      ln <- getLine
      case readMaybe ln :: Maybe Int of
        Just n
          | Just x <- lookup n indexed -> pure x
          | otherwise -> do
              putStrLn ("Out of range: " <> show n)
              loop indexed
        Nothing -> do
          putStrLn "Please enter a number from the list."
          loop indexed

-- ---------------------------------------------------------------------------
-- Yes / no
-- ---------------------------------------------------------------------------

promptYesNo :: Text -> Bool -> IO Bool
promptYesNo title def = do
  putStr (Text.unpack title <> " " <> (if def then "[Y/n] " else "[y/N] "))
  hFlush stdout
  ln <- getLine
  pure $ case map toLowerLowercase (trim ln) of
    "" -> def
    "y" -> True
    "yes" -> True
    "n" -> False
    "no" -> False
    _ -> def
  where
    trim = dropWhile (== ' ') . reverse . dropWhile (== ' ') . reverse
    toLowerLowercase c
      | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
      | otherwise = c

-- ---------------------------------------------------------------------------
-- Schema-driven prompt
-- ---------------------------------------------------------------------------

-- | Walk a JSON Schema and return a value matching it. The path
-- argument is just a breadcrumb shown in prompts so the user knows
-- where they are in a nested record.
promptForSchema :: [Text] -> Aeson.Value -> IO Aeson.Value
promptForSchema path schema =
  case schema of
    Aeson.Object o -> promptForObjectSchema path o
    _ -> do
      putStrLn ("(non-object schema; please enter raw JSON for " <> pathLabel path <> ")")
      promptForRawJson path

promptForObjectSchema :: [Text] -> AesonKM.KeyMap Aeson.Value -> IO Aeson.Value
promptForObjectSchema path o = case AesonKM.lookup "enum" o of
  Just (Aeson.Array vs) -> promptForEnum path (Vector.toList vs)
  _ -> case AesonKM.lookup "type" o of
    Just (Aeson.String t) -> promptForType path t o
    _ -> do
      putStrLn ("(schema has no concrete 'type'; please enter raw JSON for " <> pathLabel path <> ")")
      promptForRawJson path

promptForType :: [Text] -> Text -> AesonKM.KeyMap Aeson.Value -> IO Aeson.Value
promptForType path ty o = case ty of
  "object" -> promptForObject path (childProperties o)
  "array" -> promptForArray path (childItems o)
  "string" -> promptForString path o
  "integer" -> promptForInteger path
  "number" -> promptForNumber path
  "boolean" -> Aeson.Bool <$> promptYesNo (Text.pack (pathLabel path) <> " (boolean):") False
  "null" -> pure Aeson.Null
  other -> do
    putStrLn ("(unrecognised type '" <> Text.unpack other <> "', please enter raw JSON)")
    promptForRawJson path

-- ----- object -----

promptForObject :: [Text] -> [(Text, Aeson.Value)] -> IO Aeson.Value
promptForObject path props = do
  pairs <- traverse one props
  pure (Aeson.Object (AesonKM.fromList [(AesonKey.fromText k, v) | (k, v) <- pairs]))
  where
    one (k, sub) = do
      v <- promptForSchema (path <> [k]) sub
      pure (k, v)

childProperties :: AesonKM.KeyMap Aeson.Value -> [(Text, Aeson.Value)]
childProperties o = case AesonKM.lookup "properties" o of
  Just (Aeson.Object props) ->
    [(AesonKey.toText k, v) | (k, v) <- AesonKM.toAscList props]
  _ -> []

-- ----- array -----

promptForArray :: [Text] -> Aeson.Value -> IO Aeson.Value
promptForArray path itemSchema = do
  n <- askLength
  vs <- mapM (\i -> promptForSchema (path <> [Text.pack ("[" <> show i <> "]")]) itemSchema) [0 .. n - 1]
  pure (Aeson.Array (Vector.fromList vs))
  where
    askLength = do
      putStr (pathLabel path <> " (array) length: ")
      hFlush stdout
      ln <- getLine
      case readMaybe ln :: Maybe Int of
        Just k | k >= 0 -> pure k
        _ -> do
          putStrLn "Please enter a non-negative integer."
          askLength

childItems :: AesonKM.KeyMap Aeson.Value -> Aeson.Value
childItems o = case AesonKM.lookup "items" o of
  Just v -> v
  Nothing -> Aeson.Object AesonKM.empty

-- ----- string / numbers / enum -----

promptForString :: [Text] -> AesonKM.KeyMap Aeson.Value -> IO Aeson.Value
promptForString path o = do
  putStr (pathLabel path <> " (string): ")
  hFlush stdout
  ln <- getLine
  -- A "const" in the schema means the value is fixed; respect it but
  -- still confirm to the user what we're sending.
  case AesonKM.lookup "const" o of
    Just (Aeson.String s) -> pure (Aeson.String s)
    _ -> pure (Aeson.String (Text.pack ln))

promptForInteger :: [Text] -> IO Aeson.Value
promptForInteger path = loop
  where
    loop = do
      putStr (pathLabel path <> " (integer): ")
      hFlush stdout
      ln <- getLine
      case readMaybe ln :: Maybe Integer of
        Just n -> pure (Aeson.Number (fromInteger n))
        Nothing -> do
          putStrLn "Not a valid integer."
          loop

promptForNumber :: [Text] -> IO Aeson.Value
promptForNumber path = loop
  where
    loop = do
      putStr (pathLabel path <> " (number): ")
      hFlush stdout
      ln <- getLine
      case readMaybe ln :: Maybe Double of
        Just n -> pure (Aeson.Number (Scientific.fromFloatDigits n))
        Nothing -> do
          putStrLn "Not a valid number."
          loop

promptForEnum :: [Text] -> [Aeson.Value] -> IO Aeson.Value
promptForEnum path choices = do
  picked <- pickFromList (Text.pack (pathLabel path) <> " (enum)") choices renderChoice
  case picked of
    Just v -> pure v
    Nothing -> pure Aeson.Null -- empty enum → null
  where
    renderChoice = Text.pack . LC8.unpack . Aeson.encode

promptForRawJson :: [Text] -> IO Aeson.Value
promptForRawJson path = loop
  where
    loop = do
      putStr (pathLabel path <> " (JSON): ")
      hFlush stdout
      ln <- getLine
      case Aeson.eitherDecode (LC8.pack ln) of
        Right v -> pure v
        Left err -> do
          putStrLn ("Invalid JSON: " <> err)
          loop

pathLabel :: [Text] -> String
pathLabel [] = "value"
pathLabel xs = Text.unpack (Text.intercalate "." xs)

-- ---------------------------------------------------------------------------
-- Final confirmation
-- ---------------------------------------------------------------------------

-- | Pretty-print the collected args and ask the user to confirm.
confirmAndProceed :: Aeson.Value -> IO Bool
confirmAndProceed args = do
  putStrLn "Args:"
  LC8.putStrLn (Pretty.encodePretty args)
  promptYesNo "Run?" True
