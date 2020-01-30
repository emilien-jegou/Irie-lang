{-# LANGUAGE OverloadedStrings #-}
module PrettyCore where

import Prim
import CoreSyn

import qualified Data.Vector        as V
import qualified Data.Text          as T
import qualified Data.List          as DL
import qualified Data.IntMap.Strict as IM
import Text.Printf
import Debug.Trace

ppType' = ppType (\x -> "$" ++ show x)
ppType :: (IName -> String) -> Type -> String = \deref -> clCyan . \case
 TyAlias nm      -> deref nm
 TyRigid r       -> printf "rigid: %d(%v)" r (deref r)
 TyMono m        -> case m of
   MonoTyPrim lty  -> case lty of
     other         -> show other
   MonoSubTy r p i -> printf "subTy %d : %d <= %d" i r p

 TyPoly p        -> show p
 TyArrow tys     -> clNormal ++ "(" ++ (concat $ DL.intersperse " -> "
                           (ppType deref <$> tys)) ++ ")"
-- TyPAp tys ty -> "PAp (" ++ ppType deref (TyArrow tys) ++ ") -> "
--                  ++ ppType deref (TyArrow tys)
 TyInstance ty o -> show ty ++ " ! " ++ show o
 t@TyFn{}   -> show t
 TyUnknown       -> "TyUnknown"
 TyBroken        -> "tyBroken"
 other           -> show other

ppCoreExpr :: (IName -> String) -> (IName -> String)
           -> String -> CoreExpr -> String
 = \deref derefTy indent ->
 let ppCoreExpr' = ppCoreExpr deref derefTy indent
     ppType'     = ppType derefTy
 in \e -> case e of
  Var n -> deref n
  Lit l -> show l
  App f args ->
    let parenthesize x = "(" ++ ppCoreExpr' x ++ ")" 
    in ppCoreExpr' (Var f) ++" "++ concat (DL.intersperse " " (parenthesize <$> args))
  -- Let binds e -> error "let in coreexpr" --"let "++ppBinds (\x->Nothing) binds++"in "++ ppCoreExpr e
  Case c a -> case a of
    Switch alts -> "case "++ppCoreExpr' c++show alts
    Decon  alts -> "case " ++ ppCoreExpr' c ++ " of" ++ "\n" ++ (concat $ DL.intersperse "\n" $ (ppDataAlt deref (indent++"  "))<$> alts)
  TypeExpr ty -> "TypeExpr: " ++ ppType' ty
  l -> show l

ppDataAlt :: (IName -> String) -> String -> (IName, [IName], CoreExpr) -> String
ppDataAlt deref indent (con, args, ret) = indent ++
 deref con ++ (concatMap (\x -> " " ++ (deref x)) args) ++ " -> " ++ 
 ppCoreExpr deref (\_->"fixpls") (indent++"  ") ret

showMaybeName = \case { Just nm -> show nm ; Nothing -> "_" }

ppBinds :: [Binding] -> (IName -> String) -> (IName -> String) -> String
 = \l f derefTy -> concat $ zipWith (ppBind f derefTy "\n   ") [0..] l
ppBind f derefTy indent lineNumber b =
  let ppEntity' = ppEntity derefTy
  in clGreen indent ++ show lineNumber ++ ": " ++ case b of
  LTypeVar e -> "tyVar " ++ showMaybeName (named e) ++ ": " ++ show (typed e)
  LBind entity args e -> showMaybeName (named entity)
    ++ " " ++ show args 
    ++ " : " ++ ppType derefTy (typed entity)
    ++ {-indent ++-} " = " ++ ppCoreExpr f derefTy "" e
  LArg a u  -> "larg: "    ++ ppEntity' a ++ " used " ++ show u
  LCon a    -> "lcon: "    ++ ppEntity' a
  LClass a b c-> "lclass: "  ++ ppEntity' a ++ " >= " ++ show b ++ show c
  LExtern a -> "lextern: " ++ ppEntity' a
  LInstr a instr -> "LInstr: " ++ ppEntity' a ++ " = " ++ show instr
  Inline a e-> "inline: " ++ ppEntity' a ++ " = " ++ ppCoreExpr f derefTy "" e

ppCoreModule :: CoreModule -> String
 = \(CoreModule hNm typeMap bindings n classDecls defaults fixities tyConInstances _ _) ->
  let derefTy  i = bind2HName        (typeMap  V.! i) i
      derefVar i = bind2HName (info (bindings V.! i)) i
      ppEntity'  = ppEntity derefTy
  in
     clCyan "-- types --\n"
  ++ concat (V.imap (\i x->show i ++ " " ++ ppEntity' x ++ "\n")typeMap)
  ++ clGreen "\n-- Top bindings --"
  ++ concat (V.imap (ppBind derefVar derefTy "\n") $ V.take n bindings)
  ++ clGreen "\n-- locals --"
  ++ concat (V.imap (\i->ppBind derefVar derefTy "\n" (n+i) ) $ V.drop n bindings)
  ++ "\n\n" ++ clMagenta "-- defaults --\n" ++ show defaults
  ++ "\n" ++ clRed "-- Class decls --\n"++ ppClassDecls classDecls

ppClassDecls classDecls
 = DL.intercalate "\n" $ show <$> V.toList classDecls

-- function to convert an entity to a stringname
bind2HName entity i = case named entity  of
       Just x -> T.unpack x
       Nothing-> "%" ++ show i

--ppCoreBinds :: CoreModule -> String
-- = \cm
--   -> let binds = bindings cm
--          top = V.filter (\case { LBind{} -> True ; _ -> False }) binds
--      in concat ((ppBind (bind2HName binds) "\n") <$> top)

ppEntity derefTy ent = --(Entity nm ty) = 
  case named ent of
    Just nm -> show nm
    Nothing -> show ""
  ++ " := " ++ ppType derefTy (typed ent)

clBlack   x = "\x1b[30m" ++ x ++ "\x1b[0m"
clRed     x = "\x1b[31m" ++ x ++ "\x1b[0m" 
clGreen   x = "\x1b[32m" ++ x ++ "\x1b[0m"
clYellow  x = "\x1b[33m" ++ x ++ "\x1b[0m"
clBlue    x = "\x1b[34m" ++ x ++ "\x1b[0m"
clMagenta x = "\x1b[35m" ++ x ++ "\x1b[0m"
clCyan    x = "\x1b[36m" ++ x ++ "\x1b[0m"
clWhite   x = "\x1b[37m" ++ x ++ "\x1b[0m"
clNormal = "\x1b[0m"
