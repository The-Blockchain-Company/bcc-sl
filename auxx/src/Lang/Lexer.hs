{-# LANGUAGE RecordWildCards #-}

module Lang.Lexer
       ( BracketSide(..)
       , _BracketSideOpening
       , _BracketSideClosing
       , UnknownChar(..)
       , FilePath'(..)
       , Token(..)
       , _TokenSquareBracket
       , _TokenParenthesis
       , _TokenString
       , _TokenAddress
       , _TokenPublicKey
       , _TokenStakeholderId
       , _TokenHash
       , _TokenBlockVersion
       , _TokenSoftwareVersion
       , _TokenFilePath
       , _TokenNumber
       , _TokenName
       , _TokenKey
       , _TokenEquals
       , _TokenSemicolon
       , _TokenUnknown
       , tokenize
       , tokenize'
       , detokenize
       , tokenRender
       ) where

import           Universum hiding (try)

import qualified Control.Applicative.Combinators.NonEmpty as NonEmpty
import           Control.Lens (makePrisms)
import           Data.Char (isAlpha, isAlphaNum)
import qualified Data.List as List
import qualified Data.List.NonEmpty as NonEmpty
import           Data.Loc (Loc, Span, loc, spanFromTo)
import           Data.Scientific (Scientific)
import qualified Data.Text as Text
import           Formatting (sformat)
import qualified Formatting.Buildable as Buildable
import           Test.QuickCheck.Arbitrary.Generic (Arbitrary (..),
                     genericArbitrary, genericShrink)
import qualified Test.QuickCheck.Gen as QC
import           Test.QuickCheck.Instances ()
import           Text.Megaparsec (Parsec, SourcePos (..), anySingle, between,
                     choice, eof, getSourcePos, manyTill, notFollowedBy,
                     parseMaybe, satisfy, skipMany, takeP, takeWhile1P, try,
                     unPos, (<?>))
import           Text.Megaparsec.Char (char, spaceChar,
                     string)
import           Text.Megaparsec.Char.Lexer (decimal, scientific, signed)

import           Lang.Name (Letter, Name (..), unsafeMkLetter)
import           Pos.Chain.Update (ApplicationName (..), BlockVersion (..),
                     SoftwareVersion (..))
import           Pos.Core (Address, StakeholderId, decodeTextAddress)
import           Pos.Crypto (AHash (..), PublicKey, decodeAbstractHash,
                     fullPublicKeyF, hashHexF, parseFullPublicKey,
                     unsafeCheatingHashCoerce)
import           Pos.Util.Util (toParsecError)

import           Test.Pos.Chain.Update.Arbitrary ()
import           Test.Pos.Core.Arbitrary ()

data BracketSide = BracketSideOpening | BracketSideClosing
    deriving (Eq, Ord, Show, Generic)

makePrisms ''BracketSide

withBracketSide :: a -> a -> BracketSide -> a
withBracketSide onOpening onClosing = \case
    BracketSideOpening -> onOpening
    BracketSideClosing -> onClosing

instance Arbitrary BracketSide where
    arbitrary = genericArbitrary
    shrink = genericShrink

newtype UnknownChar = UnknownChar Char
    deriving (Eq, Ord, Show)

instance Arbitrary UnknownChar where
    arbitrary = pure (UnknownChar '\0')

newtype FilePath' = FilePath'
    { getFilePath' :: FilePath
    } deriving (Eq, Ord, Show, Generic, IsString)

instance Arbitrary FilePath' where
    arbitrary = QC.elements
        [ "/a/b/c"
        , "./a/b/c"
        , "/p a t h/h e r e.k"
        ] -- TODO: proper generator

instance Buildable FilePath' where
    build = fromString . concatMap escape . getFilePath'
      where
        escape c | isFilePathChar c = [c]
                 | otherwise = '\\':[c]

isFilePathChar :: Char -> Bool
isFilePathChar c = isAlphaNum c || c `elem` ['.', '/', '-', '_']

data Token
    = TokenSquareBracket BracketSide
    | TokenParenthesis BracketSide
    | TokenString Text
    | TokenNumber Scientific
    | TokenAddress Address
    | TokenPublicKey PublicKey
    | TokenStakeholderId StakeholderId
    | TokenHash AHash
    | TokenBlockVersion BlockVersion
    | TokenSoftwareVersion SoftwareVersion
    | TokenFilePath FilePath'
    | TokenName Name
    | TokenKey Name
    | TokenEquals
    | TokenSemicolon
    | TokenUnknown UnknownChar
    deriving (Eq, Ord, Show, Generic)

makePrisms ''Token

instance Arbitrary Token where
    arbitrary = genericArbitrary
    shrink = genericShrink

tokenRender :: Token -> Text
tokenRender = \case
    TokenSquareBracket bs -> withBracketSide "[" "]" bs
    TokenParenthesis bs -> withBracketSide "(" ")" bs
    -- Double up every double quote, and surround the whole thing with double
    -- quotes.
    TokenString t -> quote (escapeQuotes t)
      where
        quote :: Text -> Text
        quote t' = Text.concat [Text.singleton '\"', t', Text.singleton '\"']
        escapeQuotes :: Text -> Text
        escapeQuotes = Text.intercalate "\"\"" . Text.splitOn "\""
    TokenNumber n -> show n
    TokenAddress a -> pretty a
    TokenPublicKey pk -> sformat fullPublicKeyF pk
    TokenStakeholderId sId -> sformat hashHexF sId
    TokenHash h -> sformat hashHexF (getAHash h)
    TokenBlockVersion v -> pretty v
    TokenSoftwareVersion v -> "~software~" <> pretty v
    TokenFilePath s -> pretty s
    TokenName ss -> pretty ss
    TokenKey ss -> pretty ss <> ":"
    TokenEquals -> "="
    TokenSemicolon -> ";"
    TokenUnknown (UnknownChar c) -> Text.singleton c

detokenize :: [Token] -> Text
detokenize = unwords . List.map tokenRender

type Lexer a = Parsec Void Text a

tokenize :: Text -> [(Span, Token)]
tokenize = fromMaybe noTokenErr . tokenize'
  where
    noTokenErr =
        error "tokenize: no token could be consumed. This is a bug"

tokenize' :: Text -> Maybe [(Span, Token)]
tokenize' = parseMaybe (between pSkip eof (many pToken))

pToken :: Lexer (Span, Token)
pToken = withPosition (try pToken' <|> pUnknown) <* pSkip
  where
    posToLoc :: SourcePos -> Loc
    posToLoc (SourcePos _ sourceLine sourceColumn) = uncurry loc
        ( fromIntegral . unPos $ sourceLine
        , fromIntegral . unPos $ sourceColumn)
    withPosition p = do
        pos1 <- posToLoc <$> getSourcePos
        t <- p
        pos2 <- posToLoc <$> getSourcePos
        return (spanFromTo pos1 pos2, t)

pUnknown :: Lexer Token
pUnknown = TokenUnknown . UnknownChar <$> anySingle

pSkip :: Lexer ()
pSkip = skipMany (void spaceChar)

marking :: Text -> Lexer a -> Lexer a
marking t p = optional (string $ "~" <> t <> "~") *> p

pToken' :: Lexer Token
pToken' = choice
    [ pPunct
    , marking "addr" $ TokenAddress <$> try pAddress
    , marking "pk" $ TokenPublicKey <$> try pPublicKey
    , marking "stakeholder" $ TokenStakeholderId <$> try pStakeholderId
    , marking "hash" $ TokenHash <$> try pHash
    , marking "block-v" $ TokenBlockVersion <$> try pBlockVersion
    , string "~software~" *> (TokenSoftwareVersion <$> try pSoftwareVersion)
    , marking "filepath" $ TokenFilePath <$> pFilePath
    , marking "num" $ TokenNumber <$> pScientific
    , marking "str" $ TokenString <$> pText
    , marking "ident" $ pIdent
    ] <?> "token"

pPunct :: Lexer Token
pPunct = choice
    [ char '[' $> TokenSquareBracket BracketSideOpening
    , char ']' $> TokenSquareBracket BracketSideClosing
    , char '(' $> TokenParenthesis BracketSideOpening
    , char ')' $> TokenParenthesis BracketSideClosing
    , char '=' $> TokenEquals
    , char ';' $> TokenSemicolon
    ] <?> "punct"

pText :: Lexer Text
pText = do
    _ <- char '\"'
    Text.pack <$> loop []
  where
    loop :: [Char] -> Lexer [Char]
    loop !acc = do
        next <- anySingle
        case next of
            -- Check for double double quotes. If it's a single double quote,
            -- it's the end of the string.
            '\"' -> try (doubleQuote acc) <|> pure (reverse acc)
            c    -> loop (c : acc)
    doubleQuote :: [Char] -> Lexer [Char]
    doubleQuote !acc = char '\"' >> loop ('\"' : acc)

pSomeAlphaNum :: Lexer Text
pSomeAlphaNum = takeWhile1P (Just "alphanumeric") isAlphaNum

pAddress :: Lexer Address
pAddress = do
    str <- pSomeAlphaNum
    toParsecError $ decodeTextAddress str

pPublicKey :: Lexer PublicKey
pPublicKey = do
    str <- (<>) <$> takeP (Just "base64") 86 <*> string "=="
    toParsecError $ parseFullPublicKey str

pStakeholderId :: Lexer StakeholderId
pStakeholderId = do
    str <- pSomeAlphaNum
    toParsecError $ decodeAbstractHash str

pHash :: Lexer AHash
pHash = do
    str <- pSomeAlphaNum
    toParsecError . fmap unsafeCheatingHashCoerce $ decodeAbstractHash str

pBlockVersion :: Lexer BlockVersion
pBlockVersion = do
    bvMajor <- decimal
    void $ char '.'
    bvSentry <- decimal
    notFollowedBy $ char '.'
    return BlockVersion{..}

pSoftwareVersion :: Lexer SoftwareVersion
pSoftwareVersion = do
    appName <- manyTill (satisfy isAlphaNum <|> char '-') (char ':')
    let svAppName = ApplicationName (toText appName)
    svNumber <- decimal
    notFollowedBy $ char '.'
    return SoftwareVersion {..}

pFilePath :: Lexer FilePath'
pFilePath = FilePath' <$> do
    dots <- many (char '.')
    cs <-
        (:) <$> char '/'
            <*> many pFilePathChar
        <|> pure ""
    notFollowedBy pFilePathChar
    let path = dots <> cs
    guard $ not (null path)
    return path
  where
    pFilePathChar :: Lexer Char
    pFilePathChar =
        char '\\' *> anySingle <|>
        satisfy isFilePathChar

pIdent :: Lexer Token
pIdent = do
    name <- NonEmpty.sepBy1 pNameSection (char '-')
    notFollowedBy (satisfy isAlphaNum)
    isKey <- isJust <$> optional (char ':')
    return $ (if isKey then TokenKey else TokenName) (Name name)

pNameSection :: Lexer (NonEmpty Letter)
pNameSection = NonEmpty.some1 pLetter

pLetter :: Lexer Letter
pLetter = unsafeMkLetter <$> satisfy isAlpha

pScientific :: Lexer Scientific
pScientific = do
    n <- signed (return ()) scientific
    p <- isJust <$> optional (char '%')
    return $ if p then n / 100 else n

{-# ANN module ("HLint: ignore Use toText" :: Text) #-}
