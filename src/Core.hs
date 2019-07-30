module Core where
import qualified LLVM.AST.Type
import qualified LLVM.AST (Operand, Type)
import Data.Vector
import Data.Map

-- Core Language
-- recall: ParseSyn >> CoreExpr >> STG codegen
-- The language for type judgements: checking and inferring
-- Type checking in the presence of higher rank types can be undecidable !
-- dependent types are an additional source of undecidability

data CoreModule = CoreModule {
   env      :: Env -- info for all bound entities (type/name etc..)
 , topBinds :: Data.Vector CoreExpr -- local bindings (name and rhs)

 -- how to infer a polytype when multiple monotypes are available
 , defaults :: Data.Map PolyType MonoType
 }

-- to instantiate monotypes from constrainted polytypes
--   1. check default declarations
--   2. filter all known monotypes (!)
type Env = Env
 { envBinds   :: Vector Entity  -- monoTypes (includes forall a. a)
 }

data Entity = Entity -- entity info
 { named :: (Maybe String)
 , typed :: Type
 , universe :: Int -- val/type/kind/sort/...
 }

data CoreExpr
 = Var Name
 | Lit Literal
 | App Expr Expr
 | Let Binds Expr
 | Case Expr [Alt]
 | TypeExpr Type -- dependent types
-- | Subsume CoreExpr CoreExpr -- (~cast) questionnable if useful before STG

data Binds = Bind Name CoreExpr
data Alt = Alt Pat CoreExpr
data Pat = PVar Name | PLit Literal | PApp Name [Pat] | PWildCard

data Literal -- same as in ParseSyntax (we haven't finished type inference yet)
 = Char Char | String String | Int Integer | Frac Rational
 | LlvmLit LLVM.AST.Operand -- everything must end up here

-----------
-- Types --
-----------
-- subsumption: s1 <= s2 means s1 is at least as polymorphic as s2
--   (it's less specific)
-- sharing: forall a b. a->[b] <= forall a. a->[a]
-- note: forall a. Int->a <= Int->(forall b. b->b)
--   (higher rank polytypes are less polymorphic)
--
-- Judgements combine inference and checking:
-- box: an inferred vanilla type
--  (boxes cannot be nested: outside is checked, inside inferred)
-- boxy types: contain >=0 boxes
-- boxy matching: fill boxes with monotypes (no instantiation/skolemization)
-- pushBox: if entire result type is a box, push down the fn App and try again
-- =~ make new holes for arg and ret types
--
-- we need that |forall b. b->b| <= forall b. b->b
-- box meets box implies: a->|s| ~ |a->s| , since otherwise |s|~|s| which is wrong
-- By design, boxy matching is not an equivalence relation: it is not reflexive
-- (that would require guessing polytype info)
-- neither is it transitive |s|~s and s~|s| but not |s|~|s|.
-- likewise subsumption is neither reflexive nor transitive (for boxy types)
--
-- Removing boxes:
-- if s->s <= |s|->s, then we should derive s->s<=s->s
-- we can 'push boxes down': if |s->s| <= s->s, we also have |s|->|s| <= s->s
--   this can be proven to preserve boxy matching, subsumption and typability
-- Unboxing lemmas: (s1|>s2 means that s2 can be constructed from s1
--   by removing or pushing boxes down the AST)
-- 1. if s1~s2 and s1|>s3 and s2|>s4 then s3~s4
-- 2. if s1<=s2 and s1|>s3 and s2|>s4 then s3<=s4
-- 3. if t:p1 and p1|>p2 then t:p2
-- note. for monotypes, boxing/unboxing does not matter
--
-- Environment: types support lexically scoped type variables
-- scoped type vars are flexible = arbitrary types rather than variables.

-- types are stratified into monotypes 't' and polytpes 's' and 'p'
-- 'p' types have no toplevel foralls, but may contain polytypes
-- Boxed (inferred) types are stratified in exactly the same way
-- Note: boxes are not nested, so we track it during type judging
type MonoType = LLVM.AST.Type
type PolyType = Forall
data Type
 = TyMono MonoType -- monotypes 't'
 | TyPoly PolyType -- constrained polytypes 'p', 's'

 | TyArrow [Type]  -- ~ function (also TySum sumtype alternatives)
 | TyProd  [Type]

 | TyExpr CoreExpr -- dependent types

 | TyBoxed Type    -- inferred type (temporary annotation)
 | TyUnknown       -- default state for an expression - we need to infer it

data Forall
 = ForallAnd [Type] -- & constraints
 | ForallOr  [Type] -- | constraints
 | ForallAny -- essentially same as an opaque monotype (eg. len : [a]->Int)
