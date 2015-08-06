{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}

module Network.MoeSocks.Helper where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import Data.Attoparsec.ByteString
import Data.Binary
import Data.Binary.Put
import Data.ByteString (ByteString)
import Data.Maybe
import Data.Monoid
import Data.Text (Text)
import Data.Text.Lens
import Data.Text.Strict.Lens (utf8)
import Network.MoeSocks.Internal.ShadowSocks.Encrypt
import Network.Socket hiding (send, recv)
import Network.Socket.ByteString
import Prelude hiding (take, (-)) 
import System.IO.Unsafe (unsafePerformIO)
import System.Log.Logger
import System.Posix.IO (FdOption(CloseOnExec), setFdOption)
import qualified Data.ByteString as S
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as LB

-- BEGIN backports

infixr 0 -
(-) :: (a -> b) -> a -> b
(-) = ($)

-- END backports

_TBQueue_Size :: Int
_TBQueue_Size = 16

io :: (MonadIO m) => IO a -> m a
io = liftIO

flip4 :: (a, b, c, d) -> (d, c, b, a)
flip4 (_a, _b, _c, _d) = (_d, _c, _b, _a)

boolToMaybe :: Bool -> Maybe ()
boolToMaybe True = Just ()
boolToMaybe False = Nothing

syncLock :: MVar ()
syncLock = unsafePerformIO - newEmptyMVar

sync :: IO a -> IO a
sync aIO = do
  putMVar syncLock ()
  aIO <* takeMVar syncLock

puts :: String -> IO ()
puts = sync . debugM "moe" . ("😽  " <>)

pute :: String -> IO ()
pute = sync . errorM "moe" . ("😾  " <>)

_log :: String -> IO ()
_log = sync . infoM "moe" . ("😺  " <>)

_say :: String -> IO ()
_say = sync . noticeM "moe" . ("😼  " <>)

puteT :: Text -> IO ()
puteT = pute . view _Text

showBytes :: ByteString -> String
showBytes = show . S.unpack

      
logClose :: String -> Socket -> IO ()
logClose aID aSocket = do
  pure aID
  puts - "Closing socket " <> aID
  close aSocket 

logSocketWithAddress :: String -> IO (Socket, SockAddr) -> 
                        ((Socket, SockAddr) -> IO a) -> IO a
logSocketWithAddress aID _init f = do
  catch (bracket _init (logClose aID . fst) f) - 
      \(e :: SomeException) -> do
      pute - "logSocket: Exception in " <> aID <> ": " <> show e
      throw e

logSA:: String -> IO (Socket, SockAddr) -> 
                        ((Socket, SockAddr) -> IO a) -> IO a
logSA = logSocketWithAddress

logSocket :: String -> IO Socket -> (Socket -> IO a) -> IO a
logSocket aID _init f =
  catch (bracket _init (logClose aID) f) - \e -> do
      pute - "Exception in " <> aID <> ": " <> show (e :: SomeException)
      throw e

catchExceptAsyncLog :: String -> IO a -> IO ()
catchExceptAsyncLog aID aIO = catches (() <$ aIO) 
                [ 
                  Handler - \(e :: AsyncException) -> do
                            pute - "ASyncException in " 
                                    <> aID
                                    <> " : " <> show e
                            throw e
                , Handler - \(e :: SomeException) -> 
                            pute - "CatcheAll in "
                                    <> aID
                                    <> " : " <> show e
                ]

catchIO:: String -> IO a -> IO ()
catchIO aID aIO = catch (() <$ aIO) - \e ->
                pute - "IOError in " <> aID <> ": " 
                  <> show (e :: IOException)
                

wrapIO :: (Maybe String, IO c) -> IO ()
wrapIO (s,  _io) = do
  pure s
  {-forM_ s - puts . ("+ " <>)-}
  catchIO (fromMaybe "" s) _io 
  {-catch  (() <$ _io) - \(e :: IOException) -> pure ()-}
    {-<* (forM_ s - puts . ("- " <>))-}
                
{-waitFirst :: IO () -> IO () -> IO ()-}
{-waitFirst = runWait True False-}

{-waitFirstDebug :: (Maybe String, IO ()) -> (Maybe String, IO ()) -> IO ()-}
{-waitFirstDebug = runWaitDebug True False-}

waitBoth :: IO () -> IO () -> IO ()
waitBoth = runWait True True

waitBothDebug :: (Maybe String, IO ()) -> (Maybe String, IO ()) -> IO ()
waitBothDebug = runWaitDebug True True

{-waitNone :: IO () -> IO () -> IO ()-}
{-waitNone = runWait False False-}

{-waitNoneDebug :: (Maybe String, IO ()) -> (Maybe String, IO ()) -> IO ()-}
{-waitNoneDebug = runWaitDebug False False-}

runWait :: Bool -> Bool -> IO () -> IO () -> IO ()
runWait _waitX _waitY x y = do
  runWaitDebug _waitX _waitY (Nothing, x) (Nothing, y)

runWaitDebug :: Bool -> Bool -> (Maybe String, IO ()) -> 
                          (Maybe String, IO ()) -> IO ()
runWaitDebug _waitX _waitY x y = do
  let _x = wrapIO x
      _y = wrapIO y

      _xID = x ^. _1 & fromMaybe ""
      _yID = y ^. _1 & fromMaybe ""
      _hID = _xID <> " / " <> _yID

  let _init = do
        _threadXDone <- newEmptyMVar
        _threadYDone <- newEmptyMVar
        xThreadID <-
          forkFinally _x -
             const - putMVar _threadXDone ()

        yThreadID <- 
          forkFinally _y - const - do
            when (not _waitX) - do
              _threadXRunning <- isEmptyMVar _threadXDone
              when _threadXRunning - killThread xThreadID 
              puts - "killing thread X: " <> _xID
            
            putMVar _threadYDone ()

        return ((_threadXDone, xThreadID), (_threadYDone, yThreadID))

  let handleError ((_, xThreadID), (_, yThreadID)) = do
        puts - "handleError for " <> _hID 
        pure xThreadID
        pure yThreadID
        pure ()
        killThread yThreadID
        killThread xThreadID

  let action ((_threadXDone, _), (_threadYDone, yThreadID)) = do
        catchExceptAsyncLog _hID - do
          puts - "waiting for first: " <> _xID
          takeMVar _threadXDone 

          when (not _waitY) - do
            _threadYRunning <- isEmptyMVar _threadYDone
            when _threadYRunning - killThread yThreadID
            puts - "killing thread Y: " <> _yID

          puts - "waiting for second: " <> _yID
          takeMVar _threadYDone
          puts - "All done for " <> _hID

  bracketOnError 
    _init
    handleError
    action

getSocket :: (Integral i, Show i) => Text -> i -> SocketType ->
                                      IO (Socket, SockAddr)
getSocket aHost aPort aSocketType = do
    maybeAddrInfo <- firstOf folded <$>
                  getAddrInfo (Just hints) 
                              (Just - aHost ^. _Text) (Just - show aPort)

    case maybeAddrInfo of
      Nothing -> error - "Error in getSocket for: " <> aHost ^. _Text 
                              <> ":" <> show aPort
      Just addrInfo -> do
          let family     = addrFamily addrInfo
          let socketType = addrSocketType addrInfo
          let protocol   = addrProtocol addrInfo
          let address    = addrAddress addrInfo

          _socket <- socket family socketType protocol
          setSocketCloseOnExec _socket

          -- send immediately!
          setSocketOption _socket NoDelay 1 

          {-puts - "Getting socket: " <> show address-}

          pure (_socket, address)
          
  where
    hints = defaultHints {
              addrFlags = [AI_ADDRCONFIG, AI_NUMERICSERV]
            , addrSocketType = aSocketType
            , addrFamily = AF_INET
            }

builder_To_ByteString :: B.Builder -> ByteString
builder_To_ByteString = LB.toStrict . B.toLazyByteString

type Cipher = ByteString -> IO ByteString 

getCipher :: Text -> Text -> IO (Cipher, Cipher)
getCipher method password =
  getEncDec method (review utf8 password)


fromWord8 :: forall t. Binary t => [Word8] -> t
fromWord8 = decode . runPut . mapM_ put

portPairToInt :: (Word8, Word8) -> Int
portPairToInt = fromIntegral . portPairToWord16 
  where
    portPairToWord16 :: (Word8, Word8) -> Word16
    portPairToWord16 = decode . runPut . put 

duplicateKey :: (Eq a) => (a, a) -> [(a, b)] -> [(a, b)]
duplicateKey (_from, _to) l = 
  case lookup _from l of
    Nothing -> l
    Just v -> (_to,v) : l


recv_ :: Socket -> IO ByteString
recv_ = flip recv 4096

send_ :: Socket -> ByteString -> IO ()
send_ = sendAll

sendBuilder :: TBQueue (Maybe ByteString) -> B.Builder -> IO ()
sendBuilder _queue = 
  atomically . writeTBQueue _queue . Just . builder_To_ByteString

sendBuilderEncrypted ::  TBQueue (Maybe ByteString) -> 
                          (ByteString -> IO ByteString) -> B.Builder -> IO ()
sendBuilderEncrypted _queue _encrypt x = 
  atomically . writeTBQueue _queue . Just =<< 
                                      _encrypt (builder_To_ByteString x)

-- | An exception raised when parsing fails.
data ParseException = ParseException String

instance Show ParseException where
    show (ParseException s) = "Parse exception: " ++ s

instance Exception ParseException

parseSocket :: String -> ByteString -> (ByteString -> IO ByteString) ->
                  Parser a -> Socket -> IO (ByteString, a)
parseSocket aID _partial _decrypt aParser = parseSocketWith aID - parse aParser
  where
    parseSocketWith :: String -> (ByteString -> Result a) ->
                        Socket -> IO (ByteString, a)
    parseSocketWith _id _parser _socket = do
      _rawBytes <- recv_ _socket
      {-puts - "rawBytes: " <> show _rawBytes-}
      _bytes <- _decrypt _rawBytes

      let r =  _parser - _partial <> _bytes
      case r of
        Done i _r -> pure (i, _r)
        Fail _ _ msg -> throwIO - ParseException -
                    "Failed to parse " <> _id <> ": " <> msg
        Partial _p -> parseSocketWith _id _p _socket

produceLoop :: String -> Socket -> TBQueue (Maybe ByteString) -> 
              (ByteString -> IO ByteString) -> IO ()
produceLoop aID aSocket aTBQueue f = 
  onException _produce - do
    atomically - writeTBQueue aTBQueue Nothing

  where
    _produce = do
      _r <- recv_ aSocket `catch` \(e :: IOException) -> 
              do
                puts - aID <> ": " <> show e
                throw e

      if (_r & isn't _Empty) 
        then do
          f _r >>= atomically . writeTBQueue aTBQueue . Just
          _produce 
        else do
          atomically - writeTBQueue aTBQueue Nothing

consumeLoop :: String -> Socket -> TBQueue (Maybe ByteString) -> IO ()
consumeLoop aID aSocket aTBQueue = _consume 
  where 
    _consume = do
      _r <- atomically -readTBQueue aTBQueue 
      case _r of
        Nothing -> do
                      pure ()
        Just _data -> do
                      (send_ aSocket _data >> _consume) `catch`
                        \(e :: IOException) -> do
                            puts - aID <> ": " <> show e
                            throw e



-- Copied and slightly modified from: 
-- https://github.com/mzero/plush/blob/master/src/Plush/Server/Warp.hs
setSocketCloseOnExec :: Socket -> IO ()
setSocketCloseOnExec aSocket =
    setFdOption (fromIntegral $ fdSocket aSocket) CloseOnExec True
