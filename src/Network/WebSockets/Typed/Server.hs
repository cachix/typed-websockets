module Network.WebSockets.Typed.Server
  ( Options (..),
    defaultOptions,
    run,
    ClientConnection (..),
    Session.Session,
    Session.SessionProtocol (..),
    Session.Codec (..),
  )
where

import Control.Exception.Safe (SomeException, fromException, handle, throwIO)
import Control.Monad (when)
import Control.Monad.RWS (MonadState (put))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (unpack)
import Data.Foldable (for_)
import Data.Maybe (isNothing)
import Network.WebSockets qualified as WS
import Network.WebSockets.Connection.PingPong qualified as PingPong
import Network.WebSockets.Typed.Session qualified as Session
import Network.WebSockets.Typed.Utils qualified as Utils

data Options a = Options
  { handlePendingConnection :: (ClientConnection a) => WS.PendingConnection -> IO (Maybe a),
    pingPongOptions :: WS.PingPongOptions -> IO WS.PingPongOptions,
    messageLimit :: Int,
    -- handler for sync exceptions, ignoring WS.ConnectionException
    onHandleException :: WS.PendingConnection -> SomeException -> IO ()
  }

--
defaultOptions :: Options WS.Connection
defaultOptions =
  Options
    { handlePendingConnection = fmap Just . WS.acceptRequest,
      pingPongOptions = return,
      messageLimit = 10000,
      onHandleException = \_ exc -> do
        putStrLn $ "Exception in websocket server: " <> show exc
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
    application pingpongOpts pendingConnection = handle (handler pendingConnection) $ do
      maybeClient <- handlePendingConnection options pendingConnection
      for_ maybeClient $ \client -> PingPong.withPingPong pingpongOpts (getConnection client) $ \_ ->
        Session.run (messageLimit options) (getConnection client) (app client) (receiveApp client)

    handler :: WS.PendingConnection -> SomeException -> IO ()
    handler pendingConnection exc = do
      when (isNothing $ fromException @WS.ConnectionException exc) $
        onHandleException options pendingConnection exc
