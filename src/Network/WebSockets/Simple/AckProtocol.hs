module Network.WebSockets.Simple.AckProtocol (AckProtocol (..), resendTimedoutEvents) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (asks)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (atomicModifyIORef', readIORef)
import Data.Time.Clock (addUTCTime, getCurrentTime, secondsToNominalDiffTime)
import GHC.Generics (Generic)
import Network.WebSockets.Simple.Session qualified as Session

-- inspired by https://socket.io/docs/v4/socket-io-protocol/#exchange-protocol
data AckProtocol message
  = Send message
  | Event Integer message
  | EventAck Integer
  deriving (Show, Generic)

instance
  ( MonadIO m,
    Session.Codec (AckProtocol send),
    Session.Codec (AckProtocol receive),
    Session.Codec send,
    Session.Codec receive
  ) =>
  Session.SessionProtocol m (AckProtocol send) (AckProtocol receive)
  where
  send (Send msg) = do
    timestamp <- liftIO getCurrentTime
    ackProtocol <- asks Session.ackProtocol
    id_ <- liftIO $ atomicModifyIORef' ackProtocol $ \(current, hashMap) ->
      let next = current + 1
          -- inefficient since we're converting to bytestring twice and on each retry
          newHashMap = HashMap.insert next (timestamp, Session.toByteString msg) hashMap
       in ((next, newHashMap), next)
    Session.send $ Event id_ msg
  send (Event _ _) = error "send: unexpected Event message"
  send (EventAck _) = error "send: unexpected EventAck message"

  receive = do
    msg <- Session.receive
    case msg of
      EventAck id_ -> do
        ackProtocol <- asks Session.ackProtocol
        _ <- liftIO $ atomicModifyIORef' ackProtocol $ \(current, hashMap) ->
          ((current, HashMap.delete id_ hashMap), ())
        return $ EventAck id_
      Event id_ msg2 -> do
        Session.send $ EventAck id_
        return $ Event id_ msg2
      Send _ -> error "receive: unexpected Send message"

resendTimedoutEvents ::
  ( MonadIO m,
    Session.Codec (AckProtocol send),
    Session.Codec (AckProtocol receive),
    Session.Codec send,
    Session.Codec receive
  ) =>
  Session.Session m (AckProtocol send) (AckProtocol receive) ()
resendTimedoutEvents = do
  ackProtocol <- asks Session.ackProtocol
  (_, hashMap) <- liftIO $ readIORef ackProtocol
  currentTime <- liftIO getCurrentTime
  let timedout = HashMap.filter (\(msgTimestamp, _) -> addUTCTime (secondsToNominalDiffTime $ fromIntegral interval) msgTimestamp < currentTime) hashMap
  forM_ (HashMap.toList timedout) $ \(id_, (_, msg)) ->
    Session.send $ Event id_ $ Session.fromByteString msg
  liftIO $ threadDelay (fromIntegral interval * 1000 * 1000)
  resendTimedoutEvents
  where
    interval = 10
