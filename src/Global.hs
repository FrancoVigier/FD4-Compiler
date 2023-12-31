{-|
Module      : Global
Description : Define el estado global del compilador
Copyright   : (c) Mauro Jaskelioff, Guido Martínez, 2020.
License     : GPL-3
Maintainer  : mauro@fceia.unr.edu.ar
Stability   : experimental

-}
module Global where

import Lang

data GlEnv = GlEnv {
  inter :: Bool,        --  ^ True, si estamos en modo interactivo.
                        -- Este parámetro puede cambiar durante la ejecución:
                        -- Es falso mientras se cargan archivos, pero luego puede ser verdadero.
  lfile :: String,      -- ^ Último archivo cargado.
  cantDecl :: Int,      -- ^ Cantidad de declaraciones desde la última carga
  glb :: [Decl TTerm]  -- ^ Entorno con declaraciones globales
}

-- ^ Entorno de tipado de declaraciones globales
tyEnv :: GlEnv ->  [(Name,Ty)]
tyEnv g =
  let
    f (Decl _ _ _ _) = True
    f (DeclType _ _ _) = False
  in (map (\(Decl _ n ty _) -> (n, ty))) $ (filter f) $ (glb g)

-- ^ Entorno de tipado de declaraciones globales
tyTypeEnv :: GlEnv ->  [(Name,Ty)]
tyTypeEnv g =
  let
    f (Decl _ _ _ _) = False
    f (DeclType _ _ _) = True
  in (map (\(DeclType _ n ty) -> (n, ty))) $ (filter f) $ (glb g)

{-
 Tipo para representar las banderas disponibles en línea de comando.
-}
data Mode =
    Interactive
  | Typecheck
  | Eval
  | InteractiveCEK
  | Bytecompile
  | RunVM
  | CC
  -- | Canon
  -- | Assembler
  -- | Build
data Conf = Conf {
    opt :: Bool,          --  ^ True, si estan habilitadas las optimizaciones.
    cek :: Bool,          --  ^ True, si se ejecuta en el CEK.
    noColor :: Bool,      --  ^ True, si se imprime el texto sin enriquecer
    modo :: Mode
}

-- | Valor del estado inicial
initialEnv :: GlEnv
initialEnv = GlEnv False "" 0 []
