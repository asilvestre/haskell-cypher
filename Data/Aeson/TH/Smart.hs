{-# LANGUAGE CPP, NoImplicitPrelude, TemplateHaskell, OverloadedStrings #-}
-- Shamelessly copied from Bryan O'Sullivan, 2011

-- null parameters should be excluded
-- enumerations are just strings
-- constructors are not objectified
-- parsing of maybe parameters should use a Nothing if they're not found


module Data.Aeson.TH.Smart
    ( deriveJSON

    , deriveToJSON
    , deriveFromJSON

    , mkToJSON
    , mkParseJSON
    ) where

--------------------------------------------------------------------------------
-- Imports
--------------------------------------------------------------------------------

-- from aeson:
import Data.Aeson ( toJSON, Object, object, (.=)
                  , ToJSON, toJSON
                  , FromJSON, parseJSON
                  )
import Data.Aeson.Types ( Value(..), Parser )
-- from base:
import Control.Applicative ( pure, (<$>), (<*>) )
import Control.Monad       ( return, mapM, liftM2, fail )
import Data.Bool           ( otherwise )
import Data.Eq             ( (==) )
import Data.Function       ( ($), (.), id )
import Data.Functor        ( fmap )
import Data.List           ( (++), foldl, foldl', intercalate
                           , length, map, zip, genericLength
                           )
import Data.Maybe          ( Maybe(Nothing, Just) )
import Prelude             ( String, (-), Integer, fromIntegral, not, error, filter, fst, snd)
import Text.Printf         ( printf )
import Text.Show           ( show )
#if __GLASGOW_HASKELL__ < 700
import Control.Monad       ( (>>=) )
import Prelude             ( fromInteger )
#endif
-- from unordered-containers:
import qualified Data.HashMap.Strict as H ( lookup, toList, size )
-- from template-haskell:
import Language.Haskell.TH
-- from text:
import qualified Data.Text as T ( Text, pack, unpack )
-- from vector:
import qualified Data.Vector as V ( unsafeIndex, null, length, create, filter)
import qualified Data.Vector.Mutable as VM ( unsafeNew, unsafeWrite )


--------------------------------------------------------------------------------
-- Convenience
--------------------------------------------------------------------------------

-- | Generates both 'ToJSON' and 'FromJSON' instance declarations for the given
-- data type.
--
-- This is a convienience function which is equivalent to calling both
-- 'deriveToJSON' and 'deriveFromJSON'.
deriveJSON :: (String -> String)
           -- ^ Function to change field names.
           -> Name
           -- ^ Name of the type for which to generate 'ToJSON' and 'FromJSON'
           -- instances.
           -> Q [Dec]
deriveJSON withField name =
    liftM2 (++)
           (deriveToJSON   withField name)
           (deriveFromJSON withField name)


--------------------------------------------------------------------------------
-- ToJSON
--------------------------------------------------------------------------------

{-
TODO: Don't constrain phantom type variables.

data Foo a = Foo Int
instance (ToJSON a) ⇒ ToJSON Foo where ...

The above (ToJSON a) constraint is not necessary and perhaps undesirable.
-}

-- | Generates a 'ToJSON' instance declaration for the given data type.
--
-- Example:
--
-- @
-- data Foo = Foo 'Char' 'Int'
-- $('deriveToJSON' 'id' ''Foo)
-- @
--
-- This will splice in the following code:
--
-- @
-- instance 'ToJSON' Foo where
--      'toJSON' =
--          \value -> case value of
--                      Foo arg1 arg2 -> 'Array' $ 'V.create' $ do
--                        mv <- 'VM.unsafeNew' 2
--                        'VM.unsafeWrite' mv 0 ('toJSON' arg1)
--                        'VM.unsafeWrite' mv 1 ('toJSON' arg2)
--                        return mv
-- @
deriveToJSON :: (String -> String)
             -- ^ Function to change field names.
             -> Name
             -- ^ Name of the type for which to generate a 'ToJSON' instance
             -- declaration.
             -> Q [Dec]
deriveToJSON withField name =
    withType name $ \tvbs cons -> fmap (:[]) $ fromCons tvbs cons
  where
    fromCons :: [TyVarBndr] -> [Con] -> Q Dec
    fromCons tvbs cons =
        instanceD (return $ map (\t -> ClassP ''ToJSON [VarT t]) typeNames)
                  (classType `appT` instanceType)
                  [ funD 'toJSON
                         [ clause []
                                  (normalB $ consToJSON withField cons)
                                  []
                         ]
                  ]
      where
        classType = conT ''ToJSON
        typeNames = map tvbName tvbs
        instanceType = foldl' appT (conT name) $ map varT typeNames

-- | Generates a lambda expression which encodes the given data type as JSON.
--
-- Example:
--
-- @
-- data Foo = Foo Int
-- @
--
-- @
-- encodeFoo :: Foo -> 'Value'
-- encodeFoo = $('mkToJSON' id ''Foo)
-- @
--
-- This will splice in the following code:
--
-- @
-- \value -> case value of Foo arg1 -> 'toJSON' arg1
-- @
mkToJSON :: (String -> String) -- ^ Function to change field names.
         -> Name -- ^ Name of the type to encode.
         -> Q Exp
mkToJSON withField name = withType name (\_ cons -> consToJSON withField cons)

-- | Helper function used by both 'deriveToJSON' and 'mkToJSON'. Generates code
-- to generate the JSON encoding of a number of constructors. All constructors
-- must be from the same type.
consToJSON :: (String -> String)
           -- ^ Function to change field names.
           -> [Con]
           -- ^ Constructors for which to generate JSON generating code.
           -> Q Exp
consToJSON _ [] = error $ "Data.Aeson.TH.consToJSON: "
                          ++ "Not a single constructor given!"
-- A single constructor is directly encoded. The constructor itself may be
-- forgotten.
consToJSON withField [con] = do
    value <- newName "value"
    lam1E (varP value)
          $ caseE (varE value)
                  [encodeArgs Nothing withField con]

consToJSON withField cons = do
	    value <- newName "value"
	    lam1E (varP value)
	          $ caseE (varE value)
	                  [ encodeArgs (Just $ wrap $ [|String . T.pack|] `appE` conNameExp con) withField con
	                  | con <- cons
	                  ]
  where
    wrap :: Q Exp -> [Q Exp] -> Q Exp
    wrap name exps =
        [e|object|] `appE` ([e| filter (not .(==Null) . snd )|] `appE`
            listE (infixApp (litE $ stringL "constructor") [e|(.=)|] name : exps))

-- | Generates code to generate the JSON encoding of a single constructor.
encodeArgs :: Maybe ([Q Exp] -> Q Exp) -> (String -> String) -> Con -> Q Match
encodeArgs _ _ c@(NormalC conName []) =
    match (conP conName []) (normalB $ [e|toJSON|] `appE` ([|T.pack|] `appE` conNameExp c)) []
encodeArgs wrapper _ (NormalC conName ts) = do
    let len = length ts
    args <- mapM newName ["arg" ++ show n | n <- [1..len]]
    let js = case [[e|toJSON|] `appE` varE arg | arg <- args] of
              -- Single argument is directly converted.
              [e] -> e
              -- Multiple arguments are converted to a JSON array.
              es  -> do
                 mv <- newName "mv"
                 let newMV = bindS (varP mv)
                                  ([e|VM.unsafeNew|] `appE`
                                    litE (integerL $ fromIntegral len))
                     stmts = [noBindS $
                                [e|VM.unsafeWrite|] `appE`
                                  (varE mv) `appE`
                                    litE (integerL ix) `appE` e | (ix, e) <- zip [(0::Integer)..] es]
                     ret = noBindS $ [e|return|] `appE` varE mv
                     fltr = [e| V.filter (not . (== Null))|]
                 [e|Array|] `appE` (fltr `appE` (varE 'V.create `appE` doE (newMV:stmts++[ret])))
    let b = case wrapper of
              Nothing -> js
              (Just wrapper') -> wrapper' [infixApp (litE (stringL "value")) [e|(.=)|] js]
    match (conP conName $ map varP args) (normalB b) []
-- Records.
encodeArgs withExp withField (RecC conName ts) = do
    args <- mapM newName ["arg" ++ show n | (_, n) <- zip ts [1 :: Integer ..]]
    let args' = map (([e|toJSON|] `appE`) . varE) args
    let js = [ infixApp ([e|T.pack|] `appE` fieldNameExp withField field) [e|(.=)|] arg
             | (arg, (field, _, _)) <- zip args' ts
             ]
    let b = case withExp of
              Nothing -> [e|object|] `appE` ([e| filter (not . (==Null) . snd) |] `appE` listE js)
              (Just wrapper) -> wrapper js
    match (conP conName $ map varP args) (normalB b) []
-- Infix constructors.
encodeArgs withExp _ (InfixC _ conName _) = do
    al <- newName "argL"
    ar <- newName "argR"
    let l = listE [[e|toJSON|] `appE` varE a | a <- [al,ar]]
    let b = case withExp of
              Nothing -> [e|toJSON|] `appE` l
              (Just wrapper) -> wrapper [infixApp (litE $ stringL "value") [e|(.=)|] l]
    match (infixP (varP al) conName (varP ar)) (normalB b) []
-- Existentially quantified constructors.
encodeArgs withExp withField (ForallC _ _ con) =
    encodeArgs withExp withField con


--------------------------------------------------------------------------------
-- FromJSON
--------------------------------------------------------------------------------

-- | Generates a 'FromJSON' instance declaration for the given data type.
--
-- Example:
--
-- @
-- data Foo = Foo Char Int
-- $('deriveFromJSON' id ''Foo)
-- @
--
-- This will splice in the following code:
--
-- @
-- instance 'FromJSON' Foo where
--     'parseJSON' =
--         \value -> case value of
--                     'Array' arr ->
--                       if (V.length arr == 2)
--                       then Foo \<$\> 'parseJSON' (arr `V.unsafeIndex` 0)
--                                \<*\> 'parseJSON' (arr `V.unsafeIndex` 1)
--                       else fail \"\<error message\>\"
--                     other -> fail \"\<error message\>\"
-- @
deriveFromJSON :: (String -> String)
               -- ^ Function to change field names.
               -> Name
               -- ^ Name of the type for which to generate a 'FromJSON' instance
               -- declaration.
               -> Q [Dec]
deriveFromJSON withField name =
    withType name $ \tvbs cons -> fmap (:[]) $ fromCons tvbs cons
  where
    fromCons :: [TyVarBndr] -> [Con] -> Q Dec
    fromCons tvbs cons =
        instanceD (return $ map (\t -> ClassP ''FromJSON [VarT t]) typeNames)
                  (classType `appT` instanceType)
                  [ funD 'parseJSON
                         [ clause []
                                  (normalB $ consFromJSON name withField cons)
                                  []
                         ]
                  ]
      where
        classType = conT ''FromJSON
        typeNames = map tvbName tvbs
        instanceType = foldl' appT (conT name) $ map varT typeNames

-- | Generates a lambda expression which parses the JSON encoding of the given
-- data type.
--
-- Example:
--
-- @
-- data Foo = Foo 'Int'
-- @
--
-- @
-- parseFoo :: 'Value' -> 'Parser' Foo
-- parseFoo = $('mkParseJSON' id ''Foo)
-- @
--
-- This will splice in the following code:
--
-- @
-- \\value -> case value of arg -> Foo \<$\> 'parseJSON' arg
-- @
mkParseJSON :: (String -> String) -- ^ Function to change field names.
            -> Name -- ^ Name of the encoded type.
            -> Q Exp
mkParseJSON withField name =
    withType name (\_ cons -> consFromJSON name withField cons)

-- | Helper function used by both 'deriveFromJSON' and 'mkParseJSON'. Generates
-- code to parse the JSON encoding of a number of constructors. All constructors
-- must be from the same type.
consFromJSON :: Name
             -- ^ Name of the type to which the constructors belong.
             -> (String -> String)
             -- ^ Function to change field names.
             -> [Con]
             -- ^ Constructors for which to generate JSON parsing code.
             -> Q Exp
consFromJSON _ _ [] = error $ "Data.Aeson.TH.consFromJSON: "
                              ++ "Not a single constructor given!"
consFromJSON tName withField [con] = do
  value <- newName "value"
  lam1E (varP value)
        $ caseE (varE value)
                (parseArgs tName withField con)
consFromJSON tName withField cons = do
  value  <- newName "value"
  obj    <- newName "obj"
  conKey <- newName "conKey"
  conVal <- newName "conVal"

  let -- Convert the Data.Map inside the Object to a list and pattern match
      -- against it. It must contain a single element otherwise the parse will
      -- fail.
      caseLst = caseE ([e|H.toList|] `appE` varE obj)
                      [ match (listP [tupP [varP conKey, varP conVal]])
                              (normalB caseKey)
                              []
                      , do other <- newName "other"
                           match (varP other)
                                 (normalB $ [|wrongPairCountFail|]
                                            `appE` (litE $ stringL $ show tName)
                                            `appE` ([|show . length|] `appE` varE other)
                                 )
                                 []
                      ]

      caseKey = caseE (varE conKey)
                      [match wildP (guardedB guards) []]
      guards = [ do g <- normalG $ infixApp (varE conKey)
                                            [|(==)|]
                                            ( [|T.pack|]
                                              `appE` conNameExp con
                                            )
                    e <- caseE (varE conVal)
                               (parseArgs tName withField con)
                    return (g, e)
               | con <- cons
               ]
               ++
               [ liftM2 (,)
                        (normalG [e|otherwise|])
                        ( [|conNotFoundFail|]
                          `appE` (litE $ stringL $ show tName)
                          `appE` listE (map (litE . stringL . nameBase . getConName) cons)
                          `appE` ([|T.unpack|] `appE` varE conKey)
                        )
               ]

  lam1E (varP value)
        $ caseE (varE value)
                [ match (conP 'Object [varP obj])
                        (normalB caseLst)
                        []
                , do other <- newName "other"
                     match (varP other)
                           ( normalB
                           $ [|noObjectFail|]
                             `appE` (litE $ stringL $ show tName)
                             `appE` ([|valueConName|] `appE` varE other)
                           )
                           []
                ]

-- | Generates code to parse the JSON encoding of a single constructor.
parseArgs :: Name -- ^ Name of the type to which the constructor belongs.
          -> (String -> String) -- ^ Function to change field names.
          -> Con -- ^ Constructor for which to generate JSON parsing code.
          -> [Q Match]
-- Nullary constructors.
parseArgs tName _ (NormalC conName []) =
    [ do arr <- newName "arr"
         match (conP 'Array [varP arr])
               ( normalB $ condE ([|V.null|] `appE` varE arr)
                                 ([e|pure|] `appE` conE conName)
                                 ( parseTypeMismatch tName conName
                                     (litE $ stringL "an empty Array")
                                     ( infixApp (litE $ stringL $ "Array of length ")
                                                [|(++)|]
                                                ([|show . V.length|] `appE` varE arr)
                                     )
                                 )
               )
               []
    , matchFailed tName conName "Array"
    ]
-- Unary constructors.
parseArgs _ _ (NormalC conName [_]) =
    [ do arg <- newName "arg"
         match (varP arg)
               ( normalB $ infixApp (conE conName)
                                    [e|(<$>)|]
                                    ([e|parseJSON|] `appE` varE arg)
               )
               []
    ]
-- Polyadic constructors.
parseArgs tName _ (NormalC conName ts) = parseProduct tName conName $ genericLength ts
-- Records.
parseArgs tName withField (RecC conName ts) =
    [ do obj <- newName "recObj"
         let x:xs = [ [|lookupField|]
                      `appE` (litE $ stringL $ show tName)
                      `appE` (litE $ stringL $ nameBase conName)
                      `appE` (varE obj)
                      `appE` ( [e|T.pack|]
                               `appE`
                               fieldNameExp withField field
                             )
                    | (field, _, _) <- ts
                    ]
         match (conP 'Object [varP obj])
               ( normalB $ condE ( infixApp ([|H.size|] `appE` varE obj)
                                            [|(==)|]
                                            (litE $ integerL $ genericLength ts)
                                 )
                                 ( foldl' (\a b -> infixApp a [|(<*>)|] b)
                                          (infixApp (conE conName) [|(<$>)|] x)
                                          xs
                                 )
                                 ( parseTypeMismatch tName conName
                                     ( litE $ stringL $ "Object with "
                                                        ++ show (length ts)
                                                        ++ " name/value pairs"
                                     )
                                     ( infixApp ([|show . H.size|] `appE` varE obj)
                                                [|(++)|]
                                                (litE $ stringL $ " name/value pairs")
                                     )
                                 )
               )
               []
    , matchFailed tName conName "Object"
    ]
-- Infix constructors. Apart from syntax these are the same as
-- polyadic constructors.
parseArgs tName _ (InfixC _ conName _) = parseProduct tName conName 2
-- Existentially quantified constructors. We ignore the quantifiers
-- and proceed with the contained constructor.
parseArgs tName withField (ForallC _ _ con) = parseArgs tName withField con

-- | Generates code to parse the JSON encoding of an n-ary
-- constructor.
parseProduct :: Name -- ^ Name of the type to which the constructor belongs.
             -> Name -- ^ 'Con'structor name.
             -> Integer -- ^ 'Con'structor arity.
             -> [Q Match]
parseProduct tName conName numArgs =
    [ do arr <- newName "arr"
         -- List of: "parseJSON (arr `V.unsafeIndex` <IX>)"
         let x:xs = [ [|parseJSON|]
                      `appE`
                      infixApp (varE arr)
                               [|V.unsafeIndex|]
                               (litE $ integerL ix)
                    | ix <- [0 .. numArgs - 1]
                    ]
         match (conP 'Array [varP arr])
               (normalB $ condE ( infixApp ([|V.length|] `appE` varE arr)
                                           [|(==)|]
                                           (litE $ integerL numArgs)
                                )
                                ( foldl' (\a b -> infixApp a [|(<*>)|] b)
                                         (infixApp (conE conName) [|(<$>)|] x)
                                         xs
                                )
                                ( parseTypeMismatch tName conName
                                    (litE $ stringL $ "Array of length " ++ show numArgs)
                                    ( infixApp (litE $ stringL $ "Array of length ")
                                               [|(++)|]
                                               ([|show . V.length|] `appE` varE arr)
                                    )
                                )
               )
               []
    , matchFailed tName conName "Array"
    ]


--------------------------------------------------------------------------------
-- Parsing errors
--------------------------------------------------------------------------------

matchFailed :: Name -> Name -> String -> MatchQ
matchFailed tName conName expected = do
  other <- newName "other"
  match (varP other)
        ( normalB $ parseTypeMismatch tName conName
                      (litE $ stringL expected)
                      ([|valueConName|] `appE` varE other)
        )
        []

parseTypeMismatch :: Name -> Name -> ExpQ -> ExpQ -> ExpQ
parseTypeMismatch tName conName expected actual =
    foldl appE
          [|parseTypeMismatch'|]
          [ litE $ stringL $ nameBase conName
          , litE $ stringL $ show tName
          , expected
          , actual
          ]

lookupField :: (FromJSON a) => String -> String -> Object -> T.Text -> Parser a
lookupField tName rec obj key =
    case H.lookup key obj of
      Nothing -> unknownFieldFail tName rec (T.unpack key)
      Just v  -> parseJSON v

unknownFieldFail :: String -> String -> String -> Parser fail
unknownFieldFail tName rec key =
    fail $ printf "When parsing the record %s of type %s the key %s was not present."
                  rec tName key

noObjectFail :: String -> String -> Parser fail
noObjectFail t o =
    fail $ printf "When parsing %s expected Object but got %s." t o

wrongPairCountFail :: String -> String -> Parser fail
wrongPairCountFail t n =
    fail $ printf "When parsing %s expected an Object with a single name/value pair but got %s pairs."
                  t n

conNotFoundFail :: String -> [String] -> String -> Parser fail
conNotFoundFail t cs o =
    fail $ printf "When parsing %s expected an Object with a name/value pair where the name is one of [%s], but got %s."
                  t (intercalate ", " cs) o

parseTypeMismatch' :: String -> String -> String -> String -> Parser fail
parseTypeMismatch' tName conName expected actual =
    fail $ printf "When parsing the constructor %s of type %s expected %s but got %s."
                  conName tName expected actual


--------------------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------------------

-- | Boilerplate for top level splices.
--
-- The given 'Name' must be from a type constructor. Furthermore, the
-- type constructor must be either a data type or a newtype. Any other
-- value will result in an exception.
withType :: Name
         -> ([TyVarBndr] -> [Con] -> Q a)
         -- ^ Function that generates the actual code. Will be applied
         -- to the type variable binders and constructors extracted
         -- from the given 'Name'.
         -> Q a
         -- ^ Resulting value in the 'Q'uasi monad.
withType name f = do
    info <- reify name
    case info of
      TyConI dec ->
        case dec of
          DataD    _ _ tvbs cons _ -> f tvbs cons
          NewtypeD _ _ tvbs con  _ -> f tvbs [con]
          other -> error $ "Data.Aeson.TH.withType: Unsupported type: "
                          ++ show other
      _ -> error "Data.Aeson.TH.withType: I need the name of a type."

-- | Extracts the name from a constructor.
getConName :: Con -> Name
getConName (NormalC name _)  = name
getConName (RecC name _)     = name
getConName (InfixC _ name _) = name
getConName (ForallC _ _ con) = getConName con

-- | Extracts the name from a type variable binder.
tvbName :: TyVarBndr -> Name
tvbName (PlainTV  name  ) = name
tvbName (KindedTV name _) = name

-- | Makes a string literal expression from a constructor's name.
conNameExp :: Con -> Q Exp
conNameExp = litE . stringL . nameBase . getConName

-- | Creates a string literal expression from a record field name.
fieldNameExp :: (String -> String) -- ^ Function to change the field name.
             -> Name
             -> Q Exp
fieldNameExp f = litE . stringL . f . nameBase

-- | The name of the outermost 'Value' constructor.
valueConName :: Value -> String
valueConName (Object _) = "Object"
valueConName (Array  _) = "Array"
valueConName (String _) = "String"
valueConName (Number _) = "Number"
valueConName (Bool   _) = "Boolean"
valueConName Null       = "Null"