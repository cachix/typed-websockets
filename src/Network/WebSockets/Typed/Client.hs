module Network.WebSockets.Typed.Client
  ( Options (..),
    defaultOptions,
    run,
    Session.Session,
    Session.SessionProtocol (..),
    Session.Codec (..),
  )
where

import Control.Exception (Exception (fromException), SomeException, finally)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (unpack)
import Data.Foldable (for_)
import Data.Maybe (isJust)
import Network.WebSockets qualified as WS
import Network.WebSockets.Connection.PingPong qualified as PingPong
import Network.WebSockets.Typed.Session qualified as Session
import Network.WebSockets.Typed.Utils qualified as Utils
import Stamina qualified
import Wuss qualified

data Options = Options
  { headers :: WS.Headers,
    messageLimit :: Int,
    staminaSettings :: Stamina.RetrySettings,
    onStaminaRetry :: Stamina.RetryStatus -> IO (),
    onShutdown :: WS.Connection -> IO ()
  }

defaultOptions :: Options
defaultOptions =
  Options
    { headers = [],
      messageLimit = 10000,
      staminaSettings =
        Stamina.defaults
          { Stamina.maxTime = Nothing,
            Stamina.maxAttempts = Nothing
          },
      onStaminaRetry = \retryStatus -> do
        for_ (Stamina.lastException retryStatus) $ \exc ->
          putStrLn $ "Retrying websocket connection after exception: " <> show exc,
      onShutdown = \connection ->
        -- TODO: drain the message queues
        -- TODO: if there was an exception related to socket, we need to handle it?
        WS.sendClose connection ("Bye!" :: ByteString)
    }

run :: (Session.Codec send, Session.Codec receive) => ByteString -> Options -> Session.Session IO send receive () -> (receive -> Session.Session IO send receive ()) -> IO ()
run uriBS options app receiveApp = do
  (isSecure, host, port, path) <- Utils.parseURI uriBS
  Stamina.retryFor (staminaSettings options) handler $ \retryStatus -> do
    when (isJust $ Stamina.lastException retryStatus) $
      onStaminaRetry options retryStatus
    if isSecure
      then Wuss.runSecureClientWith (unpack host) (fromIntegral port) (unpack path) connectionOptions (headers options) (go retryStatus)
      else WS.runClientWith (unpack host) (fromIntegral port) (unpack path) connectionOptions (headers options) (go retryStatus)
  where
    connectionOptions :: WS.ConnectionOptions
    connectionOptions = WS.defaultConnectionOptions

    handler :: SomeException -> IO Stamina.RetryAction
    handler exc = case fromException exc of
      -- we don't want to retry on close requests
      Just WS.CloseRequest {} -> pure Stamina.RaiseException
      _ -> pure Stamina.Retry

    go :: Stamina.RetryStatus -> WS.ClientApp ()
    go retryStatus connection = do
      Stamina.resetInitial retryStatus
      PingPong.withPingPong
        WS.defaultPingPongOptions
        connection
        $ const
        $ Session.run (messageLimit options) connection app receiveApp `finally` onShutdown options connection
