module Network.WebSockets.Simple.Utils where

import Control.Exception (Exception, throwIO)
import Data.ByteString (ByteString)
import URI.ByteString qualified as URI

escalateWith :: (Exception exc) => (err -> exc) -> Either err URI.URI -> IO URI.URI
escalateWith f = either (throwIO . f) pure

data InitException
  = InvalidURIScheme URI.URIParseError
  | Unsupported String
  deriving (Show)

instance Exception InitException

parseURI :: ByteString -> IO (Bool, ByteString, Int, ByteString)
parseURI uriBS = do
  uri <- escalateWith InvalidURIScheme $ URI.parseURI URI.strictURIParserOptions uriBS
  isSecure <- case URI.uriScheme uri of
    (URI.Scheme "wss") -> pure True
    (URI.Scheme "ws") -> pure False
    _ -> throwIO $ InvalidURIScheme $ URI.OtherError $ "Invalid URI scheme " <> show uri <> ", expected ws:// or wss://"
  let authority :: Maybe URI.Authority
      authority = URI.uriAuthority uri
      port = maybe (if isSecure then 443 else 80) URI.portNumber (authority >>= URI.authorityPort)
      path = URI.uriPath uri
      host = maybe "127.0.0.1" (URI.hostBS . URI.authorityHost) authority
  return (isSecure, host, port, path)
