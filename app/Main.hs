{-# LANGUAGE RecordWildCards #-}

{-|
Module      : Main
Description : Compilador de FD4.
Copyright   : (c) Mauro Jaskelioff, Guido Martínez, 2020.
License     : GPL-3
Maintainer  : mauro@fceia.unr.edu.ar
Stability   : experimental

-}

module Main where

import System.Console.Haskeline ( defaultSettings, getInputLine, runInputT, InputT )
import System.Process ( callCommand )
import Control.Monad.Catch (MonadMask)

--import Control.Monad
import Control.Monad.Trans
import Data.List (nub, isPrefixOf, intercalate )
import Data.Char ( isSpace )
import Control.Exception ( catch , IOException )
import System.IO ( hPrint, stderr, hPutStrLn )
import Data.Maybe ( fromMaybe )

import System.Exit ( exitWith, ExitCode(ExitFailure) )
import Options.Applicative

import Global
import Errors
import Lang
import Optimize ( optimize )
import UnnameTypes
import Parse ( P, tm, program, declOrTm, runP )
import Elab ( elab, elabDecl )
import Eval ( eval )
import Bytecompile ( runBC, bcWrite, bcRead, bytecompileModule, showBC )
import PPrint ( pp , ppTy, ppDecl )
import MonadFD4
import TypeChecker ( tc, tcDecl )
import ClosureConvert ( compileC )

import CEK

prompt :: String
prompt = "FD4> "

-- | Parser de banderas
parseMode :: Parser (Mode,Bool,Bool,Bool)
parseMode = (,,,) <$>
      (flag' Typecheck         (long "typecheck" <> short 't' <> help "Chequear tipos e imprimir el término")
      <|> flag' InteractiveCEK (long "interactiveCEK" <> short 'k' <> help "Ejecutar interactivamente en la CEK")
      <|> flag' Bytecompile    (long "bytecompile" <> short 'm' <> help "Compilar a la BVM")
      <|> flag' RunVM          (long "runVM" <> short 'r' <> help "Ejecutar bytecode en la BVM")
      <|> flag' Interactive    (long "interactive" <> short 'i' <> help "Ejecutar en forma interactiva")
      <|> flag' Eval           (long "eval" <> short 'e' <> help "Evaluar programa")
      <|> flag' CC             ( long "cc" <> short 'c' <> help "Compilar a código C")
  -- <|> flag' Canon ( long "canon" <> short 'n' <> help "Imprimir canonicalización")
  -- <|> flag' Assembler ( long "assembler" <> short 'a' <> help "Imprimir Assembler resultante")
  -- <|> flag' Build ( long "build" <> short 'b' <> help "Compilar")
      )
       <*> flag False True (long "optimize" <> short 'o' <> help "Optimizar código")
       <*> flag False True (long "cek" <> help "Pasar por CEK") -- TODO hacer solo valida cuando se ejecuta con --eval
       <*> flag False True (long "noColor" <> help "Salida de texto es sin color") -- TODO hacer solo valida cuando se ejecuta con --typecheck

-- | Parser de opciones general, consiste de un modo y una lista de archivos a procesar
parseArgs :: Parser (Mode,Bool,Bool,Bool,[FilePath])
parseArgs = (\(a,b,c,d) e -> (a,b,c,d,e)) <$> parseMode <*> many (argument str (metavar "FILES..."))

main :: IO ()
main = execParser opts >>= go
  where
    opts = info (parseArgs <**> helper)
      ( fullDesc
     <> progDesc "Compilador de FD4"
     <> header "Compilador de FD4 de la materia Compiladores 2022" )

    go :: (Mode,Bool,Bool,Bool,[FilePath]) -> IO () --TODO refactor
    go (Interactive, opt, cek, noColor, files) =
              runOrFail (Conf opt cek noColor Interactive) (runInputT defaultSettings (repl files))
    go (InteractiveCEK, opt, cek, noColor, files) =
              runOrFail (Conf opt cek noColor InteractiveCEK) (runInputT defaultSettings (repl files))
    go (Bytecompile, opt, cek, noColor, files) =
              runOrFail (Conf opt cek noColor Bytecompile) (mapM_ compileBytecode files)
    go (RunVM, opt, cek, noColor, files) =
              runOrFail (Conf opt cek noColor RunVM) (mapM_ runBytecode files)
    go (CC, opt, cek, noColor, files) =
              runOrFail (Conf opt cek noColor CC) (mapM_ compileBytecode files)
    go (m,opt, cek, noColor, files) =
              runOrFail (Conf opt cek noColor m) (mapM_ compileFile files)

runOrFail :: Conf -> FD4 a -> IO a
runOrFail c m = do
  r <- runFD4 m c
  case r of
    Left err -> do
      liftIO $ hPrint stderr err
      exitWith (ExitFailure 1)
    Right v -> return v

compileBytecode :: MonadFD4 m => FilePath -> m ()
compileBytecode pathFd4 =
  do
    decls <- loadFile pathFd4

    let declsTypeElab = map elabDecl decls
    pureDeclsElab <- toPureDecls declsTypeElab

    mapM_ tcAndAdd (init pureDeclsElab)

    let t = toTerm pureDeclsElab
    let t' = elab t

    let lastDecl = last pureDeclsElab
    let newDecl = Decl (declPos lastDecl) (declName lastDecl) (declBodyType lastDecl) t'

    d' <- tcDecl newDecl

    opt <- getOpt
    d'' <- if opt then optimize d' else (return d')

    m <- getMode
    case m of
      Interactive -> undefined
      Typecheck -> undefined
      Eval -> undefined
      InteractiveCEK -> undefined
      RunVM -> undefined
      Bytecompile -> do
          bytecode <- bytecompileModule [d'']
          let pathBc = (take (length pathFd4 - 3)  pathFd4) ++ "bc32"
          liftIO $ bcWrite bytecode pathBc
          liftIO $ putStrLn $ showBC bytecode
      CC -> do
          let cFileName = (take (length pathFd4 - 3)  pathFd4) ++ "c"
          let objectFileName = take (length pathFd4 - 4) pathFd4
          let cCode = compileC d''
          liftIO $ writeFile cFileName $ cCode
          liftIO $ putStrLn $ cCode
          liftIO $ callCommand ("gcc -std=gnu11 -Wall -ggdb " ++ cFileName ++ " runtime.c " ++" -lgc -o "++objectFileName)
    return ()
  where
    tcAndAdd :: MonadFD4 m => Decl STerm -> m ()
    tcAndAdd d =
      case d of
        Decl _ _ _ _ ->
          do
            d' <- typecheckDecl d
            addDecl d'
        DeclType _ _ _ -> undefined -- toPureDecls ya lo elimina

runBytecode :: MonadFD4 m => FilePath -> m ()
runBytecode pathBc =
  do
    bytecode <- liftIO $ bcRead pathBc
    runBC bytecode

repl :: (MonadFD4 m, MonadMask m) => [FilePath] -> InputT m ()
repl args = do
       lift $ setInter True
       lift $ catchErrors $ mapM_ compileFile args
       s <- lift get
       when (inter s) $ liftIO $ putStrLn
         (  "Entorno interactivo para FD4.\n"
         ++ "Escriba :? para recibir ayuda.")
       loop
  where loop = do
           minput <- getInputLine prompt
           case minput of
               Nothing -> return ()
               Just "" -> loop
               Just x -> do
                       c <- liftIO $ interpretCommand x
                       b <- lift $ catchErrors $ handleCommand c
                       maybe loop (`when` loop) b

loadFile ::  MonadFD4 m => FilePath -> m [SDecl STerm]
loadFile f = do
    let filename = reverse(dropWhile isSpace (reverse f))
    x <- liftIO $ catch (readFile filename)
               (\e -> do let err = show (e :: IOException)
                         hPutStrLn stderr ("No se pudo abrir el archivo " ++ filename ++ ": " ++ err)
                         return "")
    setLastFile filename
    parseIO filename program x

compileFile ::  MonadFD4 m => FilePath -> m ()
compileFile f = do
    i <- getInter
    setInter False
    when i $ printFD4 ("Abriendo "++f++"...")
    decls <- loadFile f
    mapM_ handleDecl decls
    setInter i

parseIO ::  MonadFD4 m => String -> P a -> String -> m a
parseIO filename p x = case runP p x filename of
                  Left e  -> throwError (ParseErr e)
                  Right r -> return r

evalDecl :: MonadFD4 m => (TTerm -> m TTerm) -> Decl TTerm -> m (Decl TTerm)
evalDecl f (Decl p n ty e) =
  do
    e' <- f e
    return (Decl p n ty e')
evalDecl _ (DeclType p n ty) = return (DeclType p n ty)

handleDecl ::  MonadFD4 m => SDecl STerm -> m ()
handleDecl d = do
        m <- getMode
        case m of
          Interactive -> do
              noTypes <- (toPureDecl . elabDecl) d
              td <- typecheckDecl noTypes
              opt <- getOpt
              td' <- if opt then optimize td else (return td)
              (case td' of
                Decl p n ty b -> do { te <- eval b; addDecl (Decl p n ty te) }
                DeclType _ _ _ -> addDecl td')
          Typecheck -> do
              f <- getLastFile
              printFD4 ("Chequeando tipos de "++f)
              noTypes <- (toPureDecl . elabDecl) d
              td <- typecheckDecl noTypes
              addDecl td
              opt <- getOpt
              noColor <- getNoColor
              td' <- if opt then optimize td else (return td)
              ppterm <- ppDecl noColor td'
              printFD4 ppterm
              addDecl td'
          InteractiveCEK -> do
              noTypes <- (toPureDecl . elabDecl) d
              td <- typecheckDecl noTypes
              opt <- getOpt
              td' <- if opt then optimize td else (return td)
              (case td' of
                Decl p n ty b -> do { te <- evalCEK b; addDecl (Decl p n ty te) }
                DeclType _ _ _ -> addDecl td')
          Bytecompile -> undefined -- No lidia con decl
          RunVM -> undefined -- No se ejecuta aca
          CC -> undefined -- No se ejecuta aca
          Eval -> do
              cek <- getCek
              noTypes <- (toPureDecl . elabDecl) d
              td <- typecheckDecl noTypes
              opt <- getOpt
              td' <- if opt then optimize td else (return td)
              ed <- evalDecl (if not cek then eval else evalCEK) td'
              addDecl ed

typecheckDecl :: MonadFD4 m => Decl STerm -> m (Decl TTerm)
typecheckDecl = tcDecl . elabSTerm

elabSTerm :: Decl STerm -> Decl Term
elabSTerm (Decl p x ty t) = Decl p x ty (elab t)
elabSTerm (DeclType a b c) = DeclType a b c-- TODO fix

data Command = Compile CompileForm
             | PPrint String
             | Type String
             | Reload
             | Browse
             | Quit
             | Help
             | Noop

data CompileForm = CompileInteractive  String
                 | CompileFile         String

data InteractiveCommand = Cmd [String] String (String -> Command) String

-- | Parser simple de comando interactivos
interpretCommand :: String -> IO Command
interpretCommand x
  =  if ":" `isPrefixOf` x then
       do  let  (cmd,t')  =  break isSpace x
                t         =  dropWhile isSpace t'
           --  find matching commands
           let  matching  =  filter (\ (Cmd cs _ _ _) -> any (isPrefixOf cmd) cs) commands
           case matching of
             []  ->  do  putStrLn ("Comando desconocido `" ++ cmd ++ "'. Escriba :? para recibir ayuda.")
                         return Noop
             [Cmd _ _ f _]
                 ->  do  return (f t)
             _   ->  do  putStrLn ("Comando ambigüo, podría ser " ++
                                   intercalate ", " ([ head cs | Cmd cs _ _ _ <- matching ]) ++ ".")
                         return Noop

     else
       return (Compile (CompileInteractive x))

commands :: [InteractiveCommand]
commands
  =  [ Cmd [":browse"]      ""        (const Browse) "Ver los nombres en scope",
       Cmd [":load"]        "<file>"  (Compile . CompileFile)
                                                     "Cargar un programa desde un archivo",
       Cmd [":print"]       "<exp>"   PPrint          "Imprime un término y sus ASTs sin evaluarlo",
       Cmd [":reload"]      ""        (const Reload)         "Vuelve a cargar el último archivo cargado",
       Cmd [":type"]        "<exp>"   Type           "Chequea el tipo de una expresión",
       Cmd [":quit",":Q"]        ""        (const Quit)   "Salir del intérprete",
       Cmd [":help",":?"]   ""        (const Help)   "Mostrar esta lista de comandos" ]

helpTxt :: [InteractiveCommand] -> String
helpTxt cs
  =  "Lista de comandos:  Cualquier comando puede ser abreviado a :c donde\n" ++
     "c es el primer caracter del nombre completo.\n\n" ++
     "<expr>                  evaluar la expresión\n" ++
     "let <var> = <expr>      definir una variable\n" ++
     unlines (map (\ (Cmd c a _ d) ->
                   let  ct = intercalate ", " (map (++ if null a then "" else " " ++ a) c)
                   in   ct ++ replicate ((24 - length ct) `max` 2) ' ' ++ d) cs)

-- | 'handleCommand' interpreta un comando y devuelve un booleano
-- indicando si se debe salir del programa o no.
handleCommand ::  MonadFD4 m => Command  -> m Bool
handleCommand cmd = do
   s@GlEnv {..} <- get
   case cmd of
       Quit   ->  return False
       Noop   ->  return True
       Help   ->  printFD4 (helpTxt commands) >> return True
       Browse ->  do  printFD4 (unlines (reverse (nub (map declName glb))))
                      return True
       Compile c ->
                  do  case c of
                          CompileInteractive e -> compilePhrase e
                          CompileFile f        -> compileFile f
                      return True
       Reload ->  eraseLastFileDecls >> (getLastFile >>= compileFile) >> return True
       PPrint e   -> printPhrase e >> return True
       Type e    -> typeCheckPhrase e >> return True

compilePhrase ::  MonadFD4 m => String -> m ()
compilePhrase x = do
    dot <- parseIO "<interactive>" declOrTm x
    case dot of
      Left d  -> handleDecl d
      Right t ->
        do
          mode <- getMode
          case mode of
            Interactive -> handleTerm t eval
            InteractiveCEK -> handleTerm t evalCEK
            _ -> failFD4 "fail Interactive without MODE"

handleTerm ::  MonadFD4 m => STerm ->(TTerm -> m TTerm) -> m ()
handleTerm t f = do
         let t' = elab t
         s <- get
         tt <- tc t' (tyEnv s) (tyTypeEnv s)
         te <- f tt
         ppte <- pp te
         doc <- ppTy (getTy tt)
         printFD4 (ppte ++ " : " ++ doc)

printPhrase   :: MonadFD4 m => String -> m ()
printPhrase x =
  do
    x' <- parseIO "<interactive>" tm x
    let ex = elab x'
    tyenv <- gets tyEnv
    tytypeenv <- gets tyTypeEnv
    tex <- tc ex tyenv tytypeenv
    t  <- case x' of
           (SV p f) -> fromMaybe tex <$> lookupDecl f
           _       -> return tex
    printFD4 "STerm:"
    printFD4 (show x')
    printFD4 "TTerm:"
    printFD4 (show t)

typeCheckPhrase :: MonadFD4 m => String -> m ()
typeCheckPhrase x = do
         t <- parseIO "<interactive>" tm x
         let t' = elab t
         s <- get
         tt <- tc t' (tyEnv s) (tyTypeEnv s)
         let ty = getTy tt
         doc <- ppTy ty
         printFD4 doc
