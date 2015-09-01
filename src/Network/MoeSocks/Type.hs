{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}

module Network.MoeSocks.Type where

import Control.Lens
import Control.Monad.Except
import Control.Monad.Reader
import Control.Concurrent.Async
import Data.Aeson
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.IP
import Data.Word
import Data.Monoid
import GHC.Generics
import System.Log.Logger
import qualified Data.Strict as S

data ClientGreeting = ClientGreeting
  {
    _authenticationMethods :: [Word8]
  }
  deriving (Show)

makeLenses ''ClientGreeting

data ConnectionType =
    TCP_IP_StreamConnection
  | TCP_IP_PortBinding
  | UDP_Port
  deriving (Show, Eq)

data AddressType = 
    IPv4_Address (Word8, Word8, Word8, Word8)
  | DomainName Text
  | IPv6_Address [Word16]
  deriving (Show, Eq)

type Port = Int

data ClientRequest = ClientRequest
  {
    _connectionType :: ConnectionType
  , _addressType :: AddressType
  , _portNumber :: Port
  }
  deriving (Show, Eq)

makeLenses ''ClientRequest


data Config = Config
  {
    _remoteAddress :: Text
  , _remotePort :: Int
  , _localAddress :: Text
  , _localPort :: Int
  , _password :: Text
  , _method :: Text
  , _timeout :: Int
  , _tcpBufferSize :: Int -- in packets
  , _throttle :: Bool
  , _throttleSpeed :: Double
  , _obfuscationFlushBound :: Int -- should be greater then MTU
  , _fastOpen :: Bool
  , _socketOption_TCP_NOTSENT_LOWAT :: Bool
  }
  deriving (Show, Eq, Generic)

instance FromJSON Config
instance ToJSON Config

makeLenses ''Config

data RunningMode = RemoteMode | LocalMode | DebugMode
      deriving (Show, Eq)

data Verbosity = Normal | Verbose
      deriving (Show, Eq)

data Forward = Forward
  {
    _forwardLocalPort :: Port
  , _forwardTargetAddress :: Text
  , _forwardTargetPort :: Port
  }
  deriving (Show, Eq)


makeLenses ''Forward

{-data Profile =    Mac-}
                {-| Linux-}
  {-deriving (Show, Eq, Read)-}

{-makePrisms ''Profile-}

data Options = Options
  {
    _runningMode :: RunningMode
  , _configFile :: Maybe Text
  , _verbosity :: Priority
  , _forward_TCPs :: [Forward]
  , _forward_UDPs :: [Forward]
  , _disable_SOCKS5 :: Bool
  , _obfuscation :: Bool
  , _forbidden_IPs :: [IPRange]
  , _listMethods :: Bool
  , _params :: [(Text, Value)]
  }
  deriving (Show, Eq)

makeLenses ''Options

type Cipher = S.Maybe ByteString -> IO ByteString 
type IV = ByteString
type CipherBuilder = IV -> IO Cipher

data CipherBox = CipherBox
  {
    _ivLength :: Int
  , _generate_IV :: IO IV
  , _encryptBuilder :: CipherBuilder
  , _decryptBuilder ::  CipherBuilder
  }

makeLenses ''CipherBox

data LocalServiceType =
      LocalService_TCP_Forward Forward
    | LocalService_UDP_Forward Forward
    | LocalService_SOCKS5 Int
    deriving (Show, Eq)

makePrisms ''LocalServiceType


{-newtype AsyncWrapper = AsyncWrapper { _unAsyncWrapper :: Async () }-}
  {-deriving (Eq, Ord)-}

{-makeLenses ''AsyncWrapper-}

{-instance Show AsyncWrapper where-}
  {-show _ = "Async Wrapper"-}

data LocalService = LocalService
  {
    _localServiceAddress :: Text
  , _localServiceRemoteAddress :: Text
  , _localServiceRemotePort :: Int
  , _localServiceType :: LocalServiceType
  }
  deriving (Show, Eq)

makeLenses ''LocalService

data RemoteRelayType =
      Remote_TCP_Relay
    | Remote_UDP_Relay
    deriving (Show, Eq)

makePrisms ''RemoteRelayType


data RemoteRelay = RemoteRelay
  {
    _remoteRelayType :: RemoteRelayType
  , _remoteRelayAddress :: Text
  , _remoteRelayPort :: Int
  }
  deriving (Show, Eq)

makeLenses ''RemoteRelay

data Job = 
      RemoteRelayJob RemoteRelay
    | LocalServiceJob LocalService
    deriving (Show, Eq)

makePrisms ''Job

type Async_ID = Async ()

data Runtime = Runtime
  {
    _localServices :: [LocalService]
  , _remoteRelays :: [RemoteRelay]
  , _jobs :: [(Job, Async_ID)]
  }

makeLenses ''Runtime

instance Monoid Runtime where
  mempty = Runtime [] [] []
  Runtime x y z `mappend` Runtime x' y' z' = Runtime 
                                              (x <> x') 
                                              (y <> y')
                                              (z <> z')
          

data Env = Env
  {
    _options :: Options
  , _config :: Config
  , _cipherBox :: CipherBox
  }

makeLenses ''Env


type MoeMonadT = ReaderT Options (ExceptT String IO)

