-- |The main entry point for the roshask executable.
module Main (main) where
import Control.Applicative
import qualified Data.ByteString.Char8 as B
import System.Directory (createDirectoryIfMissing, getCurrentDirectory, 
                         getDirectoryContents)
import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode(..))
import System.FilePath (replaceExtension, isRelative, (</>), dropFileName, 
                        takeFileName, dropExtension, takeExtension)
import Ros.Core.Msg.Analysis (runAnalysis)
import Ros.Core.Msg.Parse
import Ros.Core.Msg.Gen
import Ros.Core.Msg.MD5
import Ros.Core.Msg.PkgBuilder (buildPkgMsgs)
import Ros.Core.Build.DepFinder (findPackageDeps, findPackageDepsTrans)
import Ros.Core.Build.Init (initPkg)
import Ros.Core.PathUtil (cap, codeGenDir, pathToPkgName)

-- Get a list of all messages defined in a directory.
pkgMessages :: FilePath -> IO [FilePath]
pkgMessages = fmap (map (cap . dropExtension) .
                    filter ((== ".msg") . takeExtension)) .
              getDirectoryContents

generateAndSave :: FilePath -> IO ()
generateAndSave fname = do msgType <- fst <$> generate fname
                           fname' <- hsName
                           B.writeFile fname' msgType
  where hsName = do d' <- codeGenDir fname
                    createDirectoryIfMissing True d'
                    return $ d' </> f
        f =  replaceExtension (takeFileName fname) ".hs"
        -- d' = d </> "haskell" </> "Ros" </> pkgName

generate :: FilePath -> IO (B.ByteString, String)
generate fname = 
    do r <- parseMsg fname
       pkgMsgs <- map B.pack <$> pkgMessages dir
       case r of
         Left err -> do putStrLn $ "ERROR: " ++ err
                        exitWith (ExitFailure (-2))
         Right msg -> runAnalysis $ 
                      do hMsg <- generateMsgType pkgHier pkgMsgs msg
                         md5 <- msgMD5 msg
                         return (hMsg, md5)
    where pkgHier = B.pack $ "Ros." ++ init pkgName ++ "."
          dir = dropFileName fname
          pkgName = pathToPkgName dir

-- |Run "roshask gen" on all the .msg files in each of the given
-- package directories.
buildDepMsgs :: [FilePath] -> IO ()
buildDepMsgs = runAnalysis . mapM_ buildPkgMsgs

canonicalizeName :: FilePath -> IO FilePath
canonicalizeName fname = if isRelative fname
                         then (</> fname) <$> getCurrentDirectory
                         else return fname

help :: [String]
help = [ "Usage: roshask command [[arguments]]"
       , "Available commands:"
       , "  create pkgName [[dependencies]]  -- Create a new ROS package with "
       , "                                      roshask support"
       , ""
       , "  gen file.msg                     -- Generate Haskell message code"
       , ""
       , "  dep                              -- Build all messages this package "
       , "                                      depends on"
       , ""
       , "  dep directory                    -- Build all messages the specified "
       , "                                      package depends on" 
       , ""
       , "  md5 file.msg                     -- Generate an MD5 sum for a ROS "
       , "                                      message type" ]

main :: IO ()
main = do args <- getArgs
          case args of
            ["gen",name] -> canonicalizeName name >>= generateAndSave
            ["md5",name] -> canonicalizeName name >>= 
                            generate >>= putStrLn . snd
            ("create":pkgName:deps) -> initPkg pkgName deps
            ["dep"] -> do d <- getCurrentDirectory 
                          deps <- findPackageDepsTrans d
                          buildDepMsgs (deps++[d])
            ["dep",name] -> findPackageDeps name >>= (buildDepMsgs . (++[name]))
            _ -> do mapM_ putStrLn help
                    exitWith (ExitFailure (-1))