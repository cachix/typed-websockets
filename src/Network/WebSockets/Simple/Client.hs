module Network.WebSockets.Simple.Client
  ( Options (..),
    defaultOptions,
    run,
    Session.Session,
    Session.SessionProtocol (..),
    Session.Codec (..),
  )
where

import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (unpack)
import Data.Maybe (isJust)
import Network.WebSockets qualified as WS
import Network.WebSockets.Connection.PingPong qualified as PingPong
import Network.WebSockets.Simple.Session qualified as Session
import Network.WebSockets.Simple.Utils qualified as Utils
import Stamina qualified
import Wuss qualified

data Options = Options
  { headers :: WS.Headers,
    messageLimit :: Int,
    staminaSettings :: Stamina.RetrySettings,
    staminaRetry :: Stamina.RetryStatus -> IO ()
  }

defaultOptions :: Options
defaultOptions =
  Options
    { headers = [],
      messageLimit = 10000,
      staminaSettings = Stamina.defaults,
      staminaRetry = const $ return ()
    }

run :: (Session.Codec send, Session.Codec receive) => ByteString -> Options -> Session.Session IO send receive () -> (receive -> Session.Session IO send receive ()) -> IO ()
run uriBS options app receiveApp = do
  (isSecure, host, port, path) <- Utils.parseURI uriBS
  Stamina.retry (staminaSettings options) $ \retryStatus -> do
    when (isJust $ Stamina.lastException retryStatus) $
      staminaRetry options retryStatus
    if isSecure
      then Wuss.runSecureClientWith (unpack host) (fromIntegral port) (unpack path) connectionOptions (headers options) (go retryStatus)
      else WS.runClientWith (unpack host) (fromIntegral port) (unpack path) connectionOptions (headers options) (go retryStatus)
  where
    connectionOptions :: WS.ConnectionOptions
    connectionOptions = WS.defaultConnectionOptions

    go :: Stamina.RetryStatus -> WS.ClientApp ()
    go retryStatus connection = do
      Stamina.resetInitial retryStatus
      PingPong.withPingPong WS.defaultPingPongOptions connection (\conn -> Session.run (messageLimit options) conn app receiveApp)
