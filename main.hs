{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE QuasiQuotes #-}
------------------------------------------------------------------------------
-- | 
-- Module         : Main
-- Copyright      : (C) 2014 Samuli Thomasson
-- License        : MIT (see the file LICENSE)
-- Maintainer     : Samuli Thomasson <samuli.thomasson@paivola.fi>
-- Stability      : experimental
-- Portability    : non-portable
-- 
--     /opetus/kurssit.body
--     /svenska/studierna/kurser.body
--     /english/studying/courses.body
--
--     /opetus/kurssit/{aineopinnot,perusopinnot,muutopinnot,syventavatopinnot}.body
--     /svenska/studierna/{...}.body
--     /english/studying/{...}.body
--
------------------------------------------------------------------------------
module Main (main) where

import Prelude
import           Control.Monad
import           Control.Applicative
import           Control.Monad.Reader
import           Data.Function              (on)
import qualified Data.List          as L
import           Data.Map                   (Map)
import qualified Data.Map           as Map
import           Data.Maybe
import           Data.Monoid                ((<>))
import           Data.Text                  (Text)
import qualified Data.Text          as T
import qualified Data.Text.Lazy     as LT
import qualified Data.Text.Lazy.IO  as LT
import qualified Data.Yaml          as Yaml
import           Network.HTTP.Conduit       (simpleHttp)
import           Text.Blaze.Html            (preEscapedToHtml)
import           Text.Blaze.Renderer.Text   (renderMarkup)
import           Text.Hamlet
import           Text.Julius
import           Text.Regex
import qualified Text.XML           as XML
import           Text.XML.Cursor
import           Debug.Trace
import           Data.Time
import           System.Exit (exitFailure)
import           System.IO.Unsafe (unsafePerformIO) -- pure getCurrentTime
import           System.Environment (getArgs)
import           GHC.Generics

main :: IO ()
main = Yaml.decodeFileEither "config.yaml" >>= either (error . show) (runReaderT go)
  where go = do Config{..} <- ask
                forM_ pages $ \pc@PageConf{..} -> do
                    table <- getData pageId >>= parseTable
                    forM_ languages $ \lang -> renderTable lang pc table

-- * Types

type M = ReaderT Config IO
type Lang = Text -- ^ en, se, fi, ...
data PageConf = PageConf
              { pageId    :: String
              , pageUrl   :: Map Lang Text
              , pageTitle :: Map Lang Text
              } deriving Generic
data Config   = Config
              { fetchUrl                          :: String
              , pages                             :: [PageConf]
              , colCode, colLang, colCourseName
              , colRepeats, colPeriod, colWebsite :: Text
              , colLangFi, colLukukausi, classCur :: Text
              , categories                        :: [[Text]]
              , i18n                              :: I18N
              , languages                         :: [Lang]
              } deriving Generic
instance Yaml.FromJSON PageConf
instance Yaml.FromJSON Config

data Table        = Table UTCTime [Header] [Course]       -- ^ Source table
                  deriving (Show, Read)
type Header       = Text                                  -- ^ Column headers in source table
type Course       = ([Category], Map Header ContentBlock) -- ^ A row in source table
type Category     = Text                                  -- ^ First column in source table
type ContentBlock = Text                                  -- ^ td in source table
type I18N         = Map Text (Map Lang Text)

-- * Utility

toUrlPath :: Text -> Text
toUrlPath  = (<> ".html")

toFilePath :: Text -> FilePath
toFilePath = T.unpack . ("testi" <>) . (<> ".body")

-- | A hack, for confluence html is far from the (strictly) spec.
regexes :: [String -> String]
regexes = [ rm "<meta [^>]*>", rm "<link [^>]*>", rm "<link [^>]*\">", rm "<img [^>]*>"
          , rm "<br[^>]*>", rm "<col [^>]*>" ]
    where rm s i = subRegex (mkRegexWithOpts s False True) i ""

toLang :: I18N -> Lang -> Text -> Text
toLang db lang key = maybe (trace ("Warn: no i18n db for key `" ++ T.unpack key ++ "'") key)
                           (fromMaybe fallback . Map.lookup lang) (Map.lookup key db)
  where fallback | "fi" <- lang = key
                 | otherwise    = trace ("Warn: no i18n for key `" ++ T.unpack key ++ "' with lang `" ++ T.unpack lang ++ "'") key

lookup' :: Lang -> Map Lang y -> y
lookup' i = fromJust . Map.lookup i

normalize :: Text -> Text
normalize =
    T.dropAround (`elem` " ,-!")
    . T.replace "ILMOITTAUTUMINEN PUUTTUU" ""
    . T.unwords . map (T.unwords . T.words) . T.lines

-- * Rendering

renderTable :: Lang -> PageConf -> Table -> M ()
renderTable lang pc@PageConf{..} table =
    ask >>= lift . LT.writeFile fp . renderMarkup . tableBody lang pc table
  where fp = toFilePath $ lookup' lang pageUrl

-- * Content

-- | How to render the data
tableBody :: Lang -> PageConf -> Table -> Config -> Html
tableBody lang PageConf{..} (Table time _ stuff) cnf@Config{..} =
        let ii             = toLang i18n lang
            getLang        = getThingLang i18n
            withCat n xs f = [shamlet|
$forall ys <- L.groupBy (catGroup cnf n) xs
    <div.courses>
        #{ppCat n ys}
        #{f ys}
|]
            -- course table
            go 4 xs        = [shamlet|
<table style="width:100%">
 $forall c <- xs
  <tr data-taso="#{fromMaybe "" $ catAt cnf 0 c}" data-kieli="#{getThing colLang c}" data-lukukausi="#{getThing colLukukausi c}" data-pidetaan="#{getThing "pidetään" c}">
    <td style="width:10%">
      <a href="https://weboodi.helsinki.fi/hy/opintjakstied.jsp?html=1&Kieli=1&Tunniste=#{getThing colCode c}">
        <b>#{getThing colCode c}

    <td style="width:55%">#{getLang lang colCourseName c} #
      $with op <- getThing "op" c
          $if not (T.null op)
               (#{op} #{ii "op"})

    <td.compact style="width:7%"  title="#{getThing colPeriod c}">#{getThing colPeriod c}
    <td.compact style="width:7%"  title="#{getThing colRepeats c}">#{getThing colRepeats c}
    <td.compact style="width:20%" title="#{getThing colLangFi c}">#{getThing colLangFi c}
      $maybe p <- getThingMaybe colWebsite c
        $if not (T.null p)
            \ #
            <a href="#{p}">#{ii colWebsite}
|]
            go n xs        = withCat n xs (go (n + 1))
----
            ppCat n xs     = [shamlet|
$maybe x <- catAt cnf n (head xs)
    $case n
        $of 0
            <h1>#{ii x}
        $of 1
            <h2>#{ii x}
        $of 2
            <h3>
                <i>#{ii x}
        $of 3
            <h4>#{ii x}
        $of 4
            <h5>#{ii x}
        $of 5
            <h6>#{ii x}
        $of _
            <b>#{ii x}
            |]
----
        in [shamlet|
\<!-- title: #{lookup' lang pageTitle} -->
\<!-- fi (Suomenkielinen versio): #{toUrlPath $ lookup' "fi" pageUrl} -->
\<!-- se (Svensk version): #{toUrlPath $ lookup' "se" pageUrl} -->
\<!-- en (English version): #{toUrlPath $ lookup' "en" pageUrl} -->
\ 
<p>
  #{ii "Kieli"}:&nbsp;
  <select id="select-kieli" name="kieli" onchange="updateList(this)">
     <option value="any">#{ii "Kaikki"}
     $forall l <- languages
        <option value="#{l}">#{ii l}

  #{ii "Taso"}:&nbsp;
  <select id="select-taso" name="taso" onchange="updateList(this)">
     <option value="any" >#{ii "Kaikki"}
     $forall cat <- (categories !! 0)
        <option value="#{cat}">#{ii cat}

  #{ii "Lukukausi"}:&nbsp;
  <select id="select-lukukausi" name="lukukausi" onchange="updateList(this)">
     <option value="any"   >#{ii "Kaikki"}
     <option value="kevät" >#{ii "Kevät"}
     <option value="syksy" >#{ii "Syksy"}
     <option value="kesä"  >#{ii "Kesä"}
<p>
  #{ii "aputeksti"}

<table style="width:100%">
    <tr>
        <td style="width:10%">#{ii colCode}
        <td style="width:55%">#{ii colCourseName}
        <td style="width:7%" >#{ii colPeriod}
        <td style="width:7%" >#{ii colRepeats}
        <td style="width:20%">#{ii colLang}

#{withCat 0 stuff (go 1)}

<p>#{ii "Päivitetty"} #{show time}
<style>
    .courses table { table-layout:fixed; }
    .courses td.compact {
        overflow:hidden;
        text-overflow:ellipsis;
        white-space:nowrap;
    }
    tr[data-pidetaan="next-year"] { color:gray; }
<script type="text/javascript">
  #{preEscapedToHtml $ renderJavascript $ jsLogic undefined}
|]

--
jsLogic :: JavascriptUrl url
jsLogic = [julius|

fs = { };

updateList = function(e) {
    var name = e.getAttribute("name");
    var opts = e.selectedOptions;

    fs[name] = [];
    for (var i = 0; i < opts.length; i++) {
        fs[name].push(opts[i].getAttribute("value"));
    }

    var xs = document.querySelectorAll(".courses tr");

    for (var i = 0; i < xs.length; i++) {
        xs[i].hidden = !matchesFilters(fs, xs[i]);
    }

    updateHiddenDivs();
}

matchesFilters = function(fs, thing) {
    for (var f in fs) {
        if (fs[f] != "any") {
            var m = false;
            for (var i = 0; i < fs[f].length; i++) {
                if (thing.dataset[f].indexOf(fs[f][i]) > -1) {
                    m = true;
                    break;
                }
            }
            if (!m) return false;
        }
    }
    return true;
}

updateHiddenDivs = function() {
    var xs = document.querySelectorAll(".courses");
    for (var i = 0; i < xs.length; i++) {
        var hidden = true;
        var ts = xs[i].getElementsByTagName("tr");
        for (var j = 0; j < ts.length; j++) {
            if (!ts[j].hidden) {
                hidden = false;
                break;
            }
        }
        xs[i].hidden = hidden;
    }
}
|]

-- * Courses and categories

toCourse :: Config -> [Category] -> [Header] -> Bool -> [Text] -> Course
toCourse Config{..} cats hs iscur xs =
    (cats, Map.adjust getLang colLang $
           Map.insert "pidetään" (if iscur then "this-year" else "next-year") $
           Map.insert colLangFi fiLangs $
           Map.insert colLukukausi lukukausi vals)
  where vals      = Map.fromList $ zip hs $ map normalize xs

        lukukausi = fromMaybe "syksy, kevät" $ Map.lookup colPeriod vals >>= toLukukausi
        toLukukausi x
            | x == "I"   || x == "II" || x == "I-II"   = Just "syksy"
            | x == "III" || x == "IV" || x == "III-IV" = Just "kevät"
            | x == "V"                                 = Just "kesä"
            | x == "I-IV"                              = Just "syksy, kevät"
            | "kevät" `T.isInfixOf` x                  = Just "kevät"
            | "syksy" `T.isInfixOf` x                  = Just "syksy"
            | "kesä"  `T.isInfixOf` x                  = Just "kesä"
            | otherwise                                = Nothing

        getLang x | x == "suomi"                                   = "fi"
                  | "suomi" `T.isInfixOf` x, "eng" `T.isInfixOf` x = "fi, en"
                  | "eng"   `T.isInfixOf` x                        = "en"
                  | otherwise                                      = "fi, en, se"

        fiLangs = case Map.lookup colLang vals of
                      Just x  -> x -- T.replace "fi" "suomi" $ T.replace "en" "englanti" $ T.replace "se" "ruotsi" x
                      Nothing -> "?"

-- | Accumulate a category to list of categories based on what categories
-- cannot overlap
accumCategory :: Config -> Category -> [Category] -> [Category]
accumCategory Config{..} c cs = case L.findIndex (any (`T.isPrefixOf` c)) categories of
    Nothing -> error $ "Unknown category: " ++ show c
    Just i  -> L.deleteFirstsBy T.isPrefixOf cs (f i) ++ [c]
    where f i = concat $ L.drop i categories

toCategory :: Config -> Text -> Maybe Category
toCategory Config{..} t = do
    guard $ t /= "\160" && t /= "syksy" && t /= "kevät"
    guard $ isJust $ L.find (`T.isInfixOf` t) $ concat categories
    return $ normalize t

catAt :: Config -> Int -> Course -> Maybe Text
catAt Config{..} n (cats, _) = case [ c | c <- cats, cr <- categories !! n, cr `T.isPrefixOf` c ] of
                                   x:_ -> Just x
                                   _   -> Nothing

catGroup :: Config -> Int -> Course -> Course -> Bool
catGroup cnf n = (==) `on` catAt cnf n

getThing :: Text -> Course -> Text
getThing k c = fromMaybe (traceShow ("Key not found" :: String, k, c) $ "Key not found: " <> k) $ getThingMaybe k c

getThingMaybe :: Text -> Course -> Maybe Text
getThingMaybe k (_, c) = Map.lookup k c

getThingLang :: I18N -> Lang -> Text -> Course -> Text
getThingLang db lang key c = fromMaybe (getThing key c) $ getThingMaybe (toLang db lang key) c

-- * Get source

-- | Fetch a confluence doc by id.
getData :: String -> M XML.Document
getData pid = do
    Config{..} <- ask
    xs         <- lift getArgs
    let parseSettings = XML.def { XML.psDecodeEntities = XML.decodeHtmlEntities }
        file          = "/tmp/" <> pid <> ".html"
    lift $ case xs of
        ["fetch"] -> XML.parseLBS_ parseSettings <$> simpleHttp (fetchUrl ++ pid)
        ["file"]  -> XML.parseText_ parseSettings . LT.pack . foldl1 (.) regexes <$> readFile file
        _         -> putStrLn "Usage: opetussivut < fetch | file >" >> exitFailure

-- * Parse doc

parseTable :: XML.Document -> M Table
parseTable doc = head . catMaybes . findTable (fromDocument doc) <$> ask

findTable :: Cursor -> Config -> [Maybe Table]
findTable c cnf = map ($| processTable cnf) (c $.// attributeIs "class" "confluenceTable" :: [Cursor])

getHeader :: Cursor -> Maybe Header
getHeader c = return x <* guard (not $ T.null x)
  where x = T.toLower . normalize $ T.unwords (c $// content)

processTable :: Config -> Cursor -> Maybe Table
processTable cnf c = case cells of
    _ : header : xs ->
        let headers       = mapMaybe getHeader header
            (_, mcourses) = L.mapAccumL (getRow cnf headers) [] xs
        in Just $ Table (unsafePerformIO getCurrentTime) headers (catMaybes mcourses)
    _ -> Nothing
  where
    cells = map ($/ element "td") (c $// element "tr")

-- | A row is either a category or course
getRow :: Config -> [Header] -> [Category] -> [Cursor] -> ([Category], Maybe Course)
getRow cnf@Config{..} hs cats cs = map (T.unwords . ($// content)) cs `go` ((cs !! 1 $| attribute "class") !! 0)
    where go []        _       = error "Encountered an empty row in the table!"
          go (mc : vs) classes = case toCategory cnf mc of
                Just cat                        -> (accumCategory cnf cat cats, Nothing)
                Nothing | null vs               -> (cats, Nothing)
                        | T.null (normalize mc) -> (cats, Just $ toCourse cnf cats hs (classCur `T.isInfixOf` classes) vs)
                        | otherwise             -> (cats, Just $ toCourse cnf cats hs (classCur `T.isInfixOf` classes) vs)
