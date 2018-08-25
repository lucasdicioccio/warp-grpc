{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.GRPC.Server.Handlers where

import           Control.Exception (catch, throwIO)
import           Control.Monad (when)
import           Data.Binary.Get (pushChunk, Decoder(..))
import qualified Data.ByteString.Char8 as ByteString
import           Data.ByteString.Char8 (ByteString)
import           Data.ProtoLens.Message (Message)
import           Data.ProtoLens.Service.Types (Service(..), HasMethod, HasMethodImpl(..))
import           Network.GRPC.HTTP2.Encoding (Compression, decodeInput, encodeOutput)
import           Network.GRPC.HTTP2.Types (RPC(..), GRPCStatus(..), GRPCStatusCode(..), path)
import           Network.Wai (Request, requestBody)

import Network.GRPC.Server.Helpers (modifyGRPCStatus)
import Network.GRPC.Server.Wai (WaiHandler, ServiceHandler(..))

-- | Handy type to refer to Handler for 'unary' RPCs handler.
type UnaryHandler s m = Request -> MethodInput s m -> IO (MethodOutput s m)

-- | Handy type for 'server-streaming' RPCs.
type ServerStreamHandler s m = Request -> MethodInput s m -> IO (IO (Maybe (MethodOutput s m)))

-- | Handy type for 'client-streaming' RPCs.
type ClientStreamHandler s m = Request -> MethodInput s m -> IO ()

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
  -> ServerStreamHandler s m
  -> ServiceHandler
serverStream rpc compression handler =
    ServiceHandler (path rpc) (handleServerStream rpc compression handler)

-- | Construct a handler for handling a client-streaming RPC.
clientStream
  :: (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> ClientStreamHandler s m
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
    let errorOnLeftOver rest = throwIO $ GRPCStatus INTERNAL ("left-overs: " <> rest)
    handleRequestChunksLoop (decodeInput rpc compression) (\i -> handler req i >>= reply) errorOnLeftOver nextChunk
      `catch` \e -> do
          modifyGRPCStatus req e
  where
    nextChunk = requestBody req
    reply msg = do
        write (encodeOutput rpc compression msg) >> flush
        modifyGRPCStatus req (GRPCStatus OK "")

-- | Handle Server-Streaming RPCs.
handleServerStream ::
     (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> ServerStreamHandler s m
  -> WaiHandler
handleServerStream rpc compression handler req write flush = do
    let errorOnLeftOver rest = throwIO $ GRPCStatus INTERNAL ("left-overs: " <> rest)
    handleRequestChunksLoop (decodeInput rpc compression) (\i -> handler req i >>= replyN) errorOnLeftOver nextChunk
  where
    nextChunk = requestBody req
    replyN getMsg = do
        let go = getMsg >>= \case
                Just msg -> do
                    write (encodeOutput rpc compression msg) >> flush
                    go
                Nothing -> do
                    modifyGRPCStatus req (GRPCStatus OK "")
        go

-- | Handle Client-Streaming RPCs.
handleClientStream ::
     (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> ClientStreamHandler s m
  -> WaiHandler
handleClientStream rpc compression handler req _ _ = do
    handleRequestChunksLoop (decodeInput rpc compression) (handler req) loop nextChunk
      `catch` \e -> do
          modifyGRPCStatus req e
  where
    nextChunk = requestBody req
    loop chunk = handleRequestChunksLoop (flip pushChunk chunk $ decodeInput rpc compression) (handler req) loop nextChunk

-- | Helpers to consume input in chunks.
handleRequestChunksLoop
  :: (Message a)
  => Decoder (Either String a)
  -- ^ Message decoder.
  -> (a -> IO ())
  -- ^ Handler for a single message.
  -> (ByteString -> IO ())
  -- ^ Continue action when there are leftover data.
  -> IO ByteString
  -- ^ Action to retrieve the next chunk.
  -> IO ()
{-# INLINEABLE handleRequestChunksLoop #-}
handleRequestChunksLoop decoder handler continue nextChunk =
    nextChunk >>= \chunk -> do
        case pushChunk decoder chunk of
            (Done unusedDat _ (Right val)) -> do
                handler val
                when (not . ByteString.null $ unusedDat) $ continue unusedDat
            (Done _ _ (Left err)) -> do
                throwIO (GRPCStatus INTERNAL (ByteString.pack $ "done-error: " ++ err))
            (Fail _ _ err)         ->
                throwIO (GRPCStatus INTERNAL (ByteString.pack $ "fail-error: " ++ err))
            partial@(Partial _)    ->
                if ByteString.null chunk
                then
                    throwIO (GRPCStatus INTERNAL "early end of request body")
                else
                    handleRequestChunksLoop partial handler continue nextChunk
