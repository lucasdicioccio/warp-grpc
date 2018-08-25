{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- TODO:
-- * read timeout
-- * proper primitives for streaming
module Network.GRPC.Server
    ( runGrpc
    , UnaryHandler
    , ServerStreamHandler
    , ClientStreamHandler
    -- * registration
    , ServiceHandler(..)
    , unary
    , serverStream
    , clientStream
    -- * registration
    , GRPCStatus (..)
    , throwIO
    , GRPCStatusMessage
    , GRPCStatusCode (..)
    -- * low-level
    , grpcApp
    ) where

import Control.Exception (catch, throwIO)
import qualified Data.List as List
import qualified Data.CaseInsensitive as CI
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Binary.Builder (Builder, fromByteString, singleton, putWord32be)
import Data.ByteString.Lazy (fromStrict)
import Data.Binary.Get (pushChunk, Decoder(..))
import qualified Data.ByteString.Char8 as ByteString
import Data.ByteString.Char8 (ByteString)
import Data.ProtoLens.Encoding (encodeMessage)
import Data.ProtoLens.Message (Message)
import Data.ProtoLens.Service.Types (Service(..), HasMethod, HasMethodImpl(..))
import Network.GRPC.HTTP2.Types (RPC(..), GRPCStatus(..), GRPCStatusCode(..), path, trailerForStatusCode, GRPCStatusMessage, grpcContentTypeHV, grpcStatusH, grpcStatusHV, grpcMessageH, grpcMessageHV)
import Network.GRPC.HTTP2.Encoding (Compression, decodeInput)
import Network.HTTP.Types (status200, status404)
import Network.Wai (Application, Request, rawPathInfo, responseLBS, responseStream, requestBody)
import Network.Wai.Handler.WarpTLS (TLSSettings, runTLS)
import Network.Wai.Handler.Warp (Settings, http2dataTrailers, defaultHTTP2Data, modifyHTTP2Data, HTTP2Data)

grpcApp :: [ServiceHandler] -> Application
grpcApp service req rep = do
    let hdrs200 = [
            ("content-type", grpcContentTypeHV)
          , ("trailer", grpcStatusHV)
          , ("trailer", grpcMessageHV)
          ]
    case lookupHandler (rawPathInfo req) service of
        Just handler ->
            rep $ responseStream status200 hdrs200 $ handler req
        Nothing ->
            rep $ responseLBS status404 [] $ fromStrict ("not found: " <> rawPathInfo req)

type WaiHandler =
     Request
  -> (Builder -> IO ())
  -> IO ()
  -> IO ()

data ServiceHandler = ServiceHandler {
    grpcHandlerPath :: ByteString
  , grpcWaiHandler  :: WaiHandler
  }

type UnaryHandler s m = Request -> MethodInput s m -> IO (MethodOutput s m)
type ServerStreamHandler s m = Request -> MethodInput s m -> IO (IO (Maybe (MethodOutput s m)))
type ClientStreamHandler s m = Request -> MethodInput s m -> IO ()

unary :: (Service s, HasMethod s m) => RPC s m -> Compression -> UnaryHandler s m -> ServiceHandler
unary rpc compression handler =
    ServiceHandler (path rpc) (handleUnary rpc compression handler)

serverStream :: (Service s, HasMethod s m) => RPC s m -> Compression -> ServerStreamHandler s m -> ServiceHandler
serverStream rpc compression handler =
    ServiceHandler (path rpc) (handleServerStream rpc compression handler)

clientStream :: (Service s, HasMethod s m) => RPC s m -> Compression -> ClientStreamHandler s m -> ServiceHandler
clientStream rpc compression handler =
    ServiceHandler (path rpc) (handleClientStream rpc compression handler)

lookupHandler :: ByteString -> [ServiceHandler] -> Maybe WaiHandler
lookupHandler p plainHandlers = grpcWaiHandler <$>
    List.find (\(ServiceHandler rpcPath _) -> rpcPath == p) plainHandlers

handleUnary ::
     (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> UnaryHandler s m
  -> WaiHandler
handleUnary rpc compression handler req write flush = do
    let errorOnLeftOver = undefined
    handleRequestChunksLoop (decodeInput rpc compression) (\i -> handler req i >>= reply) errorOnLeftOver nextChunk
      `catch` \e -> do
          modifyHTTP2Trailers req e

  where
    nextChunk = requestBody req
    reply msg = do
        let bin = encodeMessage msg
        write $ singleton 0 <> putWord32be (fromIntegral $ ByteString.length bin) <> fromByteString bin
        flush
        modifyHTTP2Trailers req (GRPCStatus OK "")

handleServerStream ::
     (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> ServerStreamHandler s m
  -> WaiHandler
handleServerStream rpc compression handler req write flush = do
    let errorOnLeftOver = undefined
    handleRequestChunksLoop (decodeInput rpc compression) (\i -> handler req i >>= replyN) errorOnLeftOver nextChunk
  where
    nextChunk = requestBody req
    replyN getMsg = do
        let go = getMsg >>= \case
                Just dat -> do
                    let bin = encodeMessage dat
                    write $ singleton 0 <> putWord32be (fromIntegral $ ByteString.length bin) <> fromByteString bin
                    flush
                    go
                Nothing -> do
                    modifyHTTP2Trailers req (GRPCStatus OK "")
        go

handleClientStream ::
     (Service s, HasMethod s m)
  => RPC s m
  -> Compression
  -> ClientStreamHandler s m
  -> WaiHandler
handleClientStream rpc compression handler req _ _ = do
    handleRequestChunksLoop (decodeInput rpc compression) (handler req) loop nextChunk
      `catch` \e -> do
          modifyHTTP2Trailers req e
  where
    nextChunk = requestBody req
    loop chunk = handleRequestChunksLoop (flip pushChunk chunk $ decodeInput rpc compression) (handler req) loop nextChunk

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
                continue unusedDat
            (Done _ _ (Left err)) -> do
                throwIO (GRPCStatus INTERNAL (ByteString.pack err))
            (Fail _ _ err)         ->
                throwIO (GRPCStatus INTERNAL (ByteString.pack err))
            partial@(Partial _)    ->
                if ByteString.null chunk
                then
                    throwIO (GRPCStatus INTERNAL "early end of request body")
                else
                    handleRequestChunksLoop partial handler continue nextChunk

runGrpc
  :: TLSSettings
  -> Settings
  -> [ServiceHandler]
  -> IO ()
runGrpc tlsSettings settings handlers = runTLS tlsSettings settings (grpcApp handlers)

modifyHTTP2Trailers :: Request -> GRPCStatus -> IO ()
modifyHTTP2Trailers req = modifyHTTP2Data req . makeTrailers

makeTrailers :: GRPCStatus -> (Maybe HTTP2Data -> Maybe HTTP2Data)
makeTrailers (GRPCStatus s msg) h2data =
    Just $! (fromMaybe defaultHTTP2Data h2data) { http2dataTrailers = trailers }
  where
    trailers = if ByteString.null msg then [status] else [status, message]
    status = (CI.mk grpcStatusH, trailerForStatusCode s)
    message = (CI.mk grpcMessageH, msg)
