import Data.Char
import Data.List (sortBy, sort, permutations, transpose, iterate, unfoldr)
import Data.Maybe (fromJust)
import Data.Function (on)

import Text.Printf
import qualified Debug.Trace as Dbg

import qualified Data.Set as S
import qualified Data.Map as M

{-
 -  Terminology:
 -    CT : ciphertext, what we have to decipher;
 -    ST : sample text, words from english dictionary;
 -    Frequency string: string containing character in order of decreasing frequency
 -              so in "seiarntolcdugpmhbyfkv"
 -                    's' is the most frequent char., 'v' - the least frequent one;
 -    decipher map: map from character to character that reflects some Caesar cipher;
 -}

type CharFreqList = [(Char, Int)]
type CharFreqMap = M.Map Char Int

type DecipherMap = M.Map Char Char
type SampleDict = S.Set String

-- String that contains different characters ordered by frequency in some other text:
type FreqString = String

-- CharFreqMap: <Character> : <How many times it's encountered>
freqmap :: String -> CharFreqMap
freqmap str = foldr iter M.empty str
  where iter item frq = M.alter (Just . maybe 1 succ) item frq

revertMap :: (Ord a, Ord b) => M.Map a b -> M.Map b a
revertMap = M.fromList . map (\(k, v) -> (v, k)) . M.toList

sortBySnd = sortBy (compare `on` snd)

lettersOnly :: CharFreqList -> CharFreqList
lettersOnly = filter (\(c, f) -> isAlpha c && isAscii c)

freqlst :: CharFreqMap -> CharFreqList
freqlst = sortBySnd . M.toList

printFreqmap fm =
  flip mapM_ (freqlst fm) $ \(item, freq) -> do
    putStrLn $ printf "%c\t%d" item freq

-- permutate only a part of string <abc> starting at <start> with length <count>
cypherAlphabetPermutations :: Int -> Int -> String -> [String]
cypherAlphabetPermutations start count abc = map (\p -> before ++ p ++ after) $ permutations middle
  where
    (before, rest) = splitAt start abc
    (middle, after) = splitAt count rest

-- generate decipher maps for all permutations of <ct_fstr> generated by cypherAlphabetPermutations
generateMaps :: (Int, Int) -> FreqString -> FreqString -> [DecipherMap]
generateMaps (start, count) ct_fstr st_fstr = map alist $ zip mutated_ctfl (repeat st_fstr)
  where mutated_ctfl = cypherAlphabetPermutations start count ct_fstr
        alist (cts, sts) = M.fromList $ zip cts sts

decipher :: DecipherMap -> String -> String
decipher cymap = map (fromJust . flip M.lookup cymap)

correctWordsCount :: SampleDict -> [String] -> Int
correctWordsCount dict ws = length $ filter (\w -> w `S.member` dict) ws

-- characters of the input sorted by frequency decreasingly
freqstring :: String -> FreqString
freqstring = map fst . reverse . lettersOnly . freqlst . freqmap

-- how many words deciphered from CT <ct> with deciph.map <dm>
--  are found in sample dictionary <ds>
ctCorrectness ds dm ct = correctWordsCount ds $ map (decipher dm) $ words ct

mapsIndexesByCorrectness :: SampleDict -> [DecipherMap] -> String -> [(Int, Int)]
mapsIndexesByCorrectness ds dms ct = reverse $ sortBySnd $ map (\(i, dm) -> (i, ctCorrectness ds dm ct)) $ zip [0,1..] dms

-- <sample freq str> <decipher map> -> <CT freq. string of the map>
freqstrByMap :: FreqString -> DecipherMap -> FreqString
freqstrByMap sfs dm = map (\c -> maybe '?' id $ M.lookup c revmap) (take (M.size dm) sfs)
  where revmap = revertMap dm

-- (<start permutation at index>, <count of characters to permutate) \
--    <ct freq str> <sample freq str> <sample dict> <CT>
-- -> [(<count of correct words for>, <a CT freq str>)]
bestGuesses :: (Int, Int) -> FreqString -> FreqString -> SampleDict -> String -> [(Int, FreqString)]
bestGuesses (start, count) cfs sfs ds ct = best
  where dms = generateMaps (start, count) cfs sfs
        bestIndexes = take 3 $ mapsIndexesByCorrectness ds dms ct
        best = map (\(i, nw) -> (nw, freqstrByMap sfs (dms !! i))) bestIndexes

-- (<correct words count>, <ct freq str>) <prev prefix> ->
--    (<length of common prefix>, <new ct freq str>)
chooseNextCtFrqStr :: [(Int, FreqString)] -> Int -> (Int, FreqString)
chooseNextCtFrqStr best prevpref = (prefLen (map snd best), newCFS)
  where newCFS = snd (best !! 0)
        prefLen ss = length $ takeWhile (\cs -> all (== head cs) cs) $ transpose ss

solveSteps :: FreqString -> FreqString -> SampleDict -> String -> [(Int, Int, FreqString)]
solveSteps cfs sfs ds ct = unfoldr iter (1, defCount, cfs)
  where
    defCount = 5
    iter (start, count, cfs) =
      if start + count > length cfs
      then Nothing
      else
        let best = bestGuesses (start, count) cfs sfs ds ct
            (pl, ncfs) = chooseNextCtFrqStr best start
            nxt = if pl == start then (pl, count + 1, ncfs) else (pl, defCount, ncfs)
        in {-Dbg.traceShow nxt $-} Just (nxt, nxt)

solve :: String -> String -> String
solve st ct =
  let ds = S.fromList $ lines st  -- dictionary set
      sfs = freqstring st   -- ST freq. string
      cfs = freqstring ct   -- CT freq. string
      (_, _, finalCFS) = last $ solveSteps cfs sfs ds ct
      decmap = M.fromList $ zip finalCFS sfs
  in unwords $ map (decipher decmap) $ words ct

main = do
  st <- readST    -- sampletext
  ct <- getContents
  putStrLn $ solve st ct

-- for GHCi
readCT = readFile "cyphertext.txt"
readST = readFile "/usr/share/dict/american-english"

decipherWords dm ct = map (decipher dm) $ words ct

printGuesses :: [(Int, String)] -> IO ()
printGuesses best =
  flip mapM_ best $ \(nwords, cfs) ->
    putStrLn $ show nwords ++ " correct : " ++ cfs
