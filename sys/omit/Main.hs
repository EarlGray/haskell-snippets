{-# LANGUAGE TupleSections, ScopedTypeVariables #-}
import Control.Applicative
import Control.Monad
import Control.Exception as Exc
import Data.Maybe
import Data.Char
import Data.Word
import Data.Bits
import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.UTF8 as BU
import qualified Data.ByteString.Lazy.UTF8 as BLU
import Data.Binary.Get as BinGet
import Codec.Compression.Zlib as Zlib
import qualified Data.Digest.Pure.SHA as SHA
import System.IO
import System.Time
import System.Directory
import System.Environment (getArgs)
import System.Console.ANSI as TTY
import System.Exit (exitFailure, exitSuccess)
import Numeric (readHex)
import Text.Printf

maybeOr msg = maybe (error msg) id
splitBy num lst = L.unfoldr (\s -> if null s then Nothing else Just $ splitAt num s) lst

colorPutStrLn color msg = setSGR [SetColor Foreground Dull color] >> putStr msg >> setSGR [] >> putStrLn ""

type SHAHash = B.ByteString
showSHA = concatMap (printf "%02x" )
readSHA = B.pack . map (fst . head . readHex) . splitBy 2

objpathFor hash = concat ["/objects/", take 2 hash, "/", drop 2 hash]
changeFileExtension ext = reverse . (reverse ext ++) . tail . dropWhile (/= '.') . reverse

getBlob gitdir idxmaps hash = do
    isobj <- doesFileExist (gitdir ++ objpathFor hash)
    if isobj then parseBlob <$> Zlib.decompress <$> BL.readFile (gitdir ++ objpathFor hash)
    else let (idxfile, idxmap) = head $ filter (((readSHA hash) `M.member`) . snd) idxmaps
             packfile = (gitdir ++ "/objects/pack/" ++ changeFileExtension ".pack" idxfile)
             getblobinfo inf = do
                w <- getWord8
                let inf' = (inf `shiftL` 7) .|. (fromIntegral w .&. 0x3f)
                if w `testBit` 7 then getblobinfo inf' else return inf'
             getblob = do
                skip $ fst $ fromJust $ M.lookup (readSHA hash) idxmap
                inf <- getblobinfo (0 :: Int)
                let blobty = inf .&. 3
                let bloblen = inf `shiftR` 3
                blob <- BL.fromStrict <$> getByteString bloblen
                return (inf, bloblen, blobty, blob)
         in do
                putStrLn $ "offset in pack = " ++ show (M.lookup (readSHA hash) idxmap)
                (inf, bloblen, blobty, blob) <- runGet getblob <$> BL.readFile packfile
                putStrLn $ "inf = " ++ printf "0x%x" inf
                putStrLn $ "blobtype = " ++ show blobty
                putStrLn $ "bloblen  = " ++ show bloblen
                error "TODO"


parseBlob :: BL.ByteString -> (String, Int, BL.ByteString) -- blobtype, bloblen, blob
parseBlob str = let (btype, tl') = BL.break (== 0x20) str ; (slen, tl) = BL.break (== 0) tl'
                in (BLU.toString btype, read $ BLU.toString slen, BL.tail tl)

parseTreeObject :: BL.ByteString -> [(String, String, String)]
parseTreeObject = L.unfoldr parseEntry . BL.unpack -- [(mode::String, len::String, path::String)]
  where parseEntry [] = Nothing
        parseEntry bl = let (hd, (_:tl)) = splitAt (fromJust $ L.findIndex (== 0) bl) bl in
            let (mode, (_:path)) = break (== 0x20) hd ; (hsh, tl') = splitAt 20 tl
            in Just ((BU.toString . B.pack $ mode, BU.toString . B.pack $ path, showSHA hsh), tl')

prettyTreeObject :: [(String, String, String)] -> String
prettyTreeObject = unlines . map (\(mode, path, hash) -> concat [mode, " blob ", hash, "    ", path])

getIdxFile_v2 :: Get (M.Map SHAHash (Int, Word32)) -- M.Map SHAHash (Offset, CRC32)
getIdxFile_v2 = do
    indv <- replicateM 0x100 getWord32be
    let lastind = fromIntegral $ last indv
    hashv <- replicateM lastind (getByteString 20)
    crc32v <- replicateM lastind getWord32be
    offv <- map fromIntegral <$> replicateM lastind getWord32be
    -- TODO: 8b offsets
    return $ M.fromAscList $ zip hashv $ zip offv crc32v

parseIdxFile_v2 idxfile = do
    idxdata <- BL.readFile idxfile
    let (idxbody, trail) = BL.splitAt (BL.length idxdata - 20) idxdata
    when ((show $ SHA.sha1 idxbody) /= (showSHA $ BL.unpack trail)) $ error "idxfile: idx hash invalid"
    let (0xff744f63, 2, idxmap) = runGet (liftM3 (,,) getWord32be getWord32be getIdxFile_v2) idxbody
    return idxmap

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

    -- find pack files and load them
    idxfiles <- filter (L.isSuffixOf ".idx") <$> getDirectoryContents (gitdir ++ "/objects/pack")
    idxmaps <- zip idxfiles <$> forM idxfiles (parseIdxFile_v2 . ((gitdir ++ "/objects/pack/") ++))

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
            offmap <- parseIdxFile_v2 $ changeFileExtension ".idx" packfile
            let printHash (hsh, (off, crc32)) = putStrLn $ showSHA (B.unpack hsh) ++ "  " ++ show off
            when verbose $ forM_ (M.toList offmap) printHash
            offmap `seq` exitSuccess
        verifyPack `Exc.catch` (\(e :: Exc.SomeException) -> when verbose (hPrint stderr e) >> exitFailure)

      ("log":[]) -> do
        let commitHeader hdr info = words <$> (listToMaybe $ filter (L.isPrefixOf $ hdr ++ " ") info)
        let printCommit commit = do
                ("commit", _, blob) <- getBlob gitdir idxmaps commit
                let (commMeta, commMsg) = break null $ lines $ BLU.toString blob
                let (cmTZ : cmEpoch : cmAuthor) = reverse $ maybeOr "No commit author" $ commitHeader "author" commMeta
                colPutStrLn Yellow $ "commit " ++ commit
                putStrLn $ "Author:\t" ++ unwords (drop 1 . reverse $ cmAuthor)
                putStrLn $ "Date\t" ++ show (TOD (read cmEpoch) 0)
                mapM_ (putStrLn . ("    " ++)) commMsg
                putStrLn ""
                let cmPar = commitHeader "parent" commMeta
                when (isJust cmPar) $ let ["parent", parent] = fromJust cmPar in printCommit parent

        ("ref", (':':' ':path)) <- (break (== ':') . head . lines) <$> readFile (gitdir ++ "/HEAD")
        commit <- head <$> lines <$> readFile (gitdir ++ "/" ++ path)
        printCommit commit

      _ -> error "Usage: omit [cat-file|verify-pack|log]"
