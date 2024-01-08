module Network.WebSockets.Simple.Session
  ( Codec (..),
    run,
    Session (..),
    SessionProtocol (..),
    ackProtocol,
  )
where

import Control.Concurrent.Async (async, waitAnyCancel)
import Control.Concurrent.Chan.Unagi.Bounded qualified as Unagi
import Control.Monad (forever, void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader (MonadReader, ReaderT, asks, runReaderT)
import Data.ByteString (ByteString, toStrict)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, newIORef)
import Data.Time.Clock (UTCTime)
import Network.WebSockets qualified as WS

-- Allows decoding from ByteString to any format like JSON or CBOR.
class Codec a where
  toByteString :: a -> ByteString
  fromByteString :: ByteString -> a

-- State for the session
data SessionEnv = SessionEnv
  { sendChan :: Unagi.InChan ByteString,
    receiveChan :: Unagi.OutChan ByteString,
    -- TODO: ideally we'd implement a way for each WebsocketMonad instance to specify how env is created
    -- maybe order by timestamp?
    ackProtocol :: IORef (Integer, HashMap.HashMap Integer (UTCTime, ByteString))
  }

newtype Session m send receive a = Session (ReaderT SessionEnv m a)
  deriving (Applicative, Functor, Monad, MonadIO, MonadReader SessionEnv, MonadUnliftIO)

runSession :: Session m send receive a -> SessionEnv -> m a
runSession (Session session) = runReaderT session

class (MonadIO m, Codec send, Codec receive) => SessionProtocol m send receive where
  send :: send -> Session m send receive ()
  receive :: Session m send receive receive

instance {-# OVERLAPPABLE #-} (MonadIO m, Codec send, Codec receive) => SessionProtocol m send receive where
  send msg = do
    sendChanWrite <- asks sendChan
    liftIO $ Unagi.writeChan sendChanWrite $ toByteString msg

  receive = do
    receiveChanRead <- asks receiveChan
    msg <- liftIO $ Unagi.readChan receiveChanRead
    return $ fromByteString msg

run :: (Codec send, Codec receive) => Int -> WS.Connection -> Session IO send receive () -> (receive -> Session IO send receive ()) -> IO ()
run limit conn sendApp receiveApp = do
  (sendChanWrite, sendChanRead) <- liftIO $ Unagi.newChan limit
  (receiveChanWrite, receiveChanRead) <- liftIO $ Unagi.newChan limit
  ackProtocol <- liftIO $ newIORef (0, HashMap.empty)
  let clientEnv = SessionEnv sendChanWrite receiveChanRead ackProtocol

  -- Use async to queue the send and receive channels in parallel
  sendAsync <- liftIO $ async $ forever $ do
    msg <- Unagi.readChan sendChanRead
    -- TODO support text
    WS.sendBinaryData conn msg

  receiveAsync <- liftIO $ async $ forever $ do
    msg <- WS.receiveDataMessage conn
    case msg of
      WS.Text bs _ -> Unagi.writeChan receiveChanWrite $ toStrict bs
      WS.Binary bs -> Unagi.writeChan receiveChanWrite $ toStrict bs

  sendAppAsync <-
    liftIO $
      async $
        forever $
          runSession sendApp clientEnv

  receiveAppAsync <- liftIO $ async $ forever $ do
    runSession (receive >>= receiveApp) clientEnv

  void $ liftIO $ waitAnyCancel [sendAsync, receiveAsync, sendAppAsync, receiveAppAsync]
