-- Command line arguments
module CmdLine (CmdLine(..) , parseCmdLine, defaultCmdLine) where
import Options.Applicative
import Data.Text as T

data CmdLine = CmdLine
  { printPass      :: [Text]
  , jit            :: Bool
  , noColor        :: Bool
  , repl           :: Bool
  , optlevel       :: Word
  , threads        :: Int
  , noPrelude      :: Bool
  , noCache        :: Bool
--  , reportErrors   :: Bool -- print an error summary (not doing so is probably only useful for the test suite)
  , recompile      :: Bool   -- recompile even if cached
  , quiet          :: Bool
  , outFile        :: Maybe FilePath
  , strings        :: String -- work on text from the commandline (as opposed to reading it from a file)
  , files          :: [FilePath]
  } deriving (Show)

defaultCmdLine = CmdLine -- Intended for use from ghci
  { printPass      = []
  , jit            = False
  , noColor        = True
  , repl           = False
  , optlevel       = 0
  , threads        = 1
  , noPrelude      = False
  , noCache        = False
  , recompile      = False
  , quiet          = False
  , outFile        = Nothing
  , strings        = []
  , files          = []
  }

printPasses = T.words "args source parseTree types core simple ssa C" :: [Text]

parsePrintPass :: ReadM [Text]
parsePrintPass = eitherReader $ \str -> let
  passesStr = split (==',') (toS str)
  checkAmbiguous s = case Prelude.filter (isInfixOf s) printPasses of
    []  -> Left $ "Unrecognized print pass: '" <> str <> "'"
    [p] -> Right p
    tooMany -> Left $ "Ambiguous print pass: '" <> str <> "' : " <> show tooMany
  in sequence (checkAmbiguous <$> passesStr)

cmdLineDecls :: Parser CmdLine
cmdLineDecls = CmdLine
  <$> (option parsePrintPass)
      (short 'p' <> long "print"
      <> help (toS $ "list of compiler passes to print (separated by ',') : [" <> T.intercalate " | " printPasses <> "]")
      <> value [])
  <*> switch
      (short 'j' <> long "jit"
      <> help "Execute 'main' binding in jit")
  <*> switch
      (short 'N' <> long "no-color"
      <> help "Don't print ANSI color codes")
  <*> switch
      (short 'r' <> long "repl"
      <> help "Interactive read-eval-print loop")
  <*> option auto
      (short 'O'
      <> help "Optimization level 0|1|2|3"
      <> value 0)
  <*> option auto
      (short 't' <> long "threads"
      <> help "Number of threads >0 to run concurrently (should use far less RAM than forking the compiler on each file)"
      <> value 1)
  <*> switch
      (short 'n' <> long "no-prelude"
      <> help "Don't import prelude implicitly")
  <*> switch
      (             long "no-cache"
      <> help "Don't save or re-use compiled files")
  <*> switch
      (             long "recompile"
      <> help "recompile even if cached file looks good")
  <*> switch
      (             long "quiet"
      <> help "print less to stdout")
  <*> (optional . strOption) (
      (short 'o')
      <> help "Write output to FILE")
  <*> (strOption
      (short 'e' <> long "expression"
      <> metavar "STRING"
      <> help "Add the binding to the 'CmdLineBindings' module"
      <> value ""))
  <*> many (argument str (metavar "FILE"))

progDescription = "Compiler and Interpreter for the Irie language, a subtyping CoC for system level programming."
cmdLineInfo =
  let description = fullDesc
        <> header "Irie compiler/interpreter"
        <> progDesc progDescription
  in info (helper <*> cmdLineDecls) description

-- parseCmdLine :: IO CmdLine
-- parseCmdLine = execParser cmdLineInfo
-- parseCmdLine = customExecParser (prefs disambiguate) cmdLineInfo
parseCmdLine :: [String] -> IO CmdLine
 = \rawArgs -> handleParseResult $ execParserPure (prefs disambiguate) cmdLineInfo rawArgs
