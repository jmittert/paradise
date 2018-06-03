{- |
Module      : GenLLVM
Description : Generate the llvm code for the program
Copyright   : Jason Mittertreiner, 2018
-}
{-# LANGUAGE OverloadedStrings #-}

module GenLLVM where

import qualified Data.Map as M

import qualified LLVM.AST as AST
import qualified LLVM.AST.Constant as C
import qualified LLVM.AST.InlineAssembly as IA
import qualified LLVM.AST.IntegerPredicate as IP
import qualified LLVM.AST.Type as T
import qualified LLVM.AST.CallingConvention as CC
import LLVM.IRBuilder.Constant
import LLVM.IRBuilder.Instruction
import LLVM.IRBuilder.Module
  -- Hide this one since we define our own which can set varargs
 hiding (extern)
import LLVM.IRBuilder.Monad

import Control.Monad.Except
import Errors.CompileError
import Control.Monad.State.Lazy

import qualified Ast.TypedAst as TA
import qualified Ast.OpenCLAst as CLA
import qualified Data.ByteString.Char8 as BS
import Data.Char
import Lib.Llvm
import Lib.Format
import qualified Lib.Types as TP
import GenCL

genLLVM ::
     M.Map TP.ModulePath TA.Module
  -> Either CompileError (M.Map TP.ModulePath (AST.Module, [CLA.Kernel]))
genLLVM mods =
  let llvmMods = fmap genModule mods
   in Right llvmMods

-- | Generate LLVM for a module
genModule :: TA.Module -> (AST.Module, [CLA.Kernel])
genModule mod =
  let funcs = TA.funcs mod
      cfuncs = TA.cfuncs mod
      imports = TA.importFuncs mod
      (amod, st) = (runCodegen $
        buildModuleT "main" $ do
          forM_ cfuncs externCFunc
          forM_ imports externFunc
          forM funcs genFunc)
      mod' = amod {
        AST.moduleTargetTriple = Just "x86_64-pc-linux-gnu"
        , AST.moduleSourceFileName = ntobs (TP.Name (TP.modulePathToFile (TA.mname mod)))
        }
      kerns = kernels st
  in (mod', kerns)

externCFunc :: TP.CFunc -> ModuleBuilderT Codegen ()
externCFunc (TP.CFunc n tpe args) = do
  let isVarArgs = any (== TP.Varargs) args
  if isVarArgs
    then do
      let args' = (reverse . tail . reverse) args
      f <- extern (tn2n n) (map toLLVMType args') (toLLVMType tpe) isVarArgs
      (lift . declFunc (tn2n n)) f
    else do
      f <- extern (tn2n n) (map toLLVMType args) (toLLVMType tpe) isVarArgs
      (lift . declFunc (tn2n n)) f

-- | Generate an external declaration for a function
externFunc :: (TP.QualifiedName, TP.Def) -> ModuleBuilderT Codegen ()
externFunc (qname, TP.FuncDef tpe args)
 = do
  -- Normal paradise functions cannot be varargs
  let isVarArgs = False
  fe <-
    extern
      (qn2n qname)
      (map (box . toLLVMType) args)
      (toLLVMType tpe)
      isVarArgs
  (lift . declFunc (qn2n qname)) fe
externFunc (_, a) = error $ "Cannot declare extern non func: " ++ show a

-- | Generate LLVM for a function
genFunc :: TA.Function -> ModuleBuilderT Codegen ()
genFunc (TA.Func tpe qname args bdy fret)
  -- To enable (mutual) recursion, we declare a function external before
  -- generating the body, then overwrite it with the actual definition
 = do
  f <-
    function (qn2n qname) llvmargs (toLLVMType tpe) $ \largs
      -- Create and enter a new block for the function
     -> do
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
    nameToSbs n =
      let (AST.Name sbs) = tn2n n
       in sbs
    llvmargs = [((box . toLLVMType) t, ParameterName (nameToSbs n)) | (t, n) <- args]

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
genExpr (TA.Var x _ _ _) =
  let name = tn2n x
   in do isDefined <- (lift . lift . isVarDefined) name
  -- Parameters don't need to be loaded. If it's not defined in vars, it must
  -- then be a parameter
         if isDefined
           then do
             v <- (lift . lift . getvar . tn2n) x
             load v 0 `named` ntobs x
           else (lift . lift . getparam . tn2n) x
genExpr (TA.FLit i sz) =
  case sz of
    TP.F32 -> single (realToFrac i)
    TP.F64 -> double i
    TP.FUnspec -> double i
genExpr (TA.Lit i sz _) =
  case sz of
    TP.I1 -> bit (fromIntegral i)
    TP.I8 -> byte (fromIntegral i)
    TP.I16 -> word (fromIntegral i)
    TP.I32 -> int32 (fromIntegral i)
    TP.I64 -> int64 (fromIntegral i)
    TP.IUnspec -> int64 (fromIntegral i)
genExpr (TA.Ch c) = byte (fromIntegral (ord c))
genExpr TA.Unit = error "Unit should never be generated"
genExpr (TA.ArrLit exprs tpe@(TP.Arr _ arrlen)) = do
  -- For each type or array, we need to declare the corresponding struct
  arrvar <- alloca (toLLVMType tpe) Nothing 0 `named` "arrlit"
  let assigns = zip exprs [0 :: Int ..]
  forM_
    assigns
    (\(e, i) -> do
       e' <- genExpr e
       ptr <- gep arrvar (int32 0 ++ int32 1 ++ int32 (fromIntegral i))
       store ptr 0 e')
  lenptr <- gep arrvar (int32 0 ++ int32 0)
  store lenptr 0 (AST.ConstantOperand (C.Int 64 (fromIntegral arrlen)))
  casted <- bitcast arrvar (T.ptr (removeLen (toLLVMType tpe)))
  return casted
genExpr (TA.ArrLit _ _) = error "ArrLit of non arr type"
genExpr (TA.Call fn def args _) = do
  largs <- mapM genExpr args
  let params = map (\x -> (x, [])) largs
  let func = mkFuncRef (qn2n fn) def
  call func params
genExpr (TA.CCall fn (TP.CFunc _ tpe fargs) args _) = do
  -- A ccall is like a call, but we need to first convert all the paradise types
  -- into c types
  largs <- mapM genCExpr args
  let params = map (\x -> (x, [])) largs
  let func = mkFuncRef (qn2n (TP.mkQName (TP.ModulePath []) fn)) (TP.FuncDef tpe fargs)
  call func params
genExpr (TA.ListComp _ _) = error "Not yet implemented"
genExpr (TA.FuncName _ _) = error "Not yet implemented"

genCExpr :: TA.Expr -> LLVMGen AST.Operand
-- In all othercases fallback to regular genExpr
genCExpr v@(TA.Var _ _ (TP.Arr _ _) _) = do
  -- For arrays, we load the pointer to the data
  arr <- genExpr v
  ptr <- gep arr (int32 0 ++ int32 1)
  load ptr 0
genCExpr a@(TA.ArrLit _ _) = do
  arr <- genExpr a
  ptr <- gep arr (int32 0 ++ int32 1)
  load ptr 0
genCExpr a = genExpr a

genStm :: TA.Statement -> LLVMGen ()
genStm (TA.SBlock s _) = forM_ s genStm
genStm (TA.SExpr e _) = Control.Monad.Except.void (genExpr e)
genStm (TA.SDecl name tpe _) = do
  var <- alloca (box (toLLVMType tpe)) Nothing 0 `named` ntobs name
  (lift . lift . declvar (tn2n name)) var
genStm (TA.SDeclAssign name tpe e _) = do
  var <- alloca (box (toLLVMType tpe)) Nothing 0 `named` ntobs name
  e' <- genExpr e
  (lift . lift . declvar (tn2n name)) var
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
  var <- alloca (toLLVMType elemTpe) Nothing 0 `named` ntobs name
  (lift . lift . declvar (tn2n name)) var
  -- Declare a counter to track where we are in the array
  cntr <- alloca T.i64 Nothing 0 `named` "cntr"
  store cntr 0 (AST.ConstantOperand (C.Int 64 0))
  let getLen =  uopToLLVMUop (TP.Arr elemTpe len) TP.Len
  arrlen <- getLen exp'
  br fortest
  emitBlockStart fortest
  -- loop until we've gone through the array
  cntr_val <- load cntr 0
  test <- icmp IP.EQ arrlen cntr_val
  condBr test forexit forloop
  emitBlockStart forloop
  -- Set the element we are iterating on
  let access =
        bopToLLVMBop
          (TP.Arr elemTpe len)
          (TP.Int TP.I64 TP.Signed)
          TP.ArrAccessR
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
genStm (TA.Kernel k _) = do
  let kernel = evalState (runCLState (genCL k)) emptyCLState
  let params = CLA.params kernel
  let outputs = CLA.outputs kernel
  let kname = CLA.name kernel
  mkCLContext kname
  mkCLInputs params
  callKernel kname
  mkCLOutputs outputs
  return ()
genStm (TA.Asm e o i c _ _ TP.Void) = do
  -- Assembly can be "called" by llvm as if it was a function
  let oconstrs = map fst o
  let iconstrs = map fst i
  let cconstrs = case c of Just a -> [a]; Nothing -> []
  let constrs = commaListS (oconstrs ++ iconstrs ++ cconstrs)
  args <- mapM genExpr (map snd i)
  let asm = IA.InlineAssembly
        T.VoidType
        (BS.pack e)
        (ntobs (TP.Name constrs))
        True  -- hasSideEffects
        False -- alignStack
        IA.ATTDialect
  let instr = AST.Call {
    AST.tailCallKind = Nothing
  , AST.callingConvention = CC.C
  , AST.returnAttributes = []
  , AST.function = Left asm
  , AST.arguments = zip args (repeat [])
  , AST.functionAttributes = []
  , AST.metadata = []
  }
  emitInstrVoid instr


genStm (TA.Asm e o i c _ _ t) = do
  -- Assembly can be "called" by llvm as if it was a function
  let oconstrs = map fst o
  let iconstrs = map fst i
  let cconstrs = case c of Just a -> [a]; Nothing -> []
  let constrs = commaListS (oconstrs ++ iconstrs ++ cconstrs)
  args <- mapM genExpr (map snd i)
  let asm = IA.InlineAssembly
        (toLLVMType t)
        (BS.pack e)
        (ntobs (TP.Name constrs))
        True  -- hasSideEffects
        False -- alignStack
        IA.ATTDialect
  let instr = AST.Call {
    AST.tailCallKind = Nothing
  , AST.callingConvention = CC.C
  , AST.returnAttributes = []
  , AST.function = Left asm
  , AST.arguments = zip args (repeat [])
  , AST.functionAttributes = []
  , AST.metadata = []
  }
  mkCall <- emitInstr (toLLVMType t) instr
  let (TA.Var name _ _ _) = (snd . head) o
  var' <- (lift . lift . getvar . tn2n) name
  let op' = bopToLLVMBop t t TP.Assign
  void $ op' var' mkCall

mkCLContext :: TP.Name -> LLVMGen ()
mkCLContext = undefined

mkCLInputs :: [CLA.CLParam] -> LLVMGen ()
mkCLInputs = undefined

callKernel :: TP.Name -> LLVMGen ()
callKernel = undefined

mkCLOutputs :: [TP.Name] -> LLVMGen ()
mkCLOutputs = undefined