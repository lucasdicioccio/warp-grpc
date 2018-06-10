{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import Server

import Control.Concurrent (threadDelay)
import Data.ProtoLens.Message (def)
import Proto.Protos.Grpcbin
import Network.Wai.Handler.WarpTLS (defaultTlsSettings)
import Network.Wai.Handler.Warp (defaultSettings)

import Network.GRPC
import Proto.Protos.Grpcbin

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
handleIndex req input = do
    print input
    return $ IndexReply "desc" [IndexReply'Endpoint "/path1" "description1" def] def

handleEmpty :: UnaryHandler GRPCBin "empty"
handleEmpty req input = do
    print input
    return $ EmptyMessage def

handleSpecificError :: UnaryHandler GRPCBin "specificError"
handleSpecificError req input = do
    print input
    throwIO $ GRPCStatus INTERNAL "noo"
    return $ EmptyMessage def

handleRandomError :: UnaryHandler GRPCBin "randomError"
handleRandomError req input = do
    print input
    return $ EmptyMessage def

handleDummyServerStream :: ServerStreamHandler GRPCBin "dummyServerStream"
handleDummyServerStream req input = do
    print input
    return $ (threadDelay 1000000 >> return (Just input))

handleDummyClientStream :: ClientStreamHandler GRPCBin "dummyClientStream"
handleDummyClientStream req input = do
    print input
    return $ def
