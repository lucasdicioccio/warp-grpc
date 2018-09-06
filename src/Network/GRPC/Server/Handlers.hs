{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
module Network.GRPC.Server.Handlers where

import           Data.Binary.Get (pushChunk, Decoder(..))
import qualified Data.ByteString.Char8 as ByteString
import           Data.ByteString.Char8 (ByteString)
import           Data.ByteString.Lazy (toStrict)
import           Data.ProtoLens.Message (Message)
import           Data.ProtoLens.Service.Types (Service(..), HasMethod, HasMethodImpl(..), StreamingType(..))
import           Network.GRPC.HTTP2.Encoding (decodeInput, encodeOutput, Encoding(..), Decoding(..))
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

-- | Handy type for 'bidirectional-streaming' RPCs.
--
-- We expect an implementation to:
-- - acknowlege a new bidirection stream by returning an initial state and one functions:
-- - a state-passing function that returns a single action step
-- The action may be to
-- - stop immediately
-- - wait and handle some input with a callback and a finalizer (if the client closes the stream on its side) that may change the state
-- - return a value and a new state
--
-- There is no way to stop locally (that would mean sending HTTP2 trailers) and
-- keep receiving messages from the client.
type BiDiStreamHandler s m a = Request -> IO (a, BiDiStream s m a)

data BiDiStep s m a
  = Abort
  | WaitInput !(a -> MethodInput s m -> IO a) !(a -> IO a)
  | WriteOutput !a (MethodOutput s m)

data BiDiStream s m a = BiDiStream {
    bidirNextStep :: a -> IO (BiDiStep s m a)
  }

-- | Construct a handler for handling a unary RPC.
unary
  :: (Service s, HasMethod s m)
  => RPC s m
  -> UnaryHandler s m
  -> ServiceHandler
unary rpc handler =
    ServiceHandler (path rpc) (handleUnary rpc handler)

-- | Construct a handler for handling a server-streaming RPC.
serverStream
  :: (Service s, HasMethod s m,  MethodStreamingType s m ~ 'ServerStreaming)
  => RPC s m
  -> ServerStreamHandler s m a
  -> ServiceHandler
serverStream rpc handler =
    ServiceHandler (path rpc) (handleServerStream rpc handler)

-- | Construct a handler for handling a client-streaming RPC.
clientStream
  :: (Service s, HasMethod s m,  MethodStreamingType s m ~ 'ClientStreaming)
  => RPC s m
  -> ClientStreamHandler s m a
  -> ServiceHandler
clientStream rpc handler =
    ServiceHandler (path rpc) (handleClientStream rpc handler)

-- | Construct a handler for handling a bidirectional-streaming RPC.
bidiStream
  :: (Service s, HasMethod s m,  MethodStreamingType s m ~ 'BiDiStreaming)
  => RPC s m
  -> BiDiStreamHandler s m a
  -> ServiceHandler
bidiStream rpc handler =
    ServiceHandler (path rpc) (handleBiDiStream rpc handler)

-- | Handle unary RPCs.
handleUnary ::
     (Service s, HasMethod s m)
  => RPC s m
  -> UnaryHandler s m
  -> WaiHandler
handleUnary rpc handler decoding encoding req write flush = do
    handleRequestChunksLoop (decodeInput rpc $ _getDecodingCompression decoding) handleMsg handleEof nextChunk
  where
    nextChunk = toStrict <$> strictRequestBody req
    handleMsg = errorOnLeftOver (\i -> handler req i >>= reply)
    handleEof = closeEarly (GRPCStatus INVALID_ARGUMENT "early end of request body")
    reply msg = write (encodeOutput rpc (_getEncodingCompression encoding) msg) >> flush

-- | Handle Server-Streaming RPCs.
handleServerStream ::
     (Service s, HasMethod s m)
  => RPC s m
  -> ServerStreamHandler s m a
  -> WaiHandler
handleServerStream rpc handler decoding encoding req write flush = do
    handleRequestChunksLoop (decodeInput rpc $ _getDecodingCompression decoding) handleMsg handleEof nextChunk
  where
    nextChunk = toStrict <$> strictRequestBody req
    handleMsg = errorOnLeftOver (\i -> handler req i >>= replyN)
    handleEof = closeEarly (GRPCStatus INVALID_ARGUMENT "early end of request body")
    replyN (v, sStream) = do
        let go v1 = serverStreamNext sStream v1 >>= \case
                Just (v2, msg) -> do
                    write (encodeOutput rpc (_getEncodingCompression encoding) msg) >> flush
                    go v2
                Nothing -> pure ()
        go v

-- | Handle Client-Streaming RPCs.
handleClientStream ::
     (Service s, HasMethod s m)
  => RPC s m
  -> ClientStreamHandler s m a
  -> WaiHandler
handleClientStream rpc handler0 decoding encoding req write flush = do
    handler0 req >>= go
  where
    go (v, cStream) = handleRequestChunksLoop (decodeInput rpc $ _getDecodingCompression decoding) (handleMsg v) (handleEof v) nextChunk
      where
        nextChunk = requestBody req
        handleMsg v0 dat msg = clientStreamHandler cStream v0 msg >>= \v1 -> loop dat v1
        handleEof v0 = clientStreamFinalizer cStream v0 >>= reply
        reply msg = write (encodeOutput rpc (_getEncodingCompression encoding) msg) >> flush
        loop chunk v1 = handleRequestChunksLoop (flip pushChunk chunk $ decodeInput rpc (_getDecodingCompression decoding)) (handleMsg v1) (handleEof v1) nextChunk

-- | Handle Bidirectional-Streaming RPCs.
handleBiDiStream ::
    (Service s, HasMethod s m)
  => RPC s m
  -> BiDiStreamHandler s m a
  -> WaiHandler
handleBiDiStream rpc handler0 decoding encoding req write flush = do
    handler0 req >>= go ""
  where
    nextChunk = requestBody req
    reply msg = write (encodeOutput rpc (_getEncodingCompression encoding) msg) >> flush
    go chunk (v0, bStream) = do
        let cont dat v1 = go dat (v1, bStream)
        step <- (bidirNextStep bStream) v0
        case step of
            WaitInput handleMsg handleEof -> do
                handleRequestChunksLoop (flip pushChunk chunk $ decodeInput rpc $ _getDecodingCompression decoding)
                                        (\dat msg -> handleMsg v0 msg >>= cont dat)
                                        (handleEof v0 >>= cont "")
                                        nextChunk
            WriteOutput v1 msg -> do
                reply msg
                cont "" v1
            Abort -> return ()

-- | Helpers to consume input in chunks.
handleRequestChunksLoop
  :: (Message a)
  => Decoder (Either String a)
  -- ^ Message decoder.
  -> (ByteString -> a -> IO b)
  -- ^ Handler for a single message.
  -- The ByteString corresponds to leftover data.
  -> IO b
  -- ^ Handler for handling end-of-streams.
  -> IO ByteString
  -- ^ Action to retrieve the next chunk.
  -> IO b
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
