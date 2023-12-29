module Network.WebSockets.Simple.Client
  ( Options (..),
    defaultOptions,
    run,
    Session.Session,
    Session.SessionProtocol (..),
    Session.Codec (..),
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 (unpack)
import Network.WebSockets qualified as WS
import Network.WebSockets.Connection.PingPong qualified as PingPong
import Network.WebSockets.Simple.Session qualified as Session
import Network.WebSockets.Simple.Utils qualified as Utils
import Wuss qualified

data Options = Options
  { headers :: WS.Headers,
    messageLimit :: Int
  }

defaultOptions :: Options
defaultOptions =
  Options
    { headers = [],
      messageLimit = 10000
    }

run :: (Session.Codec send, Session.Codec receive) => ByteString -> Options -> Session.Session IO send receive () -> (receive -> Session.Session IO send receive ()) -> IO ()
run uriBS options app receiveApp = do
  (isSecure, host, port, path) <- Utils.parseURI uriBS
  if isSecure
    then Wuss.runSecureClientWith (unpack host) (fromIntegral port) (unpack path) connectionOptions (headers options) go
    else WS.runClientWith (unpack host) (fromIntegral port) (unpack path) connectionOptions (headers options) go
  where
    connectionOptions :: WS.ConnectionOptions
    connectionOptions = WS.defaultConnectionOptions

    go :: WS.ClientApp ()
    go connection = do
      PingPong.withPingPong WS.defaultPingPongOptions connection (\conn -> Session.run (messageLimit options) conn app receiveApp)

-- TODO: shutdown :: IO ()
-- TODO: retries
