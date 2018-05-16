{- |
Module      : GenLLVM
Description : Generate the llvm code for the program
Copyright   : Jason Mittertreiner, 2018
-}

{-# LANGUAGE OverloadedStrings #-}
module GenLLVM where

import qualified LLVM.AST as AST
import qualified LLVM.AST.Type as T
import qualified LLVM.AST.Constant as C
import qualified LLVM.AST.IntegerPredicate as IP
import LLVM.IRBuilder.Module
import LLVM.IRBuilder.Monad
import LLVM.IRBuilder.Instruction
import LLVM.IRBuilder.Constant
import qualified Data.Map as M

import Control.Monad.Except
import Errors.CompileError

import Lib.Llvm
import qualified Lib.Types as TP
import qualified Ast.TypedAst as TA
import Data.Char

-- | Generate LLVM for a program
genProg :: [TA.Prog] -> AST.Module
genProg progs =
  let funcs = (\(TA.Prog func) -> func) =<< progs in
    evalCodegen $ buildModuleT "main" (forM funcs genFunc)

-- | Generate LLVM for a function
genFunc :: TA.Function -> ModuleBuilderT Codegen ()
genFunc (TA.Func tpe qname args bdy fret) = do
  -- To enable (mutual) recursion, we declare a function external before
  -- generating the body, then overwrite it with the actual definition
  unless (TP.isMain qname) $ do
    fe <- extern (qn2n qname) (map (toLLVMType . fst) args) (toLLVMType tpe)
    (lift . declFunc (qn2n qname)) fe

  f <- function (qn2n qname) llvmargs (toLLVMType tpe) $ \largs -> do
      -- Create and enter a new block for the function
      emitBlockStart "entry"

      -- Declare the function arguments
      lift $ lift $ declParams $ zip (map (tn2n . snd) args) largs

      -- Generate the body
      forM_ bdy genStm

      -- Return
      r <- genExpr fret
      ret r
  (lift . declFunc (qn2n qname)) f
  where
    nameToSbs n = let (AST.Name sbs) = tn2n n in sbs
    llvmargs = [(toLLVMType t, ParameterName (nameToSbs n)) | (t, n) <- args]

genExpr :: TA.Expr -> LLVMGen AST.Operand
-- | If a name appears as an lval, get the address, not the value
genExpr (TA.BOp op@TP.Assign e1@(TA.Var name _ _ _) e2 _) = do
  let op' = bopToLLVMBop (TA.getExprType e1) (TA.getExprType e2) op
  var' <- (lift . lift . getvar . tn2n) name
  exp' <- genExpr e2
  op' var' exp'
genExpr (TA.BOp op e1 e2 _) = do
  let op' = bopToLLVMBop (TA.getExprType e1) (TA.getExprType e2) op
  e1' <- genExpr e1
  e2' <- genExpr e2
  op' e1' e2'
genExpr (TA.UOp op e1 _) = do
  let op' = uopToLLVMUop (TA.getExprType e1) op
  e1' <- genExpr e1
  op' e1'
-- If the name we are loading is an array, we don't load is since that would
-- give us the first element
genExpr (TA.Var x _ (TP.Arr _ _) _) = (lift . lift .getvar . tn2n) x
genExpr (TA.Var x _ _ _) = let
  name = tn2n x in do
  isDefined <- (lift . lift . isVarDefined) name
  -- Parameters don't need to be loaded. If it's not defined in vars, it must
  -- then be a parameter
  if isDefined then do
      v <- (lift . lift . getvar . tn2n) x
      load v 0 `named` (ntobs x)
      else (lift . lift . getparam . tn2n) x
genExpr (TA.FLit i sz) = case sz of
  TP.F32 -> single (realToFrac i)
  TP.F64 -> double i
  TP.FUnspec -> double i
genExpr (TA.Lit i sz _) = case sz of
  TP.I1 -> bit (fromIntegral i)
  TP.I8 -> byte (fromIntegral i)
  TP.I16 -> word (fromIntegral i)
  TP.I32 -> int32 (fromIntegral i)
  TP.I64 -> int64 (fromIntegral i)
  TP.IUnspec -> int64 (fromIntegral i)
genExpr (TA.Ch c) = byte (fromIntegral (ord c))
genExpr TA.Unit = error "Unit should never be generated"
genExpr (TA.ArrLit exprs tpe) = do
  arrvar <- alloca (toLLVMType tpe) Nothing 0 `named` "arrlit"
  let assigns = zip exprs [0::Int ..]
  forM_ assigns (\(e, i) -> do
           e' <- genExpr e
           ptr <- gep arrvar (int64 0 ++ int64 (fromIntegral i))
           store ptr 0 e')
  return arrvar
genExpr (TA.Call fn _ args _) = do
  largs <- mapM genExpr args
  let params = map (\x -> (x, [])) largs
  func <- (lift . lift . getfunc . qn2n) fn
  call func params
genExpr (TA.CCall _ _) = error "Not yet implemented"
genExpr (TA.ListComp _ _) = error "Not yet implemented"
genExpr (TA.FuncName _ _) = error "Not yet implemented"

genStm :: TA.Statement -> LLVMGen ()
genStm (TA.SBlock s _) = forM_ s genStm
genStm (TA.SExpr e _) = Control.Monad.Except.void (genExpr e)
genStm (TA.SDecl name tpe _) = do
  var <- alloca (toLLVMType tpe) Nothing 0 `named` (ntobs name)
  (lift . lift . declvar (tn2n name)) var
genStm (TA.SDeclAssign name tpe e _) = do
  var <- alloca (toLLVMType tpe) Nothing 0 `named` (ntobs name)
  e' <- genExpr e
  (lift .lift . declvar (tn2n name)) var
  let op = bopToLLVMBop tpe (TA.getExprType e) TP.Assign
  void $ op var e'
genStm (TA.SWhile e bdy _) = do
  whiletest <- freshName "while.test"
  whileloop <- freshName "while.loop"
  whileexit <- freshName "while.exit"
  br whiletest
  emitBlockStart whiletest
  cond <- genExpr e
  test <- icmp IP.NE (AST.ConstantOperand (C.Int 1 0)) cond
  condBr test whileloop whileexit
  emitBlockStart whileloop
  genStm bdy
  br whiletest
  emitBlockStart whileexit
genStm (TA.ForEach name exp stmnt _) = do
  fordecl <- freshName "foreach.decl"
  fortest <- freshName "foreach.test"
  forloop <- freshName "foreach.loop"
  forexit <- freshName "foreach.exit"

  br fordecl
  emitBlockStart fordecl
  -- Generate the array
  exp' <- genExpr exp

  -- Declare the element we are focusing
  let (TP.Arr elemTpe len) = TA.getExprType exp
  var <- alloca (toLLVMType elemTpe) Nothing 0 `named` (ntobs name)
  (lift . lift . declvar (tn2n name))  var

  -- Declare a counter to track where we are in the array
  cntr <- alloca T.i64 Nothing 0 `named` "cntr"
  store cntr 0 (AST.ConstantOperand (C.Int 64 0))

  br fortest
  emitBlockStart fortest
  -- loop until we've gone through the array
  cntr_val <- load cntr 0
  test <- icmp IP.EQ (AST.ConstantOperand (C.Int 64 (fromIntegral len))) cntr_val
  condBr test forexit forloop
  emitBlockStart forloop

  -- Set the element we are iterating on
  let access = bopToLLVMBop (TP.Arr elemTpe len) (TP.Int TP.I64 TP.Signed) TP.ArrAccessR
  val <- access exp' cntr_val
  store var 0 val
 -- store var 0 (AST.ConstantOperand (C.Int 64 0))
  genStm stmnt
  -- Increment our counter
  add1 <- add cntr_val (AST.ConstantOperand (C.Int 64 1))
  store cntr 0 add1
  -- Loop
  br fortest

  emitBlockStart forexit

genStm (TA.SIf e bdy _) = do
  ifblock <- freshName "if.block"
  ifend <- freshName "if.exit"
  cond <- genExpr e
  test <- icmp IP.NE (AST.ConstantOperand (C.Int 1 0)) cond
  condBr test ifblock ifend
  emitBlockStart ifblock
  genStm bdy
  br ifend
  emitBlockStart ifend
genStm (TA.Kernel _ _) = error "Not yet implemented"

genLLVM :: M.Map TP.ModulePath TA.Prog -> Either CompileError AST.Module
genLLVM = Right . (\d -> d{AST.moduleTargetTriple=Just "x86_64-pc-linux-gnu"}) . genProg . M.elems
