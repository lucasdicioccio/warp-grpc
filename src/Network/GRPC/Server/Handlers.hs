{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.GRPC.Server.Handlers where

import           Data.Binary.Get (pushChunk, Decoder(..))
import qualified Data.ByteString.Char8 as ByteString
import           Data.ByteString.Char8 (ByteString)
import           Data.ByteString.Lazy (toStrict)
import           Data.ProtoLens.Message (Message)
import           Data.ProtoLens.Service.Types (Service(..), HasMethod, HasMethodImpl(..))
import           Network.GRPC.HTTP2.Encoding (Compression, decodeInput, encodeOutput)
import           Network.GRPC.HTTP2.Types (RPC(..), GRPCStatus(..), GRPCStatusCode(..), path)
import           Network.Wai (Request, requestBody, strictRequestBody)

import Network.GRPC.Server.Wai (WaiHandler, ServiceHandler(..), closeEarly)

-- | Handy type to refer to Handler for 'unary' RPCs handler.
type UnaryHandler s m = Request -> MethodInput s m -> IO (MethodOutput s m)

-- | Handy type for 'server-streaming' RPCs.
--
-- We expect an implementation to:
-- - read the input request
-- - return an initial state and an state-passing action that the server code will call to fetch the output to send to the client (or close an a Nothing)
-- See 'ServerStream' for the type which embodies these requirements.
type ServerStreamHandler s m a = Request -> MethodInput s m -> IO (a, ServerStream s m a)

newtype ServerStream s m a = ServerStream {
    serverStreamNext :: a -> IO (Maybe (a, MethodOutput s m))
  }

-- | Handy type for 'client-streaming' RPCs.
--
-- We expect an implementation to:
-- - acknowledge a the new client stream by returning an initial state and two functions:
-- - a state-passing handler for new client message
-- - a state-aware handler for answering the client when it is ending its stream
-- See 'ClientStream' for the type which embodies these requirements.
type ClientStreamHandler s m a = Request -> IO (a, ClientStream s m a)

data ClientStream s m a = ClientStream {
    clientStreamHandler   :: a -> MethodInput s m -> IO a
  , clientStreamFinalizer :: a -> IO (MethodOutput s m)
  }

-- | Construct a handler for handling a unary RPC.
unary
  :: (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> UnaryHandler s m
  -> ServiceHandler
unary rpc compression handler =
    ServiceHandler (path rpc) (handleUnary rpc compression handler)

-- | Construct a handler for handling a server-streaming RPC.
serverStream
  :: (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> ServerStreamHandler s m a
  -> ServiceHandler
serverStream rpc compression handler =
    ServiceHandler (path rpc) (handleServerStream rpc compression handler)

-- | Construct a handler for handling a client-streaming RPC.
clientStream
  :: (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> ClientStreamHandler s m a
  -> ServiceHandler
clientStream rpc compression handler =
    ServiceHandler (path rpc) (handleClientStream rpc compression handler)

-- | Handle unary RPCs.
handleUnary ::
     (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> UnaryHandler s m
  -> WaiHandler
handleUnary rpc compression handler req write flush = do
    handleRequestChunksLoop (decodeInput rpc compression) handleMsg handleEof nextChunk
  where
    nextChunk = toStrict <$> strictRequestBody req
    handleMsg = errorOnLeftOver (\i -> handler req i >>= reply)
    handleEof = closeEarly (GRPCStatus INVALID_ARGUMENT "early end of request body")
    reply msg = write (encodeOutput rpc compression msg) >> flush

-- | Handle Server-Streaming RPCs.
handleServerStream ::
     (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> ServerStreamHandler s m a
  -> WaiHandler
handleServerStream rpc compression handler req write flush = do
    handleRequestChunksLoop (decodeInput rpc compression) handleMsg handleEof nextChunk
  where
    nextChunk = toStrict <$> strictRequestBody req
    handleMsg = errorOnLeftOver (\i -> handler req i >>= replyN)
    handleEof = closeEarly (GRPCStatus INVALID_ARGUMENT "early end of request body")
    replyN (v, sStream) = do
        let go v1 = serverStreamNext sStream v1 >>= \case
                Just (v2, msg) -> do
                    write (encodeOutput rpc compression msg) >> flush
                    go v2
                Nothing -> pure ()
        go v

-- | Handle Client-Streaming RPCs.
handleClientStream ::
     (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> ClientStreamHandler s m a
  -> WaiHandler
handleClientStream rpc compression handler0 req write flush = do
    handler0 req >>= go
  where
    go (v, cStream) = handleRequestChunksLoop (decodeInput rpc compression) (handleMsg v) (handleEof v) nextChunk
      where
        nextChunk = requestBody req
        handleMsg v0 dat msg = clientStreamHandler cStream v0 msg >>= \v1 -> loop dat v1
        handleEof v0 = clientStreamFinalizer cStream v0 >>= reply
        reply msg = write (encodeOutput rpc compression msg) >> flush
        loop chunk v1 = handleRequestChunksLoop (flip pushChunk chunk $ decodeInput rpc compression) (handleMsg v1) (handleEof v1) nextChunk

-- | Helpers to consume input in chunks.
handleRequestChunksLoop
  :: (Message a)
  => Decoder (Either String a)
  -- ^ Message decoder.
  -> (ByteString -> a -> IO ())
  -- ^ Handler for a single message.
  -- The ByteString corresponds to leftover data.
  -> IO ()
  -- ^ Handler for handling end-of-streams.
  -> IO ByteString
  -- ^ Action to retrieve the next chunk.
  -> IO ()
{-# INLINEABLE handleRequestChunksLoop #-}
handleRequestChunksLoop decoder handleMsg handleEof nextChunk =
    case decoder of
        (Done unusedDat _ (Right val)) -> do
            handleMsg unusedDat val
        (Done _ _ (Left err)) -> do
            closeEarly (GRPCStatus INVALID_ARGUMENT (ByteString.pack $ "done-error: " ++ err))
        (Fail _ _ err)         ->
            closeEarly (GRPCStatus INVALID_ARGUMENT (ByteString.pack $ "fail-error: " ++ err))
        partial@(Partial _)    -> do
            chunk <- nextChunk
            if ByteString.null chunk
            then
                handleEof
            else
                handleRequestChunksLoop (pushChunk partial chunk) handleMsg handleEof nextChunk

-- | Combinator around message handler to error on left overs.
--
-- This combinator ensures that, unless for client stream, an unparsed piece of
-- data with a correctly-read message is treated as an error.
errorOnLeftOver :: (a -> IO b) -> ByteString -> a -> IO b
errorOnLeftOver f rest
  | ByteString.null rest = f
  | otherwise            = const $ closeEarly $ GRPCStatus INVALID_ARGUMENT ("left-overs: " <> rest)
