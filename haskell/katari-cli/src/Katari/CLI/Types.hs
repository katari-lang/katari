module Katari.CLI.Types
  ( Command (..),
    BuildOpts (..),
    ApplyOpts (..),
    RunOpts (..),
    StopOpts (..),
    StatusOpts (..),
    ResultOpts (..),
    ListOpts (..),
    CheckOpts (..),
    DumpOpts (..),
    ProjectConfig (..),
  )
where

import Data.Map.Strict (Map)
import Data.Text (Text)

data Command
  = CmdBuild BuildOpts
  | CmdApply ApplyOpts
  | CmdRun RunOpts
  | CmdStop StopOpts
  | CmdStatus StatusOpts
  | CmdResult ResultOpts
  | CmdList ListOpts
  | CmdCheck CheckOpts
  | CmdDump DumpOpts

newtype BuildOpts = BuildOpts
  { boPath :: Maybe FilePath
  }

data ApplyOpts = ApplyOpts
  { aoDir :: Maybe FilePath,
    aoRuntimeUrl :: Maybe String
  }

data RunOpts = RunOpts
  { roAgentName :: Maybe String,
    roInputJson :: Maybe String,
    roRuntimeUrl :: Maybe String
  }

data StopOpts = StopOpts
  { soAgentId :: Maybe String,
    soRuntimeUrl :: Maybe String
  }

newtype StatusOpts = StatusOpts
  { stRuntimeUrl :: Maybe String
  }

data ResultOpts = ResultOpts
  { reAgentId :: Maybe String,
    reRuntimeUrl :: Maybe String
  }

newtype ListOpts = ListOpts
  { liRuntimeUrl :: Maybe String
  }

newtype CheckOpts = CheckOpts
  { chPath :: Maybe FilePath
  }

newtype DumpOpts = DumpOpts
  { dpPath :: Maybe FilePath
  }

data ProjectConfig = ProjectConfig
  { pcRuntimeUrl :: Maybe Text,
    pcServers :: Map Text Text
  }
