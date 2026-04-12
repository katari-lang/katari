module Katari.CLI.Interactive
  ( selectFromList,
    promptParam,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Console.ANSI
  ( Color (..),
    ColorIntensity (..),
    ConsoleLayer (..),
    SGR (..),
    clearLine,
    cursorUp,
    setSGR,
  )
import System.IO
  ( BufferMode (..),
    hFlush,
    hGetBuffering,
    hGetEcho,
    hSetBuffering,
    hSetEcho,
    stdin,
    stdout,
  )

-- | Display a selection list and let the user pick one with arrow keys.
-- Returns @Nothing@ if the user cancels with Esc or q.
selectFromList :: Text -> [(Text, Text)] -> IO (Maybe Text)
selectFromList title items
  | null items = do
      TIO.putStrLn (title <> ": (no items)")
      return Nothing
  | otherwise = do
      oldBuf <- hGetBuffering stdin
      oldEcho <- hGetEcho stdin
      hSetBuffering stdin NoBuffering
      hSetEcho stdin False
      TIO.putStrLn title
      let n = length items
      drawList items 0
      result <- loop items 0 n
      -- Clear the drawn list
      cursorUp n
      mapM_ (\_ -> clearLine >> putStrLn "") [1 .. n]
      cursorUp n
      hSetBuffering stdin oldBuf
      hSetEcho stdin oldEcho
      case result of
        Just idx -> do
          let (label, val) = items !! idx
          setSGR [SetColor Foreground Vivid Green]
          TIO.putStr ("  > " <> label)
          setSGR [Reset]
          putStrLn ""
          return (Just val)
        Nothing -> return Nothing

loop :: [(Text, Text)] -> Int -> Int -> IO (Maybe Int)
loop items cur n = do
  c <- getChar
  case c of
    '\n' -> return (Just cur)
    '\ESC' -> do
      -- Check for arrow key sequence
      c2 <- getChar
      case c2 of
        '[' -> do
          c3 <- getChar
          case c3 of
            'A' -> move items cur n (-1) -- Up
            'B' -> move items cur n 1 -- Down
            _ -> loop items cur n
        _ -> return Nothing -- Esc alone: cancel
    'q' -> return Nothing
    'k' -> move items cur n (-1)
    'j' -> move items cur n 1
    _ -> loop items cur n

move :: [(Text, Text)] -> Int -> Int -> Int -> IO (Maybe Int)
move items cur n delta = do
  let cur' = (cur + delta) `mod` n
  cursorUp n
  drawList items cur'
  loop items cur' n

drawList :: [(Text, Text)] -> Int -> IO ()
drawList items cur =
  mapM_
    ( \(i, (label, _)) -> do
        clearLine
        if i == cur
          then do
            setSGR [SetColor Foreground Vivid Cyan]
            TIO.putStr ("  > " <> label)
            setSGR [Reset]
          else TIO.putStr ("    " <> label)
        putStrLn ""
    )
    (zip [0 ..] items)

-- | Prompt the user for a single parameter value.
promptParam :: Text -> Text -> IO Text
promptParam name description = do
  setSGR [SetColor Foreground Vivid Yellow]
  TIO.putStr name
  setSGR [Reset]
  TIO.putStr (" (" <> description <> "): ")
  hFlush stdout
  T.strip <$> TIO.getLine
