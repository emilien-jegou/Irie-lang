{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS  -funbox-strict-fields #-}
module ParseSyntax where -- import qualified as PSyn
import Prim
import MixfixSyn
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Control.Lens
import Text.Megaparsec.Pos

type FName        = IName -- record  fields
type LName        = IName -- sumtype labels
type FreeVar      = IName -- non-local argument
type FreeVars     = BitSet
type ImplicitArg  = (IName , Maybe TT) -- implicit (? no) arg with optional type annotation
type NameMap      = M.Map HName IName
type SourceOffset = Int

data Module = Module { -- Contents of a File (Module = Function : _ → Record | Record)
   _moduleName  :: Either HName HName -- Left is file_name , Right read from module Nm ..

 , _functor     :: Maybe FunctorModule
 , _imports     :: [HName]   -- all imports used at any scope
 , _bindings    :: [TopBind] -- hNameBinds

 , _parseDetails :: ParseDetails
}
-- args and signature for the module (return type must be a record)
data FunctorModule = FunctorModule [Pattern] (Maybe TT) SourceOffset

-- HNames and local scope
data ParseDetails = ParseDetails {
   _hNameBinds     :: (Int , NameMap) -- also count anonymous (lambdas) (>= nameMap size)
 , _hNameLocals    :: [NameMap] -- let-bound names stack
 , _hNameArgs      :: [NameMap]
 , _hNameMFWords   :: (Int , M.Map HName [MFWord]) -- keep count to handle overloads (bind & mfword)
 , _freeVars       :: FreeVars
 , _underscoreArgs :: FreeVars
 , _nArgs          :: Int
 , _hNamesNoScope  :: NameMap
 , _fields         :: NameMap
 , _labels         :: NameMap
 , _newLines       :: [Int]
}

-- mark let origin ? `f = let g = G in F` => f.g = G
data TopBind = FunBind { fnDef :: FnDef } -- | PatBind [Pattern] FnDef

data FnDef = FnDef {
   fnNm         :: HName
 , top          :: Bool            -- rm
 , fnRecType    :: !LetRecT        -- or mutual
 , fnMixfixName :: Maybe MixfixDef -- rm (mixfixes are aliases)
 , implicitArgs :: [ImplicitArg]   -- rm
 , fnFreeVars   :: FreeVars
 , fnMatches    :: [FnMatch]
 , fnSig        :: (Maybe TT)      -- rm
}
data FnMatch = FnMatch [ImplicitArg] [Pattern] TT
data LetRecT = Let | Rec | LetOrRec

data TTName
 = VBind   IName
 | VLocal  IName
 | VExtern IName
data LensOp a = LensGet | LensSet a | LensOver a deriving Show
data DoStmt  = Sequence TT | Bind IName TT -- VLocal name
data TT -- Type|Term; Parser Expressions (types and terms are syntactically equivalent)
 = Var !TTName
 | WildCard           -- "_" implicit lambda argument
 | Question           -- "?" ask to infer
 | Foreign   HName TT -- no definition, and we have to trust the user given type
 | ForeignVA HName TT -- var-args for C externs

 -- lambda-calculus
 | Abs TopBind
 | App TT [TT]
 | Juxt SourceOffset [TT] -- may contain mixfixes to resolve

 -- tt primitives (sum , product , list)
-- | Tuple  [TT]   -- like a C struct
-- | Idx    TT Int -- tuples & arrays
 | Cons   [(FName , TT)] -- can be used to type itself
 | TTLens SourceOffset TT [FName] (LensOp TT)
 | Label  LName [TT]
 | Match  [(LName , FreeVars , [Pattern] , TT)] (Maybe (Pattern , TT))
 | List   [TT]

 -- term primitives
 | Lit      Literal
 | LitArray [Literal]

 -- type primitives
 | Quantified [IName] TT
 | TyListOf TT
 | TySum  [(LName , TT , Maybe ([ImplicitArg] , TT))] -- function signature , maybe gadt

 | DoStmts [DoStmt]

-- patterns represent arguments of abstractions
data Pattern
 = PArg   IName -- introduce VLocal arguments
 | PComp  IName CompositePattern

data CompositePattern
 = PLabel LName [Pattern]
 | PCons  [(FName , Pattern)]
 | PTuple [Pattern]
 | PWildCard
 | PLit   Literal

-- | PTT    TT
-- | PTyped Pattern TT
-- | PAs   IName Pattern

-- N is mutual with its name-deps that have N in their name-deps.
-- since a direct search would be O(n!), let inference handle mutuals in O(1)
data ParseState = ParseState {
   _indent      :: Pos    -- start of line indentation (need to save it for subparsers)
-- , _nameDeps    :: BitSet -- what bindings are used by this definition
 , _piBound     :: [[ImplicitArg]]
 , _tmpReserved :: [S.Set Text]

 , _moduleWIP   :: Module -- result
}

makeLenses ''Module
makeLenses ''ParseDetails
makeLenses ''ParseState

showL ind = Prelude.concatMap $ (('\n' : ind) <>) . show
prettyModule m = show (m^.moduleName) <> " {\n"
    <> "imports: " <> showL "  " (m^.imports)  <> "\n"
    <> "binds:   " <> showL "  " (m^.bindings) <> "\n"
--  <> "locals:  " <> showL "  " (m^.locals)   <> "\n"
    <> show (m^.parseDetails) <> "\n}"
prettyParseDetails p = Prelude.concatMap ("\n  " <>) 
    [ "binds:  "   <> show (p^.hNameBinds)
    , "args:   "   <> show (p^.hNameArgs)
    , "extern: "   <> show (p^.hNamesNoScope)
    , "fields: "   <> show (p^.fields)
    , "labels: "   <> show (p^.labels)
    , "newlines: " <> show (p^.newLines)
    ]
prettyTTName :: TTName -> Text = \case
    VBind x   -> "π" <> show x 
    VLocal  x -> "λ" <> show x
    VExtern x -> "?" <> show x

--deriving instance Show Module
deriving instance Show ParseDetails
deriving instance Show FnDef
deriving instance Show TopBind
deriving instance Show TTName
deriving instance Show FnMatch 
deriving instance Show TT
deriving instance Show DoStmt
deriving instance Show CompositePattern
deriving instance Show Pattern
deriving instance Show LetRecT
