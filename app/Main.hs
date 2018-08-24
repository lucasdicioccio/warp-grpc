{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
module Main where

import Network.GRPC.Server

import Control.Concurrent (threadDelay)
import Data.ProtoLens.Message (def)
import Network.Wai.Handler.WarpTLS (defaultTlsSettings)
import Network.Wai.Handler.Warp (defaultSettings)
import Network.GRPC.HTTP2.Types (RPC(..))
import Proto.Protos.Grpcbin (GRPCBin, EmptyMessage(..), IndexReply(..), IndexReply'Endpoint(..))

main :: IO ()
main = runGrpc defaultTlsSettings defaultSettings handlers

handlers :: [ServiceHandler]
handlers =
  [ unary (RPC :: RPC GRPCBin "empty") handleEmpty
  , unary (RPC :: RPC GRPCBin "index") handleIndex
  , unary (RPC :: RPC GRPCBin "specificError") handleSpecificError
  , unary (RPC :: RPC GRPCBin "randomError") handleRandomError
  , serverStream (RPC :: RPC GRPCBin "dummyServerStream") handleDummyServerStream
  , clientStream (RPC :: RPC GRPCBin "dummyClientStream") handleDummyClientStream
  ]

handleIndex :: UnaryHandler GRPCBin "index"
handleIndex _ input = do
    print input
    return $ IndexReply "desc" [IndexReply'Endpoint "/path1" "ill-supported" def] def

handleEmpty :: UnaryHandler GRPCBin "empty"
handleEmpty _ input = do
    print input
    return $ EmptyMessage def

handleSpecificError :: UnaryHandler GRPCBin "specificError"
handleSpecificError _ input = do
    print input
    _ <- throwIO $ GRPCStatus INTERNAL "noo"
    return $ EmptyMessage def

handleRandomError :: UnaryHandler GRPCBin "randomError"
handleRandomError _ input = do
    print input
    return $ EmptyMessage def

handleDummyServerStream :: ServerStreamHandler GRPCBin "dummyServerStream"
handleDummyServerStream _ input = do
    print input
    return $ (threadDelay 1000000 >> return (Just input))

handleDummyClientStream :: ClientStreamHandler GRPCBin "dummyClientStream"
handleDummyClientStream _ input = do
    print input
    return $ def
