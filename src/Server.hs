{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- TODO:
-- * read timeout
-- * proper primitives for streaming
module Server
    ( runGrpc
    , UnaryHandler
    , ServerStreamHandler
    , ClientStreamHandler
    -- * registration
    , ServiceHandler
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

import Control.Exception (Exception, catch, throwIO)
import qualified Data.List as List
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Binary.Builder (Builder, fromByteString, singleton, putWord32be)
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.Binary.Get (getByteString, getInt8, getWord32be, pushChunk, runGet, runGetIncremental, Decoder(..))
import qualified Data.ByteString.Char8 as ByteString
import Data.ProtoLens.Encoding (encodeMessage, decodeMessage)
import Data.ProtoLens.Message (Message)
import Network.GRPC (RPC(..), Input, Output)
import Network.HTTP.Types (status200, status404)
import Network.Wai (Application, Request, rawPathInfo, responseLBS, responseStream, requestBody, strictRequestBody)
import Network.Wai.Handler.WarpTLS (runTLS)
import Network.Wai.Handler.Warp (http2dataTrailers, defaultHTTP2Data, modifyHTTP2Data, HTTP2Data)

grpcApp :: [ServiceHandler] -> Application
grpcApp service req rep = do
    let hdrs200 = [
            ("content-type", "application/grpc")
          , ("trailer", "Grpc-Status")
          , ("trailer", "Grpc-Message")
          ]
    case lookupHandler (rawPathInfo req) service of
        Just (ServiceHandler (rpc, action)) ->
            rep $ responseStream status200 hdrs200 $ action req
        Nothing ->
            rep $ responseLBS status404 [] $ fromStrict ("not found: " <> rawPathInfo req)

type WaiHandler =
     Request
  -> (Builder -> IO ())
  -> IO ()
  -> IO ()

data ServiceHandler = forall rpc. RPC rpc => ServiceHandler (rpc, WaiHandler)

type UnaryHandler rpc = Request -> Input rpc -> IO (Output rpc)
type ServerStreamHandler rpc = Request -> Input rpc -> IO (IO (Maybe (Output rpc)))
type ClientStreamHandler rpc = Request -> Either String (Input rpc) -> IO ()

unary :: RPC rpc => rpc -> UnaryHandler rpc -> ServiceHandler
unary rpc handler =
    ServiceHandler (rpc, handleUnary rpc handler)

serverStream :: RPC rpc => rpc -> ServerStreamHandler rpc -> ServiceHandler
serverStream rpc handler =
    ServiceHandler (rpc, handleServerStream rpc handler)

clientStream :: RPC rpc => rpc -> ClientStreamHandler rpc -> ServiceHandler
clientStream rpc handler =
    ServiceHandler (rpc, handleClientStream rpc handler)

lookupHandler :: ByteString.ByteString -> [ServiceHandler] -> Maybe ServiceHandler
lookupHandler p plainHandlers =
    List.find (\(ServiceHandler (rpc, _)) -> path rpc == p) plainHandlers

handleUnary ::
     (RPC rpc)
  => rpc
  -> UnaryHandler rpc
  -> WaiHandler
handleUnary _ handler req write flush = do
        parsed <- decodePayload . toStrict <$> strictRequestBody req
        let handleParseSuccess msg = do
                bin <- encodeMessage <$> handler req msg
                write $ singleton 0 <> putWord32be (fromIntegral $ ByteString.length bin) <> fromByteString bin
                flush
                modifyHTTP2Data req (makeTrailers (GRPCStatus OK ""))
        let handleParseFailure err = do
                modifyHTTP2Data req (makeTrailers (GRPCStatus INTERNAL (ByteString.pack err)))
        (either handleParseFailure handleParseSuccess parsed) `catch` \e -> do
            modifyHTTP2Data req (makeTrailers e)

handleServerStream ::
     (RPC rpc)
  => rpc
  -> ServerStreamHandler rpc
  -> WaiHandler
handleServerStream _ handler req write flush = do
        parsed <- decodePayload . toStrict <$> strictRequestBody req
        let handleParseSuccess msg = do
                getMsg <- handler req msg
                let go = getMsg >>= \case
                        Just dat -> do
                            let bin = encodeMessage dat
                            write $ singleton 0 <> putWord32be (fromIntegral $ ByteString.length bin) <> fromByteString bin
                            flush
                            go
                        Nothing -> do
                            modifyHTTP2Data req (makeTrailers (GRPCStatus OK ""))
                go
        let handleParseFailure err = do
                modifyHTTP2Data req (makeTrailers (GRPCStatus INTERNAL (ByteString.pack err)))
        (either handleParseFailure handleParseSuccess parsed) `catch` \e -> do
            modifyHTTP2Data req (makeTrailers e)

handleClientStream ::
     (RPC rpc)
  => rpc
  -> ClientStreamHandler rpc
  -> WaiHandler
handleClientStream _ handler req write flush = do
    let loop decoder = do
            dat <- requestBody req
            handleAllChunks decoder dat loop
    loop decodeResult `catch` \e -> do
        modifyHTTP2Data req (makeTrailers e)
  where
    handleAllChunks decoder dat exitLoop =
       case pushChunk decoder dat of
           (Done unusedDat _ val) -> do
               handler req val
               handleAllChunks decodeResult unusedDat exitLoop
           failure@(Fail _ _ err)   -> do
               throwIO (GRPCStatus INTERNAL (ByteString.pack err))
           partial@(Partial _)    ->
               exitLoop partial

decodeResult :: Message a => Decoder (Either String a)
decodeResult = runGetIncremental $ do
    0 <- getInt8      -- 1byte
    n <- getWord32be  -- 4bytes
    decodeMessage <$> getByteString (fromIntegral n)

decodePayload :: Message a => ByteString.ByteString -> Either String a
decodePayload bin
  | ByteString.length bin < fromIntegral 5 =
        Left "not enough data for small in-data Proto header"
  | otherwise =
        runGet go (fromStrict bin)
  where
    go = do
        0 <- getInt8      -- 1byte
        n <- getWord32be  -- 4bytes
        if ByteString.length bin < fromIntegral (5 + n)
        then
            return $ Left "not enough data for decoding"
        else 
            decodeMessage <$> getByteString (fromIntegral n)

-- https://grpc.io/grpc/core/impl_2codegen_2status_8h.html#a35ab2a68917eb836de84cb23253108eb
data GRPCStatusCode =
    OK
  | CANCELLED
  | UNKNOWN
  | INVALID_ARGUMENT
  | DEADLINE_EXCEEDED
  | NOT_FOUND
  | ALREADY_EXISTS
  | PERMISSION_DENIED
  | UNAUTHENTICATED
  | RESOURCE_EXHAUSTED
  | FAILED_PRECONDITION
  | ABORTED
  | OUT_OF_RANGE
  | UNIMPLEMENTED
  | INTERNAL
  | UNAVAILABLE
  | DATA_LOSS
  deriving Show

trailerForStatusCode :: GRPCStatusCode -> ByteString.ByteString
trailerForStatusCode = \case
    OK
      -> "0"
    CANCELLED
      -> "1"
    UNKNOWN
      -> "2"
    INVALID_ARGUMENT
      -> "3"
    DEADLINE_EXCEEDED
      -> "4"
    NOT_FOUND
      -> "5"
    ALREADY_EXISTS
      -> "6"
    PERMISSION_DENIED
      -> "7"
    UNAUTHENTICATED
      -> "16"
    RESOURCE_EXHAUSTED
      -> "8"
    FAILED_PRECONDITION
      -> "9"
    ABORTED
      -> "10"
    OUT_OF_RANGE
      -> "11"
    UNIMPLEMENTED
      -> "12"
    INTERNAL
      -> "13"
    UNAVAILABLE
      -> "14"
    DATA_LOSS
      -> "15"

type GRPCStatusMessage = ByteString.ByteString

data GRPCStatus = GRPCStatus !GRPCStatusCode !GRPCStatusMessage
  deriving Show
instance Exception GRPCStatus

makeTrailers :: GRPCStatus -> (Maybe HTTP2Data -> Maybe HTTP2Data)
makeTrailers (GRPCStatus s msg) h2data =
    Just $! (fromMaybe defaultHTTP2Data h2data) { http2dataTrailers = trailers }
  where
    trailers = if ByteString.null msg then [status] else [status, message]
    status = ("grpc-status", trailerForStatusCode s)
    message = ("grpc-message", msg)

runGrpc tlsSettings settings handlers = runTLS tlsSettings settings (grpcApp handlers)
