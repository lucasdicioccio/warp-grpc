{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
module Network.GRPC.Server.Handlers.NoLens where

import           Control.Concurrent.Async (concurrently)
import           Control.Monad (void)
import           Data.Binary.Builder (Builder, singleton, putWord32be, fromByteString)
import           Data.Binary.Get (pushChunk, Decoder(..), runGetIncremental, getInt8, getWord32be, getByteString)
import qualified Data.ByteString.Char8 as ByteString
import           Data.ByteString.Char8 (ByteString)
import           Data.ByteString.Lazy (toStrict)
import           Network.GRPC.HTTP2.Encoding (Encoding(..), Decoding(..), Compression(..))
import           Network.GRPC.HTTP2.Types (GRPCStatus(..), GRPCStatusCode(..), HeaderValue)
import           Network.Wai (Request, getRequestBodyChunk, strictRequestBody)
import qualified Proto3.Wire.Encode as PBEnc
import qualified Proto3.Wire.Decode as PBDec

import Network.GRPC.Server.Wai (WaiHandler, ServiceHandler(..), closeEarly)

-- From 'Network.GRPC.HTTP2.Types', copied to remove dependency on proto-lens
data RPC = RPC { pkg :: ByteString, srv :: ByteString, meth :: ByteString }

path :: RPC -> HeaderValue
{-# INLINE path #-}
path rpc = "/" <> pkg rpc <> "." <> srv rpc <> "/" <> meth rpc

type ProtoBufEncoder a = a -> PBEnc.MessageBuilder
type ProtoBufDecoder a = PBDec.Parser PBDec.RawMessage a
type ProtoBufBothSides i o = (ProtoBufDecoder i, ProtoBufEncoder o)

encode :: ProtoBufEncoder m -> Compression -> m -> Builder
encode toProtoBuf compression plain =
    mconcat [ singleton (if _compressionByteSet compression then 1 else 0)
            , putWord32be (fromIntegral $ ByteString.length bin)
            , fromByteString bin
            ]
  where
    bin = _compressionFunction compression $ toStrict $ PBEnc.toLazyByteString (toProtoBuf plain)

decoder :: ProtoBufDecoder a -> Compression -> Decoder (Either PBDec.ParseError a)
decoder fromProtoBuf compression = runGetIncremental $ do
    isCompressed <- getInt8      -- 1byte
    let decompress = if isCompressed == 0 then pure else (_decompressionFunction compression)
    n <- getWord32be             -- 4bytes
    PBDec.parse fromProtoBuf <$> (decompress =<< getByteString (fromIntegral n))

-- | Handy type to refer to Handler for 'unary' RPCs handler.
type UnaryHandler i o = Request -> i -> IO o

-- | Handy type for 'server-streaming' RPCs.
--
-- We expect an implementation to:
-- - read the input request
-- - return an initial state and an state-passing action that the server code will call to fetch the output to send to the client (or close an a Nothing)
-- See 'ServerStream' for the type which embodies these requirements.
type ServerStreamHandler i o a = Request -> i -> IO (a, ServerStream o a)

newtype ServerStream o a = ServerStream {
    serverStreamNext :: a -> IO (Maybe (a, o))
  }

-- | Handy type for 'client-streaming' RPCs.
--
-- We expect an implementation to:
-- - acknowledge a the new client stream by returning an initial state and two functions:
-- - a state-passing handler for new client message
-- - a state-aware handler for answering the client when it is ending its stream
-- See 'ClientStream' for the type which embodies these requirements.
type ClientStreamHandler i o a = Request -> IO (a, ClientStream i o a)

data ClientStream i o a = ClientStream {
    clientStreamHandler   :: a -> i -> IO a
  , clientStreamFinalizer :: a -> IO o
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
type BiDiStreamHandler i o a = Request -> IO (a, BiDiStream i o a)

data BiDiStep i o a
  = Abort
  | WaitInput !(a -> i -> IO a) !(a -> IO a)
  | WriteOutput !a o

data BiDiStream i o a = BiDiStream {
    bidirNextStep :: a -> IO (BiDiStep i o a)
  }

-- | Construct a handler for handling a unary RPC.
unary
  :: ProtoBufBothSides i o
  -> RPC
  -> UnaryHandler i o
  -> ServiceHandler
unary pb rpc handler =
    ServiceHandler (path rpc) (handleUnary pb rpc handler)

-- | Construct a handler for handling a server-streaming RPC.
serverStream
  :: ProtoBufBothSides i o
  -> RPC
  -> ServerStreamHandler i o a
  -> ServiceHandler
serverStream pb rpc handler =
    ServiceHandler (path rpc) (handleServerStream pb rpc handler)

-- | Construct a handler for handling a client-streaming RPC.
clientStream
  :: ProtoBufBothSides i o
  -> RPC
  -> ClientStreamHandler i o a
  -> ServiceHandler
clientStream pb rpc handler =
    ServiceHandler (path rpc) (handleClientStream pb rpc handler)

-- | Construct a handler for handling a bidirectional-streaming RPC.
bidiStream
  :: ProtoBufBothSides i o
  -> RPC
  -> BiDiStreamHandler i o a
  -> ServiceHandler
bidiStream pb rpc handler =
    ServiceHandler (path rpc) (handleBiDiStream pb rpc handler)

-- | Construct a handler for handling a bidirectional-streaming RPC.
generalStream
  :: ProtoBufBothSides i o
  -> RPC
  -> GeneralStreamHandler i o a b
  -> ServiceHandler
generalStream pb rpc handler =
    ServiceHandler (path rpc) (handleGeneralStream pb rpc handler)

-- | Handle unary RPCs.
handleUnary ::
     ProtoBufBothSides i o
  -> RPC
  -> UnaryHandler i o
  -> WaiHandler
handleUnary (iDec, oEnc) rpc handler decoding encoding req write flush = do
    handleRequestChunksLoop (decoder iDec $ _getDecodingCompression decoding) handleMsg handleEof nextChunk
  where
    nextChunk = toStrict <$> strictRequestBody req
    handleMsg = errorOnLeftOver (\i -> handler req i >>= reply)
    handleEof = closeEarly (GRPCStatus INVALID_ARGUMENT "early end of request body")
    reply msg = write (encode oEnc (_getEncodingCompression encoding) msg) >> flush

-- | Handle Server-Streaming RPCs.
handleServerStream ::
     ProtoBufBothSides i o
  -> RPC
  -> ServerStreamHandler i o a
  -> WaiHandler
handleServerStream (iDec, oEnc) rpc handler decoding encoding req write flush = do
    handleRequestChunksLoop (decoder iDec $ _getDecodingCompression decoding) handleMsg handleEof nextChunk
  where
    nextChunk = toStrict <$> strictRequestBody req
    handleMsg = errorOnLeftOver (\i -> handler req i >>= replyN)
    handleEof = closeEarly (GRPCStatus INVALID_ARGUMENT "early end of request body")
    replyN (v, sStream) = do
        let go v1 = serverStreamNext sStream v1 >>= \case
                Just (v2, msg) -> do
                    write (encode oEnc (_getEncodingCompression encoding) msg) >> flush
                    go v2
                Nothing -> pure ()
        go v

-- | Handle Client-Streaming RPCs.
handleClientStream ::
     ProtoBufBothSides i o
  -> RPC
  -> ClientStreamHandler i o a
  -> WaiHandler
handleClientStream (iDec, oEnc) rpc handler0 decoding encoding req write flush = do
    handler0 req >>= go
  where
    go (v, cStream) = handleRequestChunksLoop (decoder iDec $ _getDecodingCompression decoding) (handleMsg v) (handleEof v) nextChunk
      where
        nextChunk = getRequestBodyChunk req
        handleMsg v0 dat msg = clientStreamHandler cStream v0 msg >>= \v1 -> loop dat v1
        handleEof v0 = clientStreamFinalizer cStream v0 >>= reply
        reply msg = write (encode oEnc (_getEncodingCompression encoding) msg) >> flush
        loop chunk v1 = handleRequestChunksLoop
                          (flip pushChunk chunk $ decoder iDec (_getDecodingCompression decoding))
                          (handleMsg v1) (handleEof v1) nextChunk

-- | Handle Bidirectional-Streaming RPCs.
handleBiDiStream ::
     ProtoBufBothSides i o
  -> RPC
  -> BiDiStreamHandler i o a
  -> WaiHandler
handleBiDiStream (iDec, oEnc) rpc handler0 decoding encoding req write flush = do
    handler0 req >>= go ""
  where
    nextChunk = getRequestBodyChunk req
    reply msg = write (encode oEnc (_getEncodingCompression encoding) msg) >> flush
    go chunk (v0, bStream) = do
        let cont dat v1 = go dat (v1, bStream)
        step <- (bidirNextStep bStream) v0
        case step of
            WaitInput handleMsg handleEof -> do
                handleRequestChunksLoop (flip pushChunk chunk
                                         $ decoder iDec
                                         $ _getDecodingCompression decoding)
                                        (\dat msg -> handleMsg v0 msg >>= cont dat)
                                        (handleEof v0 >>= cont "")
                                        nextChunk
            WriteOutput v1 msg -> do
                reply msg
                cont "" v1
            Abort -> return ()

-- | A GeneralStreamHandler combining server and client asynchronous streams.
type GeneralStreamHandler i o a b =
    Request -> IO (a, IncomingStream i a, b, OutgoingStream o b)

-- | Pair of handlers for reacting to incoming messages.
data IncomingStream i a = IncomingStream {
    incomingStreamHandler   :: a -> i -> IO a
  , incomingStreamFinalizer :: a -> IO ()
  }

-- | Handler to decide on the next message (if any) to return.
data OutgoingStream o a = OutgoingStream {
    outgoingStreamNext  :: a -> IO (Maybe (a, o))
  }

-- | Handler for the somewhat general case where two threads behave concurrently:
-- - one reads messages from the client
-- - one returns messages to the client
handleGeneralStream ::
     ProtoBufBothSides i o
  -> RPC
  -> GeneralStreamHandler i o a b
  -> WaiHandler
handleGeneralStream (iDec, oEnc) rpc handler0 decoding encoding req write flush = void $ do
    handler0 req >>= go
  where
    newDecoder = decoder iDec $ _getDecodingCompression decoding
    nextChunk = getRequestBodyChunk req
    reply msg = write (encode oEnc (_getEncodingCompression encoding) msg) >> flush

    go (in0, instream, out0, outstream) = concurrently
        (incomingLoop newDecoder in0 instream)
        (replyLoop out0 outstream)

    replyLoop v0 sstream@(OutgoingStream next) = do
        next v0 >>= \case
            Nothing          -> return v0
            (Just (v1, msg)) -> reply msg >> replyLoop v1 sstream

    incomingLoop decode v0 cstream = do
        let handleMsg dat msg = do
                v1 <- incomingStreamHandler cstream v0 msg
                incomingLoop (pushChunk newDecoder dat) v1 cstream
        let handleEof = incomingStreamFinalizer cstream v0 >> pure v0
        handleRequestChunksLoop decode handleMsg handleEof nextChunk


-- | Helpers to consume input in chunks.
handleRequestChunksLoop
  :: Decoder (Either PBDec.ParseError a)
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
            closeEarly (GRPCStatus INVALID_ARGUMENT (ByteString.pack $ "done-error: " ++ show err))
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
