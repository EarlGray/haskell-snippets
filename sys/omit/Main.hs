{-# LANGUAGE TupleSections, ScopedTypeVariables #-}
import Control.Applicative
import Control.Monad
import Control.Exception as Exc
import Data.Maybe
import Data.Char
import Data.Word
import Data.Bits
import qualified Data.List as L
import qualified Data.Set as S
import qualified Data.Map as M
import qualified Data.IntMap as IM
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.UTF8 as BU
import qualified Data.ByteString.Lazy.UTF8 as BLU
import Data.Binary.Get as BinGet
import Data.Binary.Put as BinPut
import Data.Algorithm.Diff as Diff
import Codec.Compression.Zlib as Zlib
import qualified Data.Digest.Pure.SHA as SHA
import System.IO
import System.Time
import System.Directory as Dir
import System.FilePath.Posix ((</>), takeDirectory, replaceExtension, makeRelative)
import System.Posix as Posix
import System.Posix.Types
import System.Environment (getArgs)
import System.Console.ANSI as TTY
import System.Exit (exitFailure, exitSuccess)
import Numeric (readHex)
import Text.Printf

int :: (Num b, Integral a) => a -> b
int = fromIntegral

bool thenb elseb cond = if cond then thenb else elseb
maybeOr msg = maybe (error msg) id
splitBy num lst = L.unfoldr (\s -> if null s then Nothing else Just $ splitAt num s) lst

colorPutStrLn color msg = setSGR [SetColor Foreground Dull color] >> putStr msg >> setSGR [] >> putStrLn ""
todFromPosix etime = TOD sec psec
  where [(sec, s')] = reads (show etime)
        psec = case reads s' of { [] -> 0; [(nsec, _)] -> 1000 * nsec; }

timespecToTOD (tv_sec, tv_nsec) = TOD (toInteger tv_sec) (1000 * (toInteger tv_nsec))
timespecFromTOD (TOD sec psec) = (fromInteger sec, fromInteger (psec `div` 1000))

type SHAHash = B.ByteString
showSHA = concatMap (printf "%02x" ) . B.unpack
readSHA = B.pack . map (fst . head . readHex) . splitBy 2

type HashInfoMap = (M.Map SHAHash (Int, Int, Word32)) -- (packOffset, packSize, crc32)
data IndexEntry = IndexEntry { indCTime::ClockTime, indMTime::ClockTime, indDev::Word32, indIno::Word32,
        indMode::Word32, indUID::Word32, indGID::Word32, indFileSize::Word32, indSHA::SHAHash,
        indFl::Word16, indFName::FilePath } deriving (Show, Eq)

objpathFor (h1:h2:hash) = concat ["/objects/", (h1:h2:[]), "/", hash]

blobify :: String -> BL.ByteString -> BL.ByteString
blobify blobty objdata = BL.append (BLU.fromString (blobty ++ " " ++ show (BL.length objdata) ++ "\0")) objdata

getBlob :: FilePath -> [(FilePath, M.Map SHAHash (Int, Int, Word32))] -> String
           -> IO (String {-type-}, Int {-len-}, BL.ByteString {-blob-})
getBlob gitdir idxmaps hash = do
    isobj <- doesFileExist (gitdir ++ objpathFor hash)
    if isobj then parseBlob <$> Zlib.decompress <$> BL.readFile (gitdir ++ objpathFor hash)
    else let (idxfile, idxmap) = head $ filter (((readSHA hash) `M.member`) . snd) idxmaps
             packfile = (gitdir ++ "/objects/pack/" ++ replaceExtension idxfile "pack")
             skipblobinfo (t, n) = getWord8 >>= ((bool (skipblobinfo (t, n+1)) (return (t, n))) . (`testBit` 7))
             blobinfo = getWord8 >>= (\w -> (if w `testBit` 7 then skipblobinfo else return) (w, 1))
             getblob blobpos blobsz = do
                skip blobpos
                (ty, skipped) <- blobinfo
                zblob <- getByteString (blobsz - skipped)
                return (ty, BL.fromStrict zblob)
         in do
             let Just (blobpos, blobsz, _) = M.lookup (readSHA hash) idxmap
             (ty, zblob) <- runGet (getblob blobpos blobsz) <$> BL.readFile packfile
             let blob = Zlib.decompress zblob
             let Just blobty = L.lookup (ty .&. 0x70) [(0x10,"commit"), (0x20,"tree"), (0x30,"blob")]
             return (blobty, int $ BL.length blob, blob)

parseBlob :: BL.ByteString -> (String, Int, BL.ByteString) -- blobtype, bloblen, blob
parseBlob str = let (btype, tl') = BL.break (== 0x20) str ; (slen, tl) = BL.break (== 0) tl'
                in (BLU.toString btype, read $ BLU.toString slen, BL.tail tl)

parseTreeObject :: BL.ByteString -> [(String, String, String)]
parseTreeObject = L.unfoldr parseEntry . BL.unpack -- [(mode::String, len::String, path::String)]
  where parseEntry [] = Nothing
        parseEntry bl = let (hd, (_:tl)) = splitAt (fromJust $ L.findIndex (== 0) bl) bl in
            let (mode, (_:path)) = break (== 0x20) hd ; (hsh, tl') = splitAt 20 tl
            in Just ((BU.toString $ B.pack mode, BU.toString $ B.pack path, showSHA $ B.pack hsh), tl')

prettyTreeObject :: [(String, String, String)] -> String
prettyTreeObject = unlines . map (\(mode, path, hash) -> concat [mode, " blob ", hash, "    ", path])

getIdxFile_v2 :: Get (M.Map SHAHash (Int, Word32))
getIdxFile_v2 = do
    indv <- replicateM 0x100 getWord32be
    let lastind = int $ last indv
    hashv <- replicateM lastind (getByteString 20)
    crc32v <- replicateM lastind getWord32be
    offv <- map int <$> replicateM lastind getWord32be
    -- TODO: 8b offsets
    return $ M.fromAscList $ zip hashv $ zip offv crc32v

parseIdxFile_v2 :: FilePath -> IO HashInfoMap -- (offset, size, crc32)
parseIdxFile_v2 idxfile = do
    idxdata <- BL.readFile idxfile
    packlen <- int <$> fileSize <$> getFileStatus (replaceExtension idxfile "pack")
    let (idxbody, trail) = BL.splitAt (BL.length idxdata - 20) idxdata
    when ((show $ SHA.sha1 idxbody) /= (showSHA $ BL.toStrict trail)) $ error "idxfile: idx hash invalid"
    let (0xff744f63, 2, idxmap') = runGet (liftM3 (,,) getWord32be getWord32be getIdxFile_v2) idxbody
    let offs' = S.fromList $ ((map fst $ M.elems idxmap') ++ [packlen - 20])
    return $ M.map (\(off, crc32) -> (off, (fromJust $ S.lookupGT off offs') - off, crc32)) idxmap'

parseIndex :: BL.ByteString -> [IndexEntry]
parseIndex dat = map makeIdxentry idxdata
  where
    ("DIRC", ver, nentries) = runGet (liftM3 (,,) (BU.toString <$> getByteString 4) getWord32be getWord32be) dat
    go nb bs = (B.break (== 0) <$> getByteString nb) >>= (\(d, z) -> (if B.null z then go 8 else return)(B.append bs d))
    getIdxEntry = liftM4 (,,,) (replicateM 10 getWord32be) (getByteString 20) getWord16be (go 2 B.empty)
    idxdata = runGet (replicateM (int nentries) getIdxEntry) (BL.drop 12 dat)
    makeIdxentry ([ctsec, ctusec, mtsec, mtusec, stdev, stino, stmode, stuid, stgid, fsize], sha, flags, fname) =
      IndexEntry (timespecToTOD (ctsec, ctusec)) (timespecToTOD (mtsec, mtusec))
                 stdev stino stmode stuid stgid fsize sha flags (BU.toString fname)
    -- read extensions -- verify SHA

dumpIndex :: M.Map FilePath IndexEntry -> BL.ByteString
dumpIndex indmap = BL.append body trailer
  where body = runPut $ do
          putByteString (BU.fromString "DIRC") >> mapM putWord32be [2, int $ M.size indmap]
          mapM (putEntry . snd) . M.toAscList . M.mapKeys BU.fromString $ indmap
          return ()
        trailer = SHA.bytestringDigest $ SHA.sha1 body
        putEntry (IndexEntry ctime mtime dev ino mod uid gid fsize sha fl fname) = do
          let ((cts, ctns), (mts, mtns)) = (timespecFromTOD ctime, timespecFromTOD mtime)
              bname = BU.fromString fname
              zpadding = 8 - ((62 + B.length bname) `rem` 8)
          mapM_ putWord32be [int cts, int ctns, int mts, int mtns, dev, ino, mod, uid, gid, fsize]
          putByteString sha >> putWord16be fl >> putByteString bname >> replicateM zpadding (putWord8 0)

groupByAscRange :: [(Int, a)] -> [[a]]
groupByAscRange = reverse . map reverse . snd . L.foldl' go (0, [[]])
  where go (n, grps@(hd:tl)) (k, v) = (k, if k == succ n then ((v : hd) : tl) else [v]:grps)

notFirst diffval = case diffval of { First _ -> False; _ -> True }
notSecond diffval = case diffval of { Second _ -> False; _ -> True }
isBoth diffval = case diffval of { Both _ _ -> True; _ -> False }

contextDiff :: Eq t => Int -> [Diff t] -> [[Diff (Int, t)]]
contextDiff nctx diff = groupByAscRange $ IM.toAscList ctxmap
  where annot (num1, num2, res) (Both ln1 ln2) = (succ num1, succ num2, Both (num1,ln1) (num2,ln2) : res)
        annot (num1, num2, res) (First ln)     = (succ num1, num2,      First (num1, ln) : res)
        annot (num1, num2, res) (Second ln)    = (num1,      succ num2, Second (num2, ln) : res)
        lnmap = IM.fromList $ zip [1..] $ reverse $ (\(_,_,e) -> e) $ L.foldl' annot (1,1,[]) diff
        isInContext num = not $ all isBoth $ catMaybes [ IM.lookup i lnmap | i <- [(num - nctx)..(num + nctx)] ]
        ctxmap = IM.foldlWithKey (\res n dv -> if isInContext n then IM.insert n dv res else res) IM.empty lnmap

printCtx [] = []
printCtx grp@((Both (n1,_) (n2,ln)):_) = (grpcaption ++ hdln):tllns
  where (len1, len2) = (length $ filter notSecond grp, length $ filter notFirst grp)
        diffln dv = case dv of { Both(_,ln) _ -> ' ':ln; First(_,ln) -> '-':ln; Second(_,ln) -> '+':ln }
        (hdln : tllns) = map diffln grp
        grpcaption = printf "@@ -%d,%d +%d,%d @@ " n1 len1 n2 len2

main = do
  argv <- getArgs
  curdir <- getCurrentDirectory
  outtty <- hIsTerminalDevice stdout
  let colPutStrLn color = if outtty then colorPutStrLn color else putStrLn

  -- search for a .git directory:
  let cpath = filter (/= "/") $ L.groupBy (\a b -> a /= '/' && b /= '/') curdir
  let parents = map ((\d -> "/"++d++"/.git") . L.intercalate "/") . takeWhile (not.null) . iterate init $ cpath
  pardirsexist <- mapM (\d -> (,d) <$> doesDirectoryExist d) parents
  let gitdir = maybe (error ".git directory not found") snd . listToMaybe . filter fst $ pardirsexist
  let workdir = takeDirectory gitdir

  index <- parseIndex <$> BL.readFile (gitdir ++ "/index")
  let indexByPath = M.fromList $ map (\ie -> (indFName ie, ie)) index

  -- find pack files and load them
  idxfiles <- filter (L.isSuffixOf ".idx") <$> getDirectoryContents (gitdir </> "objects" </> "pack")
  idxmaps <- zip idxfiles <$> forM idxfiles (parseIdxFile_v2 . ((gitdir ++ "/objects/pack/") ++))

  let lc = 7  -- longest collision, TODO

  case argv of
    ["cat-file", opt, hash] -> do
      (blobtype, bloblen, blob) <- getBlob gitdir idxmaps hash
      putStr $ maybe (error "Usage: omit cat-file [-t|-s|-p] <hash>") id $ lookup opt
        [("-t", blobtype ++ "\n"), ("-s", show bloblen ++ "\n"),
         ("-p", maybe (error "bad file") id $ lookup blobtype
            [("blob", BLU.toString blob), ("commit", BLU.toString blob),
             ("tree", prettyTreeObject $ parseTreeObject blob)]),
         ("blob", BLU.toString blob), ("tree", prettyTreeObject $ parseTreeObject blob),
         ("commit", BLU.toString blob)]

    ("verify-pack":argv') -> do
      let (verbose, packfile) = ("-v" `elem` argv', last argv')
      let verifyPack = do
              offmap <- parseIdxFile_v2 $ replaceExtension packfile "idx"
              let printHash (hsh, (off, sz, crc32)) =
                      putStrLn $ L.intercalate " " [showSHA hsh, show sz, show off]
              when verbose $ forM_ (M.toList offmap) printHash
              offmap `seq` return ()
      verifyPack `Exc.catch` (\(e :: Exc.SomeException) -> when verbose (hPrint stderr e) >> exitFailure)

    ("ls-files":argv') -> mapM_ (putStrLn . indFName) index

    ("log":[]) -> do
      let commitHeader hdr info = words <$> (listToMaybe $ filter (L.isPrefixOf $ hdr ++ " ") info)
      let printCommit commit = do
              ("commit", _, blob) <- getBlob gitdir idxmaps commit
              let (commMeta, commMsg) = break null $ lines $ BLU.toString blob
              let (cmTZ : cmEpoch : cmAuthor) =
                      reverse $ maybeOr "No commit author" $ commitHeader "author" commMeta
              colPutStrLn Yellow $ "commit " ++ commit
              putStrLn $ "Author:\t" ++ unwords (drop 1 . reverse $ cmAuthor)
              putStrLn $ "Date\t" ++ show (TOD (read cmEpoch) 0)
              mapM_ (putStrLn . ("    " ++)) commMsg
              putStrLn ""
              let cmPar = commitHeader "parent" commMeta
              when (isJust cmPar) $ let ["parent", parent] = fromJust cmPar in printCommit parent

      ("ref", (':':' ':path)) <- (break (== ':') . head . lines) <$> readFile (gitdir ++ "/HEAD")
      commit <- head <$> lines <$> readFile (gitdir </> path)
      printCommit commit

    ("diff":argv') -> do
      case argv' of
        [] -> forM_ index $ \ie -> do
                let (fname, stageSHA) = (indFName ie, (showSHA $ indSHA ie))
                workdirBlob <- BL.readFile (workdir </> fname)
                let fileSHA = show (SHA.sha1 $ blobify "blob" workdirBlob)
                when (fileSHA /= stageSHA) $ do
                  let workdirLines = map BLU.toString $ BLU.lines workdirBlob
                  ("blob", _, stagedBlob) <- getBlob gitdir idxmaps stageSHA
                  let stagedLines = map BLU.toString $ BLU.lines stagedBlob
                      diffcap = [ printf "diff --git a/%s b/%s" fname fname,
                          printf "index %s..%s %o" (take lc stageSHA) (take lc fileSHA) (indMode ie),
                          printf "--- a/%s\n+++ b/%s" fname fname ]
                      prettyDiff df = diffcap ++ (concat $ map printCtx $ contextDiff 3 df)
                  mapM_ putStrLn $ prettyDiff $ Diff.getDiff stagedLines workdirLines

        _ -> hPutStrLn stderr $ "Usage: omit diff"

    ("add":argv') -> do
      let iterargv pathidx rpath = do
            path <- Dir.canonicalizePath (curdir </> rpath)
            s <- getFileStatus path
            unless (isRegularFile s) $ fail ("not a file : " ++ rpath)
            blob <- blobify "blob" <$> BL.readFile path
            let (sha, fname) = (show $ SHA.sha1 blob, makeRelative workdir path)
                objpath = gitdir ++ objpathFor sha
                ie = IndexEntry (todFromPosix $ statusChangeTimeHiRes s) (todFromPosix $ modificationTimeHiRes s)
                      (int$deviceID s) (int$fileID s) 0x81a4 (int$fileOwner s) (int$fileGroup s) (int $ fileSize s)
                      (readSHA sha) (0x7ff .&. int (length fname)) fname
            exists <- doesFileExist objpath
            unless (exists || any (M.member (readSHA sha) . snd) idxmaps) $ do
                createDirectoryIfMissing False $ takeDirectory objpath
                BL.writeFile objpath (Zlib.compress blob)
            return $ M.insert fname ie pathidx

      pathidx <- foldM iterargv indexByPath argv'
      BL.writeFile (gitdir </> "omit_index") $ dumpIndex pathidx
      Dir.renameFile (gitdir </> "index") (workdir </> "git.index")
      Dir.renameFile (gitdir </> "omit_index") (gitdir </> "index")

    _ -> error "Usage: omit [cat-file|verify-pack|ls-files|log|add|diff]"
