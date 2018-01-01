{-# LANGUAGE OverloadedStrings #-}
module Main where

import Server

import Control.Concurrent (threadDelay)
import Data.ProtoLens.Message (def)
import Proto.Protos.Grpcbin
import Network.Wai.Handler.WarpTLS (defaultTlsSettings)
import Network.Wai.Handler.Warp (defaultSettings)
import GRPC.Protos.Grpcbin

main :: IO ()
main = runGrpc defaultTlsSettings defaultSettings handlers

handlers :: [ServiceHandler]
handlers =
  [ unary Grpcbin_Empty handleEmpty
  , unary Grpcbin_Index handleIndex
  , unary Grpcbin_SpecificError handleSpecificError
  , unary Grpcbin_RandomError handleRandomError
  , serverStream Grpcbin_DummyServerStream handleDummyServerStream
  , clientStream Grpcbin_DummyClientStream handleDummyClientStream
  ]

handleIndex :: UnaryHandler Grpcbin_Index
handleIndex req input = do
    print input
    return $ IndexReply "desc" [IndexReply'Endpoint "/path1" "description1" def] def

handleEmpty :: UnaryHandler Grpcbin_Empty
handleEmpty req input = do
    print input
    return $ EmptyMessage def

handleSpecificError :: UnaryHandler Grpcbin_SpecificError
handleSpecificError req input = do
    print input
    throwIO $ GRPCStatus INTERNAL "noo"
    return $ EmptyMessage def

handleRandomError :: UnaryHandler Grpcbin_RandomError
handleRandomError req input = do
    print input
    return $ EmptyMessage def

handleDummyServerStream :: ServerStreamHandler Grpcbin_DummyServerStream
handleDummyServerStream req input = do
    print input
    return $ (threadDelay 1000000 >> return (Just input))

handleDummyClientStream :: ClientStreamHandler Grpcbin_DummyClientStream
handleDummyClientStream req input = do
    print input
    return $ def
