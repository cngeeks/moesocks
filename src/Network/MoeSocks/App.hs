{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE DeriveGeneric #-}

module Network.MoeSocks.App where

import Control.Lens
import Prelude ((.))
import Air.Env hiding ((.), has, take, puts) 

import Network.Socket
import Control.Monad
import Control.Applicative
import System.Posix.Signals
import Control.Exception
import System.IO
import System.IO.Streams.Network
import qualified System.IO.Streams as Stream
import System.IO.Streams.Debug
import System.IO.Streams.Attoparsec
import System.IO.Streams.ByteString
import Data.Word
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as LB
import Data.ByteString (ByteString)
import Data.Monoid
import Control.Concurrent
import System.IO.Unsafe
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Builder.Extra as BE

import Data.Attoparsec.ByteString
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Strict.Lens as TS
import Data.Text.Lens

import Network.MoeSocks.Config
import Network.MoeSocks.Helper
import Network.MoeSocks.Type
import Network.MoeSocks.Constant
import Network.MoeSocks.BuilderAndParser

import Data.ByteString.Lens
import System.Random
import qualified Prelude as P
import "cipher-aes" Crypto.Cipher.AES
import Data.Maybe

import Options.Applicative hiding (Parser)
import qualified Options.Applicative as O
{-import Data.Aeson.Lens-}
import Data.Aeson
import Control.Monad.IO.Class

import qualified Data.HashMap.Strict as H

blockConnectForSize :: Int -> Stream.InputStream ByteString -> 
                  Stream.OutputStream ByteString -> IO ()
blockConnectForSize s p q = loop mempty
  where
    loop b = do
        m <- Stream.read p
        case m of
          Nothing -> do
            Stream.write (Just b) q
            Stream.write Nothing q
          Just x -> do
            let combined = b <> x
            if S.length combined <= s
              then do
                loop combined
              else do
                Stream.write (Just - S.take s combined) q
                loop - S.drop s combined
                
blockConnect :: Stream.InputStream ByteString -> 
                  Stream.OutputStream ByteString -> IO ()
blockConnect = blockConnectForSize - fromIntegral _PacketSize

blockGeneratorForSize :: Int -> Stream.InputStream ByteString -> 
                    Stream.Generator ByteString ()
blockGeneratorForSize s p = loop mempty
  where
    loop :: ByteString -> Stream.Generator ByteString ()
    loop b = do
        m <- liftIO - Stream.read p
        case m of
          Nothing -> do
            Stream.yield b

          Just x -> do
            let combined = b <> x
            if S.length combined <= s
              then do
                loop combined
              else do
                Stream.yield - S.take s combined
                loop - S.drop s combined
                            
blockGenerator :: Stream.InputStream ByteString -> 
                    Stream.Generator ByteString ()
blockGenerator = blockGeneratorForSize (fromIntegral _PacketSize)
                  
builder_To_ByteString :: B.Builder -> ByteString
builder_To_ByteString = LB.toStrict . B.toLazyByteString

localRequestHandler:: MoeConfig -> (Socket, SockAddr) -> IO ()
localRequestHandler config (_s, aSockAddr) = withSocket _s - \aSocket -> do
  puts - "Connected: " + show aSockAddr

  (inputStream, outputStream) <- socketToStreams aSocket


  let socksVersion = 5
      socksHeader = word8 socksVersion
  
  let greetingParser = do
        socksHeader
        let maxNoOfMethods = 5
        _numberOfAuthenticationMethods <- satisfy (<= maxNoOfMethods)

        ClientGreeting <$>
          count (fromIntegral _numberOfAuthenticationMethods) anyWord8

  let connectionParser = do
        socksHeader
        requestParser

  tryParse - do
    r <- parseFromStream greetingParser inputStream
    puts - show r 
    if not - _No_authentication `elem` (r ^. authenticationMethods)
      then do
        pute - "Client does not support 0x00: No authentication method"
        sClose aSocket

      else do
        pushStream outputStream - B.word8 socksVersion
                                <> B.word8 _No_authentication


        conn <- parseFromStream connectionParser inputStream
        puts - show conn

        _remoteSocket <- socket AF_INET Stream defaultProtocol
        
        withSocket _remoteSocket - \_remoteSocket -> do
          tryAddr (config ^. remote) (config ^. remotePort) - \_remoteAddr -> do
            connect _remoteSocket _remoteAddr

            let handleLocal _remoteSocket = do
                  let
                    write x = Stream.write (Just - x) outputStream
                    push = write . S.singleton

                  push socksVersion
                  push _Request_Granted 
                  push _ReservedByte

                  write - builder_To_ByteString -
                      addressTypeBuilder (conn ^. addressType)

                  traverseOf both push - conn ^. portNumber

                  (remoteInputStream, remoteOutputStream) <- 
                    socketToStreams _remoteSocket

                  _stdGen <- newStdGen

                  let _iv = S.pack - P.take _BlockSize - randoms _stdGen
                  puts - "local  IV: " <> show _iv
                  
                  pushStream remoteOutputStream - B.byteString _iv
                  
                  let
                      _aesKey = aesKey config
                      _encrypt = encryptCTR _aesKey _iv
                      _decrypt = decryptCTR _aesKey _iv
                  
                  encryptedRemoteOutputStream <- 
                    Stream.contramap _encrypt remoteOutputStream


                  let 
                      _header = requestBuilder conn
                      _headerBlock = clamp _PacketSize -
                                      builder_To_ByteString _header

                  {-puts - "headerStr______: " <> showBytes  _headerBlock-}

                  Stream.write (Just _headerBlock) -
                    encryptedRemoteOutputStream

                  inputBlockStream <- pure inputStream
                  
                  inputStreamDebug <- debugInputBS "LI:" Stream.stderr inputStream
                  outputStreamDebug <- debugOutputBS "LO:" Stream.stderr outputStream
                  
                  inputBlockStreamDebug <- debugInputBS "LIB:" Stream.stderr 
                                    inputBlockStream

                  decryptedRemoteInputStream <-
                    Stream.map _decrypt remoteInputStream
                  
                  decryptedRemoteInputBlockStream <-
                    Stream.map _decrypt =<<
                      takeBytes _PacketSize remoteInputStream

                  waitBoth
                    (Stream.connect inputBlockStreamDebug encryptedRemoteOutputStream)
                    (Stream.connect decryptedRemoteInputStream outputStreamDebug)
                  

            safeSocketHandler "Local Request Handler" 
              handleLocal _remoteSocket


remoteRequestHandler:: MoeConfig -> (Socket, SockAddr) -> IO ()
remoteRequestHandler aConfig (_s, aSockAddr) = withSocket _s - \aSocket -> do
  puts - "Remote Connected: " + show aSockAddr
  (remoteInputStream, remoteOutputStream) <- socketToStreams aSocket

  tryParse - do
    _iv <- parseFromStream (take _BlockSize) remoteInputStream

    puts - "remote IV: " <> show _iv

    let 
        _aesKey = aesKey aConfig
        _encrypt = encryptCTR _aesKey _iv
        _decrypt = decryptCTR _aesKey _iv
    
    encryptedRemoteOutputStream <- 
      Stream.contramap _encrypt remoteOutputStream

    decryptedRemoteInputStream <-
      Stream.map _decrypt remoteInputStream
    
    _headerBlock <- readExactly (fromIntegral _PacketSize)
                          decryptedRemoteInputStream

    _clientRequest <- 
      case eitherResult - parse requestParser _headerBlock of
        Left err -> throwIO - ParseException err
        Right r -> pure r
    
    let
        connectTarget :: ClientRequest -> IO Socket
        connectTarget _clientRequest = do

          let portNumber16 = fromWord8 - toListOf both 
                              (_clientRequest ^. portNumber) :: Word16
          
          let addressType_To_SockAddr :: ClientRequest -> SockAddr
              addressType_To_SockAddr aClientRequest =
                case aClientRequest ^. addressType of
                  IPv4_address _address -> SockAddrInet 
                                            (fromIntegral portNumber16)
                                            (fromWord8 - reverse _address)

                  Domain_name x -> SockAddrUnix -  x ^. TS.utf8 . _Text
                  IPv6_address xs -> 
                                      let rs = reverse xs
                                      in
                                      SockAddrInet6 
                                        (fromIntegral portNumber16)
                                        0
                                        ( fromWord8 - P.take 4 - rs
                                        , fromWord8 - P.drop 4 - P.take 4 - rs
                                        , fromWord8 - P.drop 8 - P.take 4 - rs
                                        , fromWord8 - P.drop 12 - rs
                                        )
                                        0
          
          let _socketAddr = addressType_To_SockAddr _clientRequest
          
              connectionType_To_SocketType :: ConnectionType -> SocketType
              connectionType_To_SocketType TCP_IP_stream_connection = Stream
              connectionType_To_SocketType TCP_IP_port_binding = NoSocketType
              connectionType_To_SocketType UDP_port = Datagram
                 
              

          _targetSocket <- initSocketForType _socketAddr -
                              connectionType_To_SocketType -
                              _clientRequest ^. connectionType
          
          puts - "Connecting Target: " <> show _socketAddr
          connect _targetSocket _socketAddr
          pure - _targetSocket

    _targetSocket <- connectTarget _clientRequest
    
    withSocket _targetSocket - \_targetSocket -> do
      let 
          handleTarget _targetSocket = do
            (targetInputStream, targetOutputStream) <- 
              socketToStreams _targetSocket

            targetOutputStream <- debugOutputBS "RO:" Stream.stderr 
              targetOutputStream

            targetInputStream <- debugInputBS "RI:" Stream.stderr 
              targetInputStream
            
            {-decryptedRemoteInputStream <- -}
                {-takeExactly _PacketSize decryptedRemoteInputStream-}

            {-targetInputStream <--}
                {-takeBytes _PacketSize targetInputStream-}

            decryptedRemoteInputBlockStream <-
              Stream.map _decrypt =<< takeBytes _PacketSize remoteInputStream
            
            decryptedRemoteInputBlockStream <-
              Stream.map _decrypt =<< takeBytes _PacketSize remoteInputStream
            
            waitBoth
              (Stream.connect decryptedRemoteInputStream targetOutputStream)
              (Stream.connect targetInputStream encryptedRemoteOutputStream)
            
      safeSocketHandler "Target Connection Handler" 
        handleTarget _targetSocket

parseConfig :: Text -> IO (Maybe MoeConfig)
parseConfig aConfigFile = do
  _configFile <- TIO.readFile - aConfigFile ^. _Text

  let _v = decodeStrict - review TS.utf8 _configFile :: Maybe Value
  let fixConfig :: Value -> Value
      fixConfig (Object _obj) =
          Object - 
            _obj & H.toList & over (mapped . _1) (T.cons '_')  & H.fromList
      fixConfig _ = Null

  
  let 
      _maybeConfig = (_v >>= decode . encode . fixConfig)

  case _maybeConfig of
    Nothing -> do
      pute "Failed to parse configuration file"
      pute "Example: "
      pute - show - encode defaultMoeConfig
      
      pure Nothing
    _config -> do
      pure - _config 

moeApp:: MoeOptions -> IO ()
moeApp options = do
  puts - "Options: " <> show options
  maybeConfig <- parseConfig - options ^. configFile 
  
  forM_ maybeConfig - \config -> do
    puts - show config

    let localApp :: SockAddr -> IO (Socket, Socket -> IO ())
        localApp _localAddr = do
          puts - "localAddr: " <> show _localAddr

          localSocket <- initSocket _localAddr
          setSocketOption localSocket ReuseAddr 1
          bindSocket localSocket _localAddr

          listen localSocket 1

          let handleLocal _socket = 
                accept _socket >>= 
                  fork . localRequestHandler config

              localLoop = 
                forever . safeSocketHandler "Local Connection" handleLocal

          pure (localSocket, localLoop)

    let remoteApp :: SockAddr -> IO (Socket, Socket -> IO ())
        remoteApp _remoteAddr = do
          puts - "remoteAddr: " <> show _remoteAddr

          remoteSocket <- initSocket _remoteAddr
          setSocketOption remoteSocket ReuseAddr 1
          bindSocket remoteSocket _remoteAddr
          listen remoteSocket 1

          let handleRemote _socket = 
                accept _socket >>= 
                  fork . remoteRequestHandler config

              remoteLoop = 
                forever . 
                safeSocketHandler "Remote Connection" handleRemote

          pure (remoteSocket, remoteLoop)

    let debugRun :: IO ()
        debugRun = do
          let _c = config
          tryAddr (_c ^. local) (_c ^. localPort) - \_localAddr -> do
            (localSocket, localLoop) <- localApp _localAddr

            tryAddr (_c ^. remote) (_c ^. remotePort) - \_remoteAddr -> do
              (remoteSocket, remoteLoop) <- remoteApp _remoteAddr
              catchAll - do
                safeSocketHandler "Local Socket" (\_localSocket ->
                  safeSocketHandler "Remote Socket" (\_remoteSocket ->
                    waitBoth 
                      (localLoop _localSocket) 
                      (remoteLoop _remoteSocket)
                      ) remoteSocket) localSocket

        remoteRun :: IO ()
        remoteRun = do
          let _c = config
          tryAddr (_c ^. remote) (_c ^. remotePort) - \_remoteAddr -> do
            (remoteSocket, remoteLoop) <- remoteApp _remoteAddr
            catchAll - 
              safeSocketHandler "Remote Socket" remoteLoop remoteSocket
          
        localRun :: IO ()
        localRun = do
          let _c = config
          tryAddr (_c ^. local) (_c ^. localPort) - \_localAddr -> do
            (localSocket, localLoop) <- localApp _localAddr
            catchAll - 
              safeSocketHandler "Local Socket" localLoop localSocket

    case options ^. runningMode of
      DebugMode -> debugRun
      RemoteMode -> remoteRun
      LocalMode -> localRun

    
