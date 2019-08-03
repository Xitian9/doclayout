{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-
A prettyprinting library for the production of text documents,
including wrapped text, indentated blocks, and tables.
-}

module Text.DocLayout (
       Doc
     , render
     , getDimensions
     , cr
     , blankline
     , blanklines
     , space
     , text
     , vfill
     , char
     , box
     , resizableBox
     , prefixed
     , flush
     , nest
     , aligned
     , hang
     , alignLeft
     , alignRight
     , alignCenter
     , nowrap
     , withColumn
     , withLineLength
     , afterBreak
     , offset
     , minOffset
     , height
     , lblock
     , cblock
     , rblock
     , (<>)
     , (<+>)
     , ($$)
     , ($+$)
     , isEmpty
     , empty
     , cat
     , hcat
     , hsep
     , vcat
     , vsep
     , nestle
     , chomp
     , inside
     , braces
     , brackets
     , parens
     , quotes
     , doubleQuotes
     , charWidth
     , realLength
     )

where
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.List.NonEmpty as N
import Control.Monad (unless)
import Data.String
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.List (foldl', transpose, intersperse)
import Control.Monad.State.Strict
import qualified Data.Text.Lazy.Builder as B
import Data.Text.Lazy.Builder (Builder)
import Data.Foldable (toList)
import Data.String.Conversions (ConvertibleStrings(..), LazyText)
#if MIN_VERSION_base(4,11,0)
#else
import Data.Semigroup (Semigroup)
#endif

import Debug.Trace

newtype Doc = Doc{ unDoc :: Seq D }
  deriving (Semigroup, Monoid, Show)

data D =
    Text Fill !Int !Text -- ^ text with real width, does not break, no '\n'.
                         -- if Fill is VFill, this will fill vertically
                         -- when adjacent to a multiline block.
  | Newline              -- ^ newline
  | SoftSpace            -- ^ space or newline depending on context
  | PushNesting (Int -> Int -> Int)
                         -- ^ change nesting level: first argument to
                         -- function is current column (before left
                         -- padding from centering or right alignment
                         -- is added), second is current nesting level.
  | PopNesting           -- ^ restore previous nesting level
  | Blanks !Int          -- ^ ensure that there are at least n blank lines
                         -- but do not add additional ones if there are
  | Box !Int Doc         -- ^ lay out the document with the given width,
                         -- and treat it as an indivisible unit
  | Chomp Doc            -- ^ remove trailing newlines from document
  | WithColumn (Int -> Doc) -- ^ output conditional on column number
  | WithLineLength (Maybe Int -> Doc) -- ^ output conditional on line length
  | PushAlignment Alignment -- ^ set alignment
  | PopAlignment        -- ^ revert to previous alignment

instance Show D where
  show (Text f n s) = "Text " ++ show f ++ " " ++ show n ++ " " ++ show s
  show Newline = "Newline"
  show SoftSpace = "SoftSpace"
  show (PushNesting _) = "PushNesting <function>"
  show PopNesting = "PopNesting"
  show (Blanks n) = "Blanks " ++ show n
  show (Box n d) = "Box " ++ show n ++ " " ++ show d
  show (Chomp d) = "Chomp " ++ show d
  show (WithColumn _) = "WithColumn <function>"
  show (WithLineLength _) = "WithLineLength <function>"
  show (PushAlignment al) = "PushAlignment " ++ show al
  show PopAlignment = "PopAlignment"

data Fill = VFill | NoFill
  deriving (Show)

data Alignment = AlLeft | AlRight | AlCenter
  deriving (Show)

newtype Line = Line { unLine :: [D] }
  deriving (Show)

instance IsString Doc where
  fromString = text

data RenderState = RenderState{
         column      :: !Int
       , nesting     :: N.NonEmpty Int
       , alignment   :: N.NonEmpty Alignment
       , lineLength  :: Maybe Int  -- ^ 'Nothing' means no wrapping
       , blanks      :: Maybe Int  -- ^ Number of preceding blank lines
       , currentLine :: [D]
       , actualWidth :: Int        -- ^ Actual max line width
       }
  deriving (Show)

-- | Render a Doc with an optional width.
render :: ConvertibleStrings LazyText a => Maybe Int -> Doc -> a
render linelen = convertString . B.toLazyText . mconcat .
                 intersperse (B.singleton '\n') .
                 map buildLine .  snd .  buildLines linelen

-- | Returns (width, height) of Doc.
getDimensions :: Maybe Int -> Doc -> (Int, Int)
getDimensions linelen doc = (w, length ls)  -- width x height
  where
   (w, ls) = buildLines linelen doc

buildLines :: Maybe Int -> Doc -> (Int, [Line])
buildLines linelen doc =
  evalState (do ls <- groupLines (toList (unDoc doc))
                w <- gets actualWidth
                return (w, handleBoxes ls))
    (startingState linelen)

startingState :: Maybe Int -> RenderState
startingState linelen =
  RenderState{ column = 0
             , nesting = N.fromList [0]
             , alignment = N.fromList [AlLeft]
             , lineLength = linelen
             , blanks = Nothing
             , currentLine = mempty
             , actualWidth = 0
             }


-- Group Ds into lines.
groupLines :: [D] -> State RenderState [Line]
groupLines [] = ($ []) <$> emitLine
groupLines (d:ds) = do
  linelen <- gets lineLength
  col <- gets column
  curline <- gets currentLine
  let hasSoftSpace = case curline of
                           SoftSpace:_ -> True
                           _           -> False
  case d of
    WithColumn f -> groupLines $ toList (unDoc (f col)) <> ds
    WithLineLength f -> groupLines $ toList (unDoc (f linelen)) <> ds
    PushNesting f -> do
      modify $ \st ->
        st{ nesting = f col (N.head (nesting st)) N.<| nesting st }
      groupLines ds
    PopNesting -> do
      modify $ \st -> st{ nesting = fromMaybe (nesting st)
                              (snd $ N.uncons (nesting st)) }
      groupLines ds
    PushAlignment align' -> do
      modify $ \st -> st{ alignment = align' N.<| alignment st }
      groupLines ds
    PopAlignment -> do
      modify $ \st -> st{ alignment = fromMaybe (alignment st)
                            (snd $ N.uncons (alignment st)) }
      groupLines ds
    SoftSpace -> do
      unless hasSoftSpace $
        modify $ \st -> st{ currentLine = d : currentLine st
                          , column = column st + 1 }
      groupLines ds
    Blanks n -> do
      f <- emitLine
      g <- emitBlanks n
      f . g <$> groupLines ds
    Text _ len _
      | maybe True ((col + len) <=) linelen || not hasSoftSpace -> do
          addToCurrentLine d
          groupLines ds
      | otherwise -> do
          f <- emitLine
          f <$> groupLines (d:ds)
    Box len _doc
      | maybe True ((col + len) <=) linelen || not hasSoftSpace -> do
          addToCurrentLine d
          groupLines ds
      | otherwise -> do
          f <- emitLine
          f <$> groupLines (d:ds)
    Chomp doc -> do
      let (actualw, ls) = buildLines linelen doc
      modify $ \st -> st{
        actualWidth =
          if actualw > actualWidth st
             then actualw
             else actualWidth st }
      let ls' = reverse . dropWhile (null . unLine) . reverse $ ls
      (ls' ++) <$> groupLines ds
    Newline -> do
          f <- emitLine
          f <$> groupLines ds

addToCurrentLine :: D -> State RenderState ()
addToCurrentLine d = do
  curline <- gets currentLine
  nest' N.:| _ <- gets nesting
  let curline' =
        case d of
          SoftSpace -> curline
          _ | null curline
            , nest' > 0 ->
                 [Text NoFill nest' (T.replicate nest' " ")]
            | otherwise -> curline
  col <- gets column
  let newcol = col + dLength d
  modify $ \st -> st{ currentLine = d : curline'
                    , column = newcol }
                    -- note, newcol may be over line length if
                    -- we could not fit the content.
                    -- getDimensions can pick up actual
                    -- dimensions.

emitLine :: State RenderState ([Line] -> [Line])
emitLine = do
  align' N.:| _ <- gets alignment
  curline <- gets currentLine
  col <- gets column
  nest' N.:| _ <- gets nesting
  modify $ \st -> st{ currentLine = []
                    , column = nest'
                    , actualWidth =
                       if col > actualWidth st
                          then col
                          else actualWidth st
                    }
  let printable = reverse (dropWhile isSoftSpace curline)
  if null printable
     then return id
     else do
       modify $ \st -> st{ blanks = Just 0 }
       let printableWidth = foldr ((+) . dLength) 0 printable
       mbLineLength <- gets lineLength
       let pad =
            case (align', mbLineLength, printableWidth) of
              (AlLeft, Just linelen, w) | w > 0
                 -> let padw = linelen - w
                    in  (++ (replicate padw SoftSpace))
              (AlCenter, Just linelen, w) | w > 0
                 -> let padw = (linelen - w) `div` 2
                    in  (Text NoFill padw (T.replicate padw " ") :) .
                        (++ (replicate padw SoftSpace))
              (AlRight, Just linelen, w) | w > 0
                 -> let padw = linelen - w
                    in  (Text NoFill padw (T.replicate padw " ") :)
              _                           -> id
       return (Line (pad printable) :)

emitBlanks :: Int -> State RenderState ([Line] -> [Line])
emitBlanks n = do
  nest' N.:| _ <- gets nesting
  mbbls <- gets blanks
  case mbbls of
    Nothing -> return id -- at beginning of document, don't add blanks
    Just bls -> do
      let blsNeeded = n - bls
      if blsNeeded > 0
         then do
           modify $ \st -> st { currentLine = []
                              , column = nest'
                              , blanks = Just $ bls + 1 }
           ((Line []:) .) <$> emitBlanks n
         else return id

isSoftSpace :: D -> Bool
isSoftSpace SoftSpace = True
isSoftSpace _ = False

isBox :: D -> Bool
isBox Box{} = True
isBox _ = False

handleBoxes :: [Line] -> [Line]
handleBoxes [] = []
handleBoxes (Line ds : ls)
  | any isBox ds = newlines ++ handleBoxes ls
  | otherwise    = Line ds : handleBoxes ls
 where
  newlines = map (Line . mconcat) $ transpose $
              zipWith padBox boxes [1..]
  boxes :: [(Int, Int, [[D]])]
  boxes = map expandBox ds
  numboxes = length boxes
  expandBox (Box w doc) = (w, length ls', ls')
    where ls' = map unLine . snd $ buildLines (Just w) doc
  expandBox d = (dLength d, 1, [[d]])
  maxdepth = maximum $ map (\(_,x,_) -> x) boxes
  padBox (w, d, ls') num
    | d < maxdepth = ls' ++ replicate (maxdepth - d)
                             (case ls' of
                               [[Text VFill _ t]] -> [Text VFill w t]
                               _ | num == numboxes -> []
                                 | otherwise -> replicate w SoftSpace)
    | otherwise    = ls'

dLength :: D -> Int
dLength (Text _ n _) = n
dLength SoftSpace    = 1
dLength (Box n _)    = n
dLength _            = 0

-- Render a line.
buildLine :: Line -> Builder
buildLine (Line ds) = fromMaybe mempty $ foldr go Nothing ds
 where
   go (Text _ _ t) Nothing    = Just (B.fromText t)
   go (Text _ _ t) (Just acc) = Just (B.fromText t <> acc)
   go SoftSpace    Nothing    = Nothing -- don't render SoftSpace at end
   go SoftSpace    (Just acc) = Just (B.fromText " " <> acc)
   go _ x                     = x

single :: D -> Doc
single = Doc . Seq.singleton

-- | A breaking (reflowable) space.
space :: Doc
space = single SoftSpace

-- | A carriage return.  Does nothing if we're at the beginning of
-- a line; otherwise inserts a newline.
cr :: Doc
cr = single Newline

-- | Inserts a blank line unless one exists already.
-- (@blankline <> blankline@ has the same effect as @blankline@.
blankline :: Doc
blankline = single (Blanks 1)

-- | Inserts blank lines unless they exist already.
-- (@blanklines m <> blanklines n@ has the same effect as @blanklines (max m n)@.
blanklines :: Int -> Doc
blanklines n = single (Blanks n)

-- | A literal string.
text :: String -> Doc
text = Doc . toChunks
  where toChunks :: String -> Seq D
        toChunks [] = mempty
        toChunks s =
           case break (=='\n') s of
             ([], _:ys) -> Newline Seq.<| toChunks ys
             (xs, _:ys) -> Text NoFill (realLength xs) (T.pack xs) Seq.<|
                               (Newline Seq.<| toChunks ys)
             (xs, [])   -> Seq.singleton $
                              Text NoFill (realLength xs) (T.pack xs)

-- | A string that fills vertically next to a block; may not
-- contain \n.
vfill :: String -> Doc
vfill xs = single (Text VFill (realLength xs) (T.pack xs))

-- | A character.
char :: Char -> Doc
char c = single $ Text NoFill (charWidth c) (T.singleton c)

-- | Returns the width of a 'Doc' (without reflowing).
offset :: Doc -> Int
offset doc = fst $ getDimensions Nothing doc

-- | Returns the height of a block or other 'Doc' (without reflowing).
height :: Doc -> Int
height doc = snd $ getDimensions Nothing doc

-- | Returns the minimal width of a 'Doc' when reflowed at breakable spaces.
minOffset :: Doc -> Int
minOffset doc = fst $ getDimensions (Just 0) doc

-- | Output conditional on current column.
withColumn :: (Int -> Doc) -> Doc
withColumn f = single (WithColumn f)

-- | Output conditional on line length.
withLineLength :: (Maybe Int -> Doc) -> Doc
withLineLength f = single (WithLineLength f)

-- | Content to print only if it comes at the beginning of a line,
-- to be used e.g. for escaping line-initial `.` in roff man.
afterBreak :: String -> Doc
afterBreak s =
  withColumn (\c -> if c == 0
                       then text s
                       else mempty)

-- | A box with the specified width.  If content can't fit
-- in the width, it is silently truncated.
box :: Int -> Doc -> Doc
box n doc = single $ Box n doc

-- | A box with an optional minimum and maximum width.
-- If no minimum width is specified, the box will not
-- be larger than the narrowest space needed to contain its contents.
-- If no maximum width is specified, it will expand as
-- needed to fit its contents.
resizableBox :: Maybe Int -> Maybe Int -> Doc -> Doc
resizableBox mbMinWidth mbMaxWidth doc = box width doc
  where
   contentWidth = minOffset doc
   width = case (mbMinWidth, mbMaxWidth) of
              (Nothing, Nothing)             -> contentWidth
              (Nothing, Just maxWidth)       -> min maxWidth contentWidth
              (Just minWidth, Nothing)       -> max minWidth contentWidth
              (Just minWidth, Just maxWidth) ->
                min (max minWidth contentWidth) maxWidth

-- | @lblock n d@ is a block of width @n@ characters, with
-- text derived from @d@ and aligned to the left.
lblock :: Int -> Doc -> Doc
lblock w doc = box w (alignLeft doc)

-- | Like 'lblock' but aligned to the right.
rblock :: Int -> Doc -> Doc
rblock w doc = box w (alignRight doc)

-- | Like 'lblock' but aligned centered.
cblock :: Int -> Doc -> Doc
cblock w doc = box w (alignCenter doc)

-- Note: we need cr in these definitions, or the last line
-- gets the wrong alignment:

-- | Align left.
alignLeft :: Doc -> Doc
alignLeft doc =
  single (PushAlignment AlLeft) <> doc <> cr <> single PopAlignment

-- | Align right.
alignRight :: Doc -> Doc
alignRight doc =
  single (PushAlignment AlRight) <> doc <> cr <> single PopAlignment

-- | Align right.
alignCenter :: Doc -> Doc
alignCenter doc =
  single (PushAlignment AlCenter) <> doc <> cr <> single PopAlignment

-- | Chomps trailing blank space off of a 'Doc'.
chomp :: Doc -> Doc
chomp doc = single (Chomp doc)

-- | Removes leading blank lines from a 'Doc'.
nestle :: Doc -> Doc
nestle (Doc ds) =
  case Seq.viewl ds of
    Newline    Seq.:< rest  -> nestle (Doc rest)
    Blanks _ Seq.:< rest    -> nestle (Doc rest)
    _                       -> Doc ds

-- | True if the document is empty.  A document counts as
-- empty if it would render empty. So @isEmpty (nest 5 empty) == True@.
isEmpty :: Doc -> Bool
isEmpty = all (not . isPrinting) . unDoc
  where
    isPrinting Text{} = True
    isPrinting Blanks{} = True
    isPrinting (Box _ d) = not (isEmpty d)
    isPrinting _ = False

-- | The empty document.
empty :: Doc
empty = mempty

-- | Concatenate a list of 'Doc's.
cat :: [Doc] -> Doc
cat = mconcat

-- | Same as 'cat'.
hcat :: [Doc] -> Doc
hcat = mconcat

-- | Concatenate two 'Doc's, putting breakable space between them.
infixr 6 <+>
(<+>) :: Doc -> Doc -> Doc
(<+>) x y
  | isEmpty x = y
  | isEmpty y = x
  | otherwise = x <> space <> y

-- | Same as 'cat', but putting breakable spaces between the 'Doc's.
hsep :: [Doc] -> Doc
hsep = foldr (<+>) empty

infixr 5 $$
-- | @a $$ b@ puts @a@ above @b@.
($$) :: Doc -> Doc -> Doc
($$) x y
  | isEmpty x = y
  | isEmpty y = x
  | otherwise = x <> cr <> y

infixr 5 $+$
-- | @a $+$ b@ puts @a@ above @b@, with a blank line between.
($+$) :: Doc -> Doc -> Doc
($+$) x y
  | isEmpty x = y
  | isEmpty y = x
  | otherwise = x <> blankline <> y

-- | List version of '$$'.
vcat :: [Doc] -> Doc
vcat = foldr ($$) empty

-- | List version of '$+$'.
vsep :: [Doc] -> Doc
vsep = foldr ($+$) empty

-- | Makes a 'Doc' non-reflowable.
nowrap :: Doc -> Doc
nowrap (Doc ds) = Doc $ fmap replaceSpace ds
  where replaceSpace SoftSpace = Text NoFill 1 " "
        replaceSpace x         = x

-- | Makes a 'Doc' flush against the left margin.
flush :: Doc -> Doc
flush doc =
  single (PushNesting (\_ _ -> 0)) <> doc <> single PopNesting

-- | Indents a 'Doc' by the specified number of spaces.
nest :: Int -> Doc -> Doc
nest ind doc =
  single (PushNesting (\_ n -> n + ind)) <> doc <> single PopNesting

-- | A hanging indent. @hang ind start doc@ prints @start@,
-- then @doc@, leaving an indent of @ind@ spaces on every
-- line but the first.
hang :: Int -> Doc -> Doc -> Doc
hang ind start doc = start <> nest ind doc

-- | Align a 'Doc' so that new lines start at current column.
aligned :: Doc -> Doc
aligned doc =
  single (PushNesting (\col _ -> col)) <>
  doc <>
  single PopNesting

-- | Uses the specified string as a prefix for every line of
-- the argument.
prefixed :: String -> Doc -> Doc
prefixed pref doc =
  withLineLength $ \mblen ->
    let boxwidth =
         case mblen of
           Just l  -> l - realLength pref
           Nothing -> fst (getDimensions Nothing doc) - realLength pref
    in  vfill pref <> box boxwidth doc

-- | Encloses a 'Doc' inside a start and end 'Doc'.
inside :: Doc -> Doc -> Doc -> Doc
inside start end contents =
  start <> contents <> end

-- | Puts a 'Doc' in curly braces.
braces :: Doc -> Doc
braces = inside (char '{') (char '}')

-- | Puts a 'Doc' in square brackets.
brackets :: Doc -> Doc
brackets = inside (char '[') (char ']')

-- | Puts a 'Doc' in parentheses.
parens :: Doc -> Doc
parens = inside (char '(') (char ')')

-- | Wraps a 'Doc' in single quotes.
quotes :: Doc -> Doc
quotes = inside (char '\'') (char '\'')

-- | Wraps a 'Doc' in double quotes.
doubleQuotes :: Doc -> Doc
doubleQuotes = inside (char '"') (char '"')

-- | Returns width of a character in a monospace font:  0 for a combining
-- character, 1 for a regular character, 2 for an East Asian wide character.
charWidth :: Char -> Int
charWidth c =
  case c of
      _ | c <  '\x0300'                    -> 1
        | c >= '\x0300' && c <= '\x036F'   -> 0  -- combining
        | c >= '\x0370' && c <= '\x10FC'   -> 1
        | c >= '\x1100' && c <= '\x115F'   -> 2
        | c >= '\x1160' && c <= '\x11A2'   -> 1
        | c >= '\x11A3' && c <= '\x11A7'   -> 2
        | c >= '\x11A8' && c <= '\x11F9'   -> 1
        | c >= '\x11FA' && c <= '\x11FF'   -> 2
        | c >= '\x1200' && c <= '\x2328'   -> 1
        | c >= '\x2329' && c <= '\x232A'   -> 2
        | c >= '\x232B' && c <= '\x2E31'   -> 1
        | c >= '\x2E80' && c <= '\x303E'   -> 2
        | c == '\x303F'                    -> 1
        | c >= '\x3041' && c <= '\x3247'   -> 2
        | c >= '\x3248' && c <= '\x324F'   -> 1 -- ambiguous
        | c >= '\x3250' && c <= '\x4DBF'   -> 2
        | c >= '\x4DC0' && c <= '\x4DFF'   -> 1
        | c >= '\x4E00' && c <= '\xA4C6'   -> 2
        | c >= '\xA4D0' && c <= '\xA95F'   -> 1
        | c >= '\xA960' && c <= '\xA97C'   -> 2
        | c >= '\xA980' && c <= '\xABF9'   -> 1
        | c >= '\xAC00' && c <= '\xD7FB'   -> 2
        | c >= '\xD800' && c <= '\xDFFF'   -> 1
        | c >= '\xE000' && c <= '\xF8FF'   -> 1 -- ambiguous
        | c >= '\xF900' && c <= '\xFAFF'   -> 2
        | c >= '\xFB00' && c <= '\xFDFD'   -> 1
        | c >= '\xFE00' && c <= '\xFE0F'   -> 1 -- ambiguous
        | c >= '\xFE10' && c <= '\xFE19'   -> 2
        | c >= '\xFE20' && c <= '\xFE26'   -> 1
        | c >= '\xFE30' && c <= '\xFE6B'   -> 2
        | c >= '\xFE70' && c <= '\xFEFF'   -> 1
        | c >= '\xFF01' && c <= '\xFF60'   -> 2
        | c >= '\xFF61' && c <= '\x16A38'  -> 1
        | c >= '\x1B000' && c <= '\x1B001' -> 2
        | c >= '\x1D000' && c <= '\x1F1FF' -> 1
        | c >= '\x1F200' && c <= '\x1F251' -> 2
        | c >= '\x1F300' && c <= '\x1F773' -> 1
        | c >= '\x20000' && c <= '\x3FFFD' -> 2
        | otherwise                        -> 1

-- | Get real length of string, taking into account combining and double-wide
-- characters.
realLength :: String -> Int
realLength = foldl' (+) 0 . map charWidth
