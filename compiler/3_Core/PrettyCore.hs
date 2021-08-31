module PrettyCore where
import Prim
import CoreSyn
import ShowCore()
import qualified Data.Vector as V
import qualified Data.Text as T
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Text.Printf

parens x = "(" <> x <> ")"
unParens x = if T.head x == '(' then T.drop 1 (T.dropEnd 1 x) else x

prettyBind showExpr bindSrc = \case
  Checking m e g ty     -> "CHECKING: " <> show m <> show e <> show g <> " : " <> show ty
  Guard m ars tvar      -> "GUARD : " <> show m <> show ars <> show tvar
  Mutual d m isRec tvar -> "MUTUAL: " <> show d <> show m <> show isRec <> show tvar
  WIP -> "WIP"
  BindOK expr -> prettyExpr' showExpr bindSrc "\n  " expr <> "\n"

prettyExpr showExpr bindSrc = prettyExpr' showExpr bindSrc ""
prettyExpr' showExpr bindSrc pad = let
  showExpr = True
  pE  = prettyExpr' showExpr bindSrc pad
  pTy = prettyTy (Just bindSrc)
  pT = prettyTerm bindSrc
  in \case
  Core term ty -> let prettyTy = clGreen  $ " : " <> unParens (pTy ty)
    in if showExpr then " = " <> pad <> pT term <> prettyTy else prettyTy
  Ty t         -> " =: " <> pad <> clGreen (pTy t)
  ExprApp f a -> pE f <> "[" <> (T.intercalate " " $ pE <$> a) <> "]"
  e -> pad <> show e

prettyVName bindSrc = \case
  VArg i  -> "λ" <> show i
--VBind i -> "π" <> show i <> "\"" <> (T.unpack $ (srcBindNames bindSrc) V.! i) <> "\""
  VBind i -> let nm = toS $ (srcBindNames bindSrc) V.! i in if nm == "_" then "π" <> show i else "\"" <> nm <> "\""
  VExt i ->  "E" <> show i <> "\"" <> (toS $ (srcExtNames  bindSrc) V.! i) <> "\""

--prettyTerm :: _ -> _ -> _ -> _ -> Text
prettyTerm bindSrc = let
  pTy = prettyTy (Just bindSrc)
  pT  = prettyTerm  bindSrc
  pE  = prettyExpr  False bindSrc
  pE' = prettyExpr' False bindSrc
  prettyFree x = if IS.null x then "" else "Γ(" <> show x <> ")"
  in \case
  Hole -> " _ "
  Var     v -> clCyan $ prettyVName bindSrc v
  Lit     l -> clMagenta $ show l
  Abs ars free term ty -> let
    prettyArg' (i , ty) = show i
    in {-pad <> -} parens $ (clYellow $ "λ " <> T.intercalate " " (prettyArg' <$> ars)) <> prettyFree free <> " => " {-<> pad-} <> pT term
     -- <> "   : " <> clGreen (pTy ty)
  App     f args -> "(" <> pT f <> clMagenta " < " <> T.intercalate " " (pT <$> args) <> ")"
  Instr   p -> "%" <> show p <> "%"
  Cast  i t -> "(" <> show i <> ")<" <> show t <> ">"

  Cons    ts -> let
    sr (field , val) = show field <> " " <> (toS $ srcFieldNames bindSrc V.! field) <> "@" <> pT val
    in "{ " <> (T.intercalate " ; " (sr <$> IM.toList ts)) <> " }"
--Proj    t f -> pT t <> "." <> show f <> (toS $ srcFieldNames bindSrc V.! f)
  Label   l t -> prettyLabel l <> "@" <> T.intercalate " " (parens . pE <$> t)
  Match caseTy ts d -> let
    showLabel l t = prettyLabel l <> " => " <> pE' "" t
    in clMagenta "\\case " <> clGreen (" : " <> pTy caseTy) <> ")\n    | "
      <> T.intercalate "\n    | " (IM.foldrWithKey (\l k -> (showLabel l k :)) [] ts) <> "\n    |_ " <> maybe "Nothing" pE d <> "\n"
--List    ts -> "[" <> (T.concatMap pE ts) <> "]"

  TTLens r target ammo -> pT r <> " . " <> T.intercalate "." (show <$> target) <> prettyLens bindSrc ammo

prettyLabel = clMagenta . show

prettyLens bindSrc = \case
  LensGet -> " . get "
  LensSet  tt -> " . set ("  <> prettyExpr False bindSrc tt <> ")"
  LensOver cast tt -> " . over (" <> "<" <> show cast <> ">" <> prettyExpr False bindSrc tt <> ")"

prettyTyRaw = prettyTy Nothing

--prettyTy :: _ -> _ -> Type -> Text
prettyTy bindSrc = let
  pTH = prettyTyHead bindSrc
  in \case
  []  -> "_"
  [x] -> pTH x
  x   -> "(" <> (T.intercalate " & " $ pTH <$> x) <> ")"

number2CapLetter i = let
  letter = (chr ((i `mod` 26) + ord 'A'))
  overflow = i `div` 26
  in if overflow > 0 then (letter `T.cons` show overflow) else T.singleton letter
number2xyz i = let
  letter = (chr ((i `mod` 3) + ord 'x'))
  overflow = i `div` 3
  in if overflow > 0 then (letter `T.cons` show overflow) else T.singleton letter

prettyTyHead bindSrc = let
 pTy = prettyTy bindSrc
 pTH = prettyTyHead bindSrc
 in \case
 THTop        -> "⊤"
 THBot        -> "⊥"
 THPrim     p -> prettyPrimType p
-- THArg      i -> "λ" <> show i
 THVar      i -> "τ" <> show i
 THBound    i -> number2CapLetter i
-- THBound    i -> "∀" <> show i
 THMuBound  t -> {-"μ" <>-} number2xyz t
 THMu v     t -> "μ" <> number2xyz v <> "." <> pTy t
-- THImplicit i -> "∀" <> show i
-- THAlias    i -> "π" <> show i
 THExt      i -> "E" <> show i
-- THRec      t -> "Rec" <> show t

 THTyCon t -> case t of
   THArrow    [] ret -> error $ toS $ "panic: fntype with no args: [] → (" <> pTy ret <> ")"
   THArrow    args ret -> parens $ T.intercalate " → " (pTy <$> (args <> [ret]))
   THSumTy   l -> let
     prettyLabel (l,ty) = (maybe (show l) (\bindSrc -> toS (srcLabelNames bindSrc V.! l)) bindSrc) <> " : " <> pTy ty
     in "[" <> T.intercalate " | " (prettyLabel <$> IM.toList l) <> "]"
   THProduct l -> let
     prettyField (f,ty) = (maybe (show f) (\bindSrc -> toS (srcFieldNames bindSrc V.! f)) bindSrc) <> " : " <> pTy ty
     in "{" <> T.intercalate " , " (prettyField <$> IM.toList l) <> "}"
   THTuple  l  -> "{" <> T.intercalate " , " (pTy <$> V.toList l) <> "}"

   THArray    t -> "@" <> show t

-- THBi i t -> "∏(#" <> show i  <> ")" <> pTy t
 THBi i t -> "∏ " <> (T.intercalate " " $ number2CapLetter <$> [0..i-1]) <> " → " <> pTy t
 THPi pi  -> "∏(" <> show pi <> ")"
 THSi pi arsMap -> "Σ(" <> show pi <> ") where (" <> show arsMap <> ")"
-- THCore t ty -> "↑(" <> show t <> " : " <> show ty <> ")" -- term in type context

 THSet   uni -> "Set" <> show uni
 THRecSi f ars -> "(μf" <> show f <> " $! " <> T.intercalate " " (show <$> ars) <> ")"
 THFam f ixable ix -> let
   fnTy = case ixable of { [] -> f ; x -> [THTyCon $ THArrow x f] }
   indexes = case ix of { [] -> "" ; ix -> " $! (" <> T.intercalate " " (show <$> ix) <> "))" }
   in "(Family " <> pTy fnTy <> ")" <> indexes
-- THInstr i ars -> show i <> show ars
 x -> show x

clBlack   x = "\x1b[30m" <> x <> "\x1b[0m"
clRed     x = "\x1b[31m" <> x <> "\x1b[0m" 
clGreen   x = "\x1b[32m" <> x <> "\x1b[0m"
clYellow  x = "\x1b[33m" <> x <> "\x1b[0m"
clBlue    x = "\x1b[34m" <> x <> "\x1b[0m"
clMagenta x = "\x1b[35m" <> x <> "\x1b[0m"
clCyan    x = "\x1b[36m" <> x <> "\x1b[0m"
clWhite   x = "\x1b[37m" <> x <> "\x1b[0m"
clNormal = "\x1b[0m"
