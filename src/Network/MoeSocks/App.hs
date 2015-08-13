{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ExistentialQuantification #-}

module Network.MoeSocks.App where

import Control.Concurrent
import Control.Lens
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader hiding (local)
import Control.Monad.Writer hiding (listen)
import Data.Aeson hiding (Result)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy (toStrict)
import Data.Text (Text)
import Data.Text.Lens
import Data.Text.Strict.Lens (utf8)
import Network.MoeSocks.Config
import Network.MoeSocks.Constant
import Network.MoeSocks.Helper
import Network.MoeSocks.Type
import Network.MoeSocks.TCP
import Network.MoeSocks.UDP
import Network.Socket hiding (send, recv, recvFrom, sendTo)
import Network.Socket.ByteString
import OpenSSL (withOpenSSL)
import OpenSSL.EVP.Cipher (getCipherByName)
import Prelude hiding ((-), take)
import System.Log.Formatter
import System.Log.Handler.Simple
import System.Log.Logger
import qualified Data.HashMap.Strict as H
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified System.IO as IO
import qualified System.Log.Handler as LogHandler


parseConfig :: Text -> MoeMonadT MoeConfig
parseConfig aFilePath = do
  _configFile <- io - TIO.readFile - aFilePath ^. _Text

  let 
      fromShadowSocksConfig :: [(Text, Value)] -> [(Text, Value)]
      fromShadowSocksConfig _configList = 
        let fixes =
              [
                ("server", "remote")
              , ("server_port", "remotePort")
              , ("local_address", "local")
              , ("local_port", "localPort")
              ]

        in
        foldl (flip duplicateKey) _configList fixes

      fromSS :: [(Text, Value)] -> [(Text, Value)]
      fromSS = fromShadowSocksConfig


  let _v = decodeStrict - review utf8 _configFile :: Maybe Value

      fixConfig :: Value -> Value
      fixConfig (Object _obj) =
          Object - 
            _obj 
                & H.toList 
                & fromSS 
                & over (mapped . _1) (T.cons '_')  
                & H.fromList
      fixConfig _ = Null
  


      
      formatConfig :: Value -> Value
      formatConfig (Object _obj) =
          Object -
            _obj
                & H.toList 
                & over (mapped . _1) T.tail 
                & H.fromList
      formatConfig _ = Null

      filterEssentialConfig :: Value -> Value
      filterEssentialConfig (Object _obj) =
          Object -
            foldl (flip H.delete) _obj - 
              [
                "_remote"
              , "_remotePort"
              , "_local"
              , "_localPort"
              , "_password"
              ]
          
      filterEssentialConfig _ = Null

      mergeConfigObject :: Value -> Value -> Value
      mergeConfigObject (Object _x) (Object _y) =
          Object - _x `H.union` _y
      mergeConfigObject _ _ = Null


      optionalConfig = filterEssentialConfig - toJSON defaultMoeConfig
      
      _maybeConfig = _v 
                      >>= decode 
                          . encode 
                          . flip mergeConfigObject optionalConfig
                          . fixConfig 

  let 
      showConfig :: MoeConfig -> ByteString
      showConfig = 
                      toStrict 
                    . encode 
                    . formatConfig 
                    . toJSON 


  case _maybeConfig of
    Nothing -> do
      let _r = 
            execWriter - do
              tell "\n\n"
              tell "Failed to parse configuration file\n"
              tell "Example: \n"

              let configBS :: ByteString  
                  configBS = showConfig defaultMoeConfig
              
              tell - configBS ^. utf8 <> "\n"

      throwError - _r ^. _Text 

    Just _config -> do
      let configStr = showConfig _config ^. utf8 . _Text :: String
      io - puts - "Using config: " <> configStr
      pure - _config 
              

initLogger :: Priority -> IO ()
initLogger aLevel = do
  stdoutHandler <- streamHandler IO.stdout DEBUG
  let formattedHandler = 
          LogHandler.setFormatter stdoutHandler -
            simpleLogFormatter "$time $msg"

  updateGlobalLogger rootLoggerName removeHandler

  updateGlobalLogger "moe" removeHandler
  updateGlobalLogger "moe" - addHandler formattedHandler
  updateGlobalLogger "moe" - setLevel aLevel

data AppType = TCP_App | UDP_App 
  deriving (Show, Eq)

moeApp:: MoeMonadT ()
moeApp = do
  _options <- ask 
  io - initLogger - _options ^. verbosity
  
  io - puts - show _options
  
  _config <- parseConfig - _options ^. configFile
  let _c = _config

  let _method = _config ^. method . _Text

  when (_method /= "none") - do
    _cipher <- io - withOpenSSL - getCipherByName _method

    case _cipher of
      Nothing -> throwError - "Invalid method '" 
                              <> _method
                              <> "' in "
                              <> _options ^. configFile . _Text
      Just _ -> pure ()

  let localAppBuilder :: AppType -> String -> 
                          (ByteString -> (Socket, SockAddr) -> IO ()) -> 
                          (Socket, SockAddr) -> IO ()
      localAppBuilder aAppType aID aHandler s = 
        logSA "L loop" (pure s) - \(_localSocket, _localAddr) -> do
          _say - "L " <> aID <> ": nyaa!"
            
          setSocketOption _localSocket ReuseAddr 1
          bindSocket _localSocket _localAddr
          
          case aAppType of
            _TCP_App -> do
              listen _localSocket maxListenQueue

              let handleLocal _socket = do
                    _s@(_newSocket, _newSockAddr) <- accept _socket
                    setSocketCloseOnExec _newSocket
                    -- send immediately!
                    setSocketOption _socket NoDelay 1 
                    
                    forkIO - catchExceptAsyncLog "L TCP thread" - 
                              logSA "L TCP client socket" (pure _s) -
                                aHandler ""

              forever - handleLocal _localSocket

            _UDP_App -> do
              let handleLocal = do
                    (_msg, _sockAddr) <- 
                        recvFrom _localSocket _ReceiveLength

                    puts - "L UDP: " <> show _msg
                    
                    let _s = (_localSocket, _sockAddr)

                    forkIO - catchExceptAsyncLog "L UDP thread" - 
                                aHandler _msg _s

              forever handleLocal
              

  let localSocks5App :: (Socket, SockAddr) -> IO ()
      localSocks5App = localAppBuilder TCP_App "socks5" - 
                            local_Socks5_RequestHandler _config

      showForwarding :: Forward -> String
      showForwarding (Forward _localPort _remoteHost _remotePort) =
                          "["
                      <> show _localPort 
                      <> " -> " 
                      <> _remoteHost ^. _Text
                      <> ":"
                      <> show _remotePort
                      <> "]"

      forward_TCP_App :: Forward -> (Socket, SockAddr) 
                                -> IO ()
      forward_TCP_App _f _s = do
        let _m = showForwarding _f
        localAppBuilder TCP_App  ("TCP forwarding " <> _m)
                                (local_TCP_ForwardRequestHandler _config _f) 
                                _s

      forward_UDP_App :: Forward -> (Socket, SockAddr) -> IO ()
      forward_UDP_App _f _s = do
        let _m = showForwarding _f 
        localAppBuilder UDP_App  ("UDP forwarding " <> _m)
                                (local_UDP_ForwardRequestHandler _config _f) 
                                _s
      
  let remote_TCP_App :: (Socket, SockAddr) -> IO ()
      remote_TCP_App s = logSA "R loop" (pure s) -
        \(_remoteSocket, _remoteAddr) -> do
          _say "R TCP: nyaa!"

          setSocketOption _remoteSocket ReuseAddr 1
          bindSocket _remoteSocket _remoteAddr

          {-let _maximum_number_of_queued_connection = 1 :: Int-}

          listen _remoteSocket maxListenQueue

          let handleRemote _socket = do
                (_newSocket, _) <- accept _socket
                setSocketCloseOnExec _newSocket
                -- send immediately!
                setSocketOption _socket NoDelay 1 
                
                forkIO - catchExceptAsyncLog "R thread" - 
                            logSocket "R remote socket" (pure _newSocket) -
                              remote_TCP_RequestHandler _config 

          forever - handleRemote _remoteSocket

  let remote_UDP_App :: (Socket, SockAddr) -> IO ()
      remote_UDP_App s = logSA "R loop" (pure s) -
        \(_remoteSocket, _remoteAddr) -> do
          _say "R UDP: nyaa!"

          setSocketOption _remoteSocket ReuseAddr 1
          bindSocket _remoteSocket _remoteAddr

          let handleRemote = do
                (_msg, _sockAddr) <- recvFrom _remoteSocket _ReceiveLength

                puts - "R UDP: " <> show _msg

                let _s = (_remoteSocket, _sockAddr)


                forkIO - catchExceptAsyncLog "R thread" - 
                            remote_UDP_RequestHandler _config _msg _s

                

          forever handleRemote


  let 
      remoteRun :: IO ()
      remoteRun = do
        let __TCP_App = foreverRun - catchExceptAsyncLog "R TCP app" - do
              getSocket (_c ^. remote) (_c ^. remotePort) Stream
                >>= remote_TCP_App 

        let __UDP_App = foreverRun - catchExceptAsyncLog "R UDP app" - do
              getSocket (_c ^. remote) (_c ^. remotePort) Datagram
                >>= remote_UDP_App 

        waitBoth __TCP_App __UDP_App

          
        
      localRun :: IO ()
      localRun = do
        let _forward_TCP_Apps = do
              forM_ (_options ^. forwardTCP) - \forwarding -> forkIO - do
                  foreverRun - catchExceptAsyncLog "L TCPForwarding app" - do
                    getSocket (_c ^. local) 
                      (forwarding ^. forwardLocalPort) 
                      Stream
                    >>= forward_TCP_App forwarding
          
        let _forward_UDP_Apps = do
              forM_ (_options ^. forwardUDP) - \forwarding -> forkIO - do
                  foreverRun - catchExceptAsyncLog "L UDPForwarding app" - do
                    getSocket (_c ^. local) 
                      (forwarding ^. forwardLocalPort) 
                      Datagram
                    >>= forward_UDP_App forwarding
        
        let _socks5App = foreverRun - catchExceptAsyncLog "L socks5 app" - do
              getSocket (_c ^. local) (_c ^. localPort) Stream
                >>= localSocks5App 

        _forward_TCP_Apps
        _forward_UDP_Apps
        _socks5App

      debugRun :: IO ()
      debugRun = do
        catchExceptAsyncLog "Debug app" - do
          waitBothDebug
            (Just "localRun", localRun)
            (Just "remoteRun", remoteRun)

  io - case _options ^. runningMode of
    DebugMode -> debugRun
    RemoteMode -> remoteRun
    LocalMode -> localRun

