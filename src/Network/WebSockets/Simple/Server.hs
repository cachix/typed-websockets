module Network.WebSockets.Simple.Server
  ( Options (..),
    defaultOptions,
    run,
    ClientConnection (..),
    Session.Session,
    Session.SessionProtocol (..),
    Session.Codec (..),
  )
where

import Control.Exception.Safe (SomeException, handle, throwIO)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (unpack)
import Data.Foldable (for_)
import Network.WebSockets qualified as WS
import Network.WebSockets.Connection.PingPong qualified as PingPong
import Network.WebSockets.Simple.Session qualified as Session
import Network.WebSockets.Simple.Utils qualified as Utils

data Options a = Options
  { handlePendingConnection :: (ClientConnection a) => WS.PendingConnection -> IO (Maybe a),
    pingPongOptions :: WS.PingPongOptions -> IO WS.PingPongOptions,
    messageLimit :: Int,
    handleException :: WS.PendingConnection -> SomeException -> IO ()
  }

--
defaultOptions :: Options WS.Connection
defaultOptions =
  Options
    { handlePendingConnection = (fmap Just) . WS.acceptRequest,
      pingPongOptions = return,
      messageLimit = 10000,
      handleException = \_ _ -> return ()
    }

class ClientConnection a where
  getConnection :: a -> WS.Connection

instance ClientConnection WS.Connection where
  getConnection = id

run :: (ClientConnection a, Session.Codec send, Session.Codec receive) => ByteString -> Options a -> (a -> Session.Session IO send receive ()) -> (a -> receive -> Session.Session IO send receive ()) -> IO ()
run uriBS options app receiveApp = do
  (isSecure, host, port, _) <- Utils.parseURI uriBS
  when isSecure $ throwIO $ Utils.Unsupported "TLS server connections are not supported yet: https://github.com/jaspervdj/websockets/pull/215"
  pingpongOpts <- pingPongOptions options WS.defaultPingPongOptions
  let serverOptions =
        WS.defaultServerOptions
          { WS.serverHost = unpack host,
            WS.serverPort = port
          }
  WS.runServerWithOptions serverOptions (application pingpongOpts)
  where
    application :: PingPong.PingPongOptions -> WS.ServerApp
    application pingpongOpts pendingConnection = handle (handleException options pendingConnection) $ do
      maybeClient <- handlePendingConnection options pendingConnection
      for_ maybeClient $ \client -> PingPong.withPingPong pingpongOpts (getConnection client) $ \_ ->
        Session.run (messageLimit options) (getConnection client) (app client) (receiveApp client)

-- TODO: shutdown ::
