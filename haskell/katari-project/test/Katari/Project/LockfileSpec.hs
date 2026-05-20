module Katari.Project.LockfileSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Katari.Project.Lockfile
import Test.Hspec

spec :: Spec
spec = do
  describe "renderLockfile / parseLockfile round-trip" $ do
    it "preserves a minimal snapshot-only lockfile" $ do
      let original =
            Lockfile
              { lockVersion = 1,
                lockSnapshot = Just "2026-05-01",
                lockPackages =
                  Map.fromList
                    [ ( "list_utils",
                        LockedPackage
                          { lockedName = "list_utils",
                            lockedSource =
                              LockedSnapshot
                                { snapshotRepo = "https://github.com/example/list_utils",
                                  snapshotRef = "v0.2.1",
                                  snapshotSha = "abc123"
                                }
                          }
                      )
                    ]
              }
          rendered = renderLockfile original
      case parseLockfile "katari.lock" rendered of
        Left err -> expectationFailure (show err)
        Right parsed -> parsed `shouldBe` original

    it "preserves a path override (no sha required)" $ do
      let original =
            Lockfile
              { lockVersion = 1,
                lockSnapshot = Nothing,
                lockPackages =
                  Map.fromList
                    [ ( "local_fork",
                        LockedPackage
                          { lockedName = "local_fork",
                            lockedSource = LockedPath "../local_fork"
                          }
                      )
                    ]
              }
      case parseLockfile "katari.lock" (renderLockfile original) of
        Left err -> expectationFailure (show err)
        Right parsed -> parsed `shouldBe` original

    it "preserves a git override (resolved SHA + tarball sha256)" $ do
      let original =
            Lockfile
              { lockVersion = 1,
                lockSnapshot = Just "2026-05-01",
                lockPackages =
                  Map.fromList
                    [ ( "bleeding_edge",
                        LockedPackage
                          { lockedName = "bleeding_edge",
                            lockedSource =
                              LockedGit
                                { gitRepoUrl = "https://github.com/foo/bar",
                                  gitRev = "abc1234567890abcdef1234567890abcdef12345",
                                  gitSha = "def456"
                                }
                          }
                      )
                    ]
              }
      case parseLockfile "katari.lock" (renderLockfile original) of
        Left err -> expectationFailure (show err)
        Right parsed -> parsed `shouldBe` original

    it "emits packages in deterministic (alphabetical) order" $ do
      let l =
            Lockfile
              { lockVersion = 1,
                lockSnapshot = Nothing,
                lockPackages =
                  Map.fromList
                    [ ("zeta", LockedPackage "zeta" (LockedPath "./z")),
                      ("alpha", LockedPackage "alpha" (LockedPath "./a")),
                      ("middle", LockedPackage "middle" (LockedPath "./m"))
                    ]
              }
          rendered = Text.lines (renderLockfile l)
          headers =
            [ Text.drop (Text.length "[packages.") (Text.dropEnd 1 h)
              | h <- rendered,
                "[packages." `Text.isPrefixOf` h
            ]
      headers `shouldBe` ["alpha", "middle", "zeta"]

  describe "parseLockfile validation" $ do
    it "rejects an unknown source kind" $ do
      let raw =
            Text.unlines
              [ "[lock]",
                "version = 1",
                "[packages.weird]",
                "source = \"smoke-signals\""
              ]
      parseLockfile "katari.lock" raw `shouldSatisfy` isLeftErr

    it "requires version" $ do
      parseLockfile "katari.lock" "" `shouldSatisfy` isLeftErr
  where
    isLeftErr = \case
      Left _ -> True
      _ -> False
