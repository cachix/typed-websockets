# typed-websockets


[![Hackage](https://img.shields.io/hackage/v/typed-websockets.svg?style=flat)](https://hackage.haskell.org/package/typed-websockets) ![CI status](https://github.com/cachix/typed-websockets/actions/workflows/ci.yml/badge.svg)

High-level interface for websockets.

## Features

- Splits up receiving and sending into separate threads
- Wires up Ping/Pong for Client and Server
- Uses channels for sending/receiving messages
- URI based API supporting `ws://` and `wss://` (for the client)
- Simple interface between client and server send/receive types
- Retries connection indefinitely for the client automatically using [Stamina](https://github.com/cachix/stamina.hs)
- Handles graceful shutdown for the client

## Example

### Settings up types

```haskell
{-# LANGUAGE DeriveAnyClass, DeriveGeneric, OverloadedStrings #-}
module Main where
import qualified Network.WebSockets.Typed.Client as WClient
import qualified Network.WebSockets.Typed.Server as WServer
import qualified Network.WebSockets as WS
-- using cbor as an example, aeson would work too
import qualified Codec.Serialise as Serialise
import Data.String.Conv (toS)
import Data.Text (Text)
import GHC.Generics (Generic)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent.Async (race_)


-- | The types of messages that can be sent from the server to the client
data ServerMessage
  = HelloFromServer Text
  deriving (Show, Generic, Serialise.Serialise)

-- | The types of messages that can be sent from the client to the server
data ClientMessage
  = HelloFromClient Text
  deriving (Show, Generic, Serialise.Serialise)

-- | The type of the client application
type MyClient = WClient.Session IO ClientMessage ServerMessage ()
-- | The type of the server application
type MyServer = WServer.Session IO ServerMessage ClientMessage ()

-- How to decode/encode ByteStrings 
instance WClient.Codec ClientMessage where
  toByteString = toS . Serialise.serialise
  fromByteString = Serialise.deserialise . toS

instance WServer.Codec ServerMessage where
  toByteString = toS . Serialise.serialise
  fromByteString = Serialise.deserialise . toS
```

### Client Example

```haskell
options :: WClient.Options
options = WClient.defaultOptions

clientApp :: MyClient
clientApp = do
  WClient.send $ HelloFromClient "Hello from client"

clientReceiveApp :: ServerMessage -> MyClient
clientReceiveApp (HelloFromServer msg) = do
  liftIO $ putStrLn $ toS $ "Received from server: " <> msg

runClient :: IO ()
runClient = do
    WClient.run "ws://127.0.0.1:8989" options clientApp clientReceiveApp
```

### Server Example

```haskell
serverOptions :: WServer.Options MyClientConnection
serverOptions = WServer.defaultOptions {
        WServer.handlePendingConnection = handlePendingConnection
    }

data MyClientConnection = MyClientConnection
  { clientConnection :: WS.Connection,
    myClientVersion :: Text
  }

instance WServer.ClientConnection MyClientConnection where 
    getConnection = clientConnection

handlePendingConnection :: WS.PendingConnection -> IO (Maybe MyClientConnection)
handlePendingConnection pendingConn = do
    connection <- WS.acceptRequest pendingConn
    return $ Just $ MyClientConnection connection "1.0"

serverApp :: MyClientConnection -> MyServer
serverApp _ = do
    WServer.send $ HelloFromServer "Hello from server"

serverReceiveApp :: MyClientConnection -> ClientMessage -> MyServer
serverReceiveApp _ (HelloFromClient msg) = do
    liftIO $ putStrLn $ toS $ "Received from client: " <> msg

runServer :: IO ()
runServer = do
  WServer.run "ws://127.0.0.1:8989" serverOptions serverApp serverReceiveApp
```

### Wire it up

```haskell
main :: IO ()
main = race_ runServer runClient
```