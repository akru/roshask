{-# LANGUAGE OverloadedStrings, TupleSections #-}
module Ros.Core.Msg.Parse (parseMsg, simpleFieldAssoc) where
import Prelude hiding (takeWhile)
import Control.Applicative hiding (many)
import Control.Arrow ((***), (&&&))
import Data.Attoparsec.Char8
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack, unpack)
import qualified Data.ByteString.Char8 as B
import Data.Char (toLower, digitToInt)
import Data.Either (partitionEithers)
import Data.List (foldl')
import System.Environment (getEnvironment)
import System.FilePath (dropExtension, takeFileName, splitDirectories, (</>))
import System.Process (readProcess)
import Ros.Core.Msg.Types

simpleFieldTypes :: [MsgType]
simpleFieldTypes = [ RBool, RInt8, RUInt8, RInt16, RUInt16, RInt32, RUInt32, 
                     RInt64, RUInt64, RFloat32, RFloat64, RString, 
                     RTime, RDuration ]

simpleFieldAssoc :: [(MsgType, ByteString)]
simpleFieldAssoc = map (id &&& B.pack . map toLower . tail . show) 
                       simpleFieldTypes

eatLine :: Parser ()
eatLine = manyTill anyChar (eitherP endOfLine endOfInput) *> skipSpace

parseName :: Parser ByteString
parseName = skipSpace *> identifier <* eatLine <* try comment

identifier :: Parser ByteString
identifier = B.cons <$> letter_ascii <*> takeWhile validChar
    where validChar c = or (map ($ c) [isDigit, isAlpha_ascii, (== '_'), (== '/')])

parseInt :: Parser Int
parseInt = foldl' (\s x -> s*10 + digitToInt x) 0 <$> many1 digit

comment :: Parser [()]
comment = many $ skipSpace *> try (char '#' *> eatLine)

simpleParser :: (MsgType, ByteString) -> Parser (ByteString, MsgType)
simpleParser (t,b) = (, t) <$> (string b *> space *> parseName)

fixedArrayParser :: (MsgType, ByteString) -> Parser (ByteString, MsgType)
fixedArrayParser (t,b) = (\len name -> (name, RFixedArray len t)) <$>
                         (string b *> char '[' *> parseInt <* char ']') <*> 
                         (space *> parseName)

varArrayParser :: (MsgType, ByteString) -> Parser (ByteString, MsgType)
varArrayParser (t,b) = (, RVarArray t) <$> 
                       (string b *> string "[]" *> space *> parseName)

userTypeParser :: Parser (ByteString, MsgType)
userTypeParser = choice [userSimple, userVarArray, userFixedArray]

userSimple :: Parser (ByteString, MsgType)
userSimple = (\t name -> (name, RUserType t)) <$>
             identifier <*> (space *> parseName)

userVarArray :: Parser (ByteString, MsgType)
userVarArray = (\t name -> (name, RVarArray (RUserType t))) <$>
               identifier <*> (string "[]" *> space *> parseName)

userFixedArray :: Parser (ByteString, MsgType)
userFixedArray = (\t n name -> (name, RFixedArray n (RUserType t))) <$>
                 identifier <*> 
                 (char '[' *> parseInt <* char ']') <*> 
                 (space *> parseName)

-- Parsers for deprecated "byte" and "char" types. These have been
-- replaced by uint8 and int8, respectively.
deprecated :: [Parser (ByteString, MsgType)]
deprecated = map (comment *>) . concatMap (\x -> map ($ x) builders) $ 
             [("byte", RUInt8), ("char", RInt8)]
    where builders = map uncurry [depField, depFixedArray, depVarArray]

depField :: ByteString -> MsgType -> Parser (ByteString, MsgType)
depField s x = (, x) <$> (string s *> space *> parseName)

depFixedArray :: ByteString -> MsgType -> Parser (ByteString, MsgType)
depFixedArray s x = (\len name -> (name, RFixedArray len x)) <$>
                    (string s *> char '[' *> parseInt <* char ']') <*>
                    (space *> parseName)

depVarArray :: ByteString -> MsgType -> Parser (ByteString, MsgType)
depVarArray s x = (, RVarArray x) <$> 
                  (string s *> string "[]" *> space *> parseName)

-- Parse constants defined in the message
constParser :: ByteString -> MsgType -> Parser (ByteString, MsgType, ByteString)
constParser s x = (,x,) <$> 
                  (string s *> space *> identifier) <*> 
                  (skipSpace *> char '=' *> skipSpace *> restOfLine <* skipSpace)
    where restOfLine :: Parser ByteString
          restOfLine = pack <$> manyTill anyChar (eitherP endOfLine endOfInput)

constParsers :: [Parser (ByteString, MsgType, ByteString)]
constParsers = map (uncurry constParser) $
               [("byte", RUInt8), ("char", RInt8)] ++
               (map (\(x,y) -> (y,x)) simpleFieldAssoc)

-- String constants are parsed somewhat differently from numeric
-- constants. For numerical constants, we drop comments and trailing
-- spaces. For strings, we take the whole line (so comments aren't
-- stripped).
sanitizeConstants :: (a, MsgType, ByteString) -> (a, MsgType, ByteString)
sanitizeConstants (name, RString, val) = 
    (name, RString, B.concat ["\"",val,"\""])
sanitizeConstants (name, t, val) = 
    (name, t, B.takeWhile (\c -> c /= '#' && not (isSpace c)) val)

-- Parsers fields and constants.
fieldParsers :: [Parser (Either (ByteString, MsgType) 
                                (ByteString, MsgType, ByteString))]
fieldParsers = map (comment *>) $
               map (Right . sanitizeConstants <$>) constParsers ++ 
               map (Left <$>) (deprecated ++ builtIns ++ [userTypeParser])
    where builtIns = concatMap (flip map simpleFieldAssoc)
                               [simpleParser, fixedArrayParser, varArrayParser]

mkParser :: String -> String -> ByteString -> Parser Msg
mkParser sname lname txt = uncurry (Msg sname lname txt) . 
                           (map buildField *** map buildConst) .
                           partitionEithers <$> 
                           many (choice fieldParsers)

buildField :: (ByteString, MsgType) -> MsgField
buildField (name,typ) = MsgField (sanitize name) typ name

buildConst :: (ByteString, MsgType, ByteString) -> MsgConst
buildConst (name,typ,val) = MsgConst (sanitize name) typ val name

{-
testMsg :: ByteString
testMsg = "# Foo bar\n\n#   \nHeader header  # a header\nuint32 aNum # a number \n  # It's not important\ngeometry_msgs/PoseStamped[] poses\nbyte DEBUG=1 #debug level\n"

test :: Result Msg
test = feed (parse (mkParser "" "") testMsg) ""
-}

-- Ensure that field and constant names are valid Haskell identifiers
-- and do not coincide with Haskell reserved words.
sanitize :: ByteString -> ByteString
sanitize "data" = "_data"
sanitize "type" = "_type"
sanitize "class" = "_class"
sanitize "module" = "_module"
sanitize x = B.cons (toLower (B.head x)) (B.tail x)

genName :: FilePath -> String
genName f = let parts = splitDirectories f
                [pkg,_,msgFile] = drop (length parts - 3) parts
            in pkg ++ "/" ++ dropExtension msgFile

{-
addHash :: IO String -> Msg -> Msg
addHash hash msg = msg { md5sum = hash }

-- Use roslib/scripts/gendeps to compute the MD5 ROS uses to uniquely
-- identify versions of msg files.
genRosMD5 :: FilePath -> IO String
genRosMD5 fname = 
    do env <- getEnvironment
       let ros_root = case lookup "ROS_ROOT" env of
                        Just s -> s
                        Nothing -> error "Environment variable ROS_ROOT not set"
           gendeps = ros_root</>"core"</>"roslib"</>"scripts"</>"gendeps"
       init <$> readProcess gendeps ["-m", fname] "" 
-}

parseMsg :: FilePath -> IO (Either String Msg)
parseMsg fname = do msgFile <- B.readFile fname
                    let shortName = dropExtension . takeFileName $ fname
                        longName = genName fname
                        parser = mkParser shortName longName msgFile
                    -- let hash = genRosMD5 fname
                    case feed (parse parser msgFile) "" of
                      Done leftOver msg
                          | B.null leftOver -> return . Right $ -- . addHash hash $ 
                                               msg
                          | otherwise -> return $ Left $ "Couldn't parse " ++ 
                                                         unpack leftOver
                      Fail _ _ctxt err -> return $ Left err
                      Partial _ -> return $ Left "Incomplete msg definition"