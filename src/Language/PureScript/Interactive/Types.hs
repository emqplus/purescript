-- |
-- Type declarations and associated basic functions for PSCI.
--
module Language.PureScript.Interactive.Types
  ( PSCiConfig(..)
  , psciEnvironment
  , PSCiState -- constructor is not exported, to prevent psciImports and psciExports from
              -- becoming inconsistent with importedModules, letBindings and loadedExterns
  , ImportedModule
  , psciExports
  , psciImports
  , psciLoadedExterns
  , psciInteractivePrint
  , psciImportedModules
  , psciLetBindings
  , initialPSCiState
  , initialInteractivePrint
  , psciImportedModuleNames
  , updateImportedModules
  , updateLoadedExterns
  , updateLets
  , setInteractivePrint
  , Command(..)
  , ReplQuery(..)
  , replQueries
  , replQueryStrings
  , showReplQuery
  , parseReplQuery
  , getVal
  , setVal
  , Directive(..)
  ) where

import Prelude.Compat

import qualified Language.PureScript as P
import qualified Data.Map as M
import           Data.List (foldl')
import           Language.PureScript.Sugar.Names.Env (nullImports, primExports)
import           Control.Monad (foldM)
import           Control.Monad.Trans.Except (runExceptT)
import           Control.Monad.Writer.Strict (runWriterT)


-- | The PSCI configuration.
--
-- These configuration values do not change during execution.
--
data PSCiConfig = PSCiConfig
  { psciFileGlobs :: [(P.ModuleName, (String, Bool))]
  , moduleDirs :: FilePath
  } deriving Show

-- | The PSCI state.
--
-- Holds a list of imported modules, loaded files, and partial let bindings,
-- plus the currently configured interactive printing function.
--
-- The let bindings are partial, because it makes more sense to apply the
-- binding to the final evaluated expression.
--
-- The last two fields are derived from the first three via updateImportExports
-- each time a module is imported, a let binding is added, or the session is
-- cleared or reloaded
data PSCiState = PSCiState
  [ImportedModule]
  [P.Declaration]
  [(P.Module, P.ExternsFile)]
  (P.ModuleName, P.Ident)
  P.Imports
  P.Exports
  String
  deriving Show

psciImportedModules :: PSCiState -> [ImportedModule]
psciImportedModules (PSCiState x _ _ _ _ _ _) = x

psciLetBindings :: PSCiState -> [P.Declaration]
psciLetBindings (PSCiState _ x _ _ _ _ _) = x

psciLoadedExterns :: PSCiState -> [(P.Module, P.ExternsFile)]
psciLoadedExterns (PSCiState _ _ x _ _ _ _) = x

psciInteractivePrint :: PSCiState -> (P.ModuleName, P.Ident)
psciInteractivePrint (PSCiState _ _ _ x _ _ _) = x

psciImports :: PSCiState -> P.Imports
psciImports (PSCiState _ _ _ _ x _ _) = x

psciExports :: PSCiState -> P.Exports
psciExports (PSCiState _ _ _ _ _ x _) = x

initialPSCiState :: PSCiState
initialPSCiState = PSCiState [preludeModule] [] [] initialInteractivePrint nullImports primExports "> "

preludeModule :: ImportedModule
preludeModule = (P.ModuleName [P.ProperName "Prelude"], P.Implicit, Nothing)

-- | The default interactive print function.
initialInteractivePrint :: (P.ModuleName, P.Ident)
initialInteractivePrint = (P.moduleNameFromString "PSCI.Support", P.Ident "eval")

psciEnvironment :: PSCiState -> P.Environment
psciEnvironment st = foldl' (flip P.applyExternsFileToEnvironment) P.initEnvironment externs
  where externs = map snd (psciLoadedExterns st)

-- | All of the data that is contained by an ImportDeclaration in the AST.
-- That is:
--
-- * A module name, the name of the module which is being imported
-- * An ImportDeclarationType which specifies whether there is an explicit
--   import list, a hiding list, or neither.
-- * If the module is imported qualified, its qualified name in the importing
--   module. Otherwise, Nothing.
--
type ImportedModule = (P.ModuleName, P.ImportDeclarationType, Maybe P.ModuleName)

psciImportedModuleNames :: PSCiState -> [P.ModuleName]
psciImportedModuleNames st =
  map (\(mn, _, _) -> mn) (psciImportedModules st)

-- * State helpers

-- This function updates the Imports and Exports values in the PSCiState, which are used for
-- handling completions. This function must be called whenever the PSCiState is modified to
-- ensure that completions remain accurate.
updateImportExports :: PSCiState -> PSCiState
updateImportExports st@(PSCiState modules lets externs iprint _ _ v) =
  case createEnv (map snd externs) >>= flip desugarModule [temporaryModule] of
    Left _          -> st -- TODO: can this fail and what should we do?
    Right (env, _)  ->
      case M.lookup temporaryName env of
        Just (_, is, es)  -> PSCiState modules lets externs iprint is es v
        _                 -> st -- impossible
  where

  desugarModule :: P.Env -> [P.Module] -> Either P.MultipleErrors (P.Env, [P.Module])
  desugarModule e = runExceptT =<< fmap fst . runWriterT . P.desugarImportsWithEnv e

  createEnv :: [P.ExternsFile] -> Either P.MultipleErrors P.Env
  createEnv = runExceptT =<< fmap fst . runWriterT . foldM P.externsEnv P.primEnv

  temporaryName :: P.ModuleName
  temporaryName = P.ModuleName [P.ProperName "$PSCI"]

  temporaryModule :: P.Module
  temporaryModule =
    let
      prim = (P.ModuleName [P.ProperName "Prim"], P.Implicit, Nothing)
      decl = (importDecl `map` (prim : modules)) ++ lets
    in
      P.Module internalSpan [] temporaryName decl Nothing

  importDecl :: ImportedModule -> P.Declaration
  importDecl (mn, declType, asQ) = P.ImportDeclaration (internalSpan, []) mn declType asQ

  internalSpan :: P.SourceSpan
  internalSpan = P.internalModuleSourceSpan "<internal>"

-- | Updates the imported modules in the state record.
updateImportedModules :: ([ImportedModule] -> [ImportedModule]) -> PSCiState -> PSCiState
updateImportedModules f (PSCiState x a b c d e v) =
  updateImportExports (PSCiState (f x) a b c d e v)

-- | Updates the loaded externs files in the state record.
updateLoadedExterns :: ([(P.Module, P.ExternsFile)] -> [(P.Module, P.ExternsFile)]) -> PSCiState -> PSCiState
updateLoadedExterns f (PSCiState a b x c d e v) =
  updateImportExports (PSCiState a b (f x) c d e v)

-- | Updates the let bindings in the state record.
updateLets :: ([P.Declaration] -> [P.Declaration]) -> PSCiState -> PSCiState
updateLets f (PSCiState a x b c d e v) =
  updateImportExports (PSCiState a (f x) b c d e v)

-- | Replaces the interactive printing function in the state record with a new
-- one.
setInteractivePrint :: (P.ModuleName, P.Ident) -> PSCiState -> PSCiState
setInteractivePrint iprint (PSCiState a b c _ d e v) =
  PSCiState a b c iprint d e v


setVal :: (String, String) -> PSCiState -> PSCiState
setVal (_,s2) (PSCiState a b c k d e _) =
  PSCiState a b c k d e s2

getVal :: PSCiState -> String
getVal (PSCiState _ _ _ _ _ _ v) = v 

-- * Commands

-- |
-- Valid Meta-commands for PSCI
--
data Command
  -- | A purescript expression
  = Expression P.Expr
  -- | Show the help (ie, list of directives)
  | ShowHelp
  -- | Import a module from a loaded file
  | Import ImportedModule
  -- | Browse a module
  | BrowseModule P.ModuleName
  -- | Exit PSCI
  | QuitPSCi
  -- | Reload all the imported modules of the REPL
  | ReloadState
  -- | Clear the state of the REPL
  | ClearState
  -- | Add some declarations to the current evaluation context
  | Decls [P.Declaration]
  -- | Find the type of an expression
  | TypeOf P.Expr
  -- | Find the kind of an expression
  | KindOf P.SourceType
  -- | Shows information about the current state of the REPL
  | ShowInfo ReplQuery
  -- | Paste multiple lines
  | PasteLines
  -- | Return auto-completion output as if pressing <tab>
  | CompleteStr String
  -- | Set the interactive printing function
  | SetInteractivePrint (P.ModuleName, P.Ident)
  | Setval String String
  deriving Show

data ReplQuery
  = QueryLoaded
  | QueryImport
  | QueryPrint
  deriving (Eq, Show)

-- | A list of all ReplQuery values.
replQueries :: [ReplQuery]
replQueries = [QueryLoaded, QueryImport, QueryPrint]

replQueryStrings :: [String]
replQueryStrings = map showReplQuery replQueries

showReplQuery :: ReplQuery -> String
showReplQuery QueryLoaded = "loaded"
showReplQuery QueryImport = "import"
showReplQuery QueryPrint = "print"

parseReplQuery :: String -> Maybe ReplQuery
parseReplQuery "loaded" = Just QueryLoaded
parseReplQuery "import" = Just QueryImport
parseReplQuery "print" = Just QueryPrint
parseReplQuery _ = Nothing

data Directive
  = Help
  | Quit
  | Reload
  | Clear
  | Browse
  | Type
  | Kind
  | Show
  | Paste
  | Complete
  | Print
  | Set
  deriving (Eq, Show)
