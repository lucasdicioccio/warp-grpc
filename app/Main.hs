{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
module Main where

import Network.GRPC.Server

import Control.Concurrent (threadDelay)
import Data.ProtoLens.Message (def)
import Network.Wai.Handler.WarpTLS (defaultTlsSettings)
import Network.Wai.Handler.Warp (defaultSettings)
import Network.GRPC.HTTP2.Types (RPC(..))
import Network.GRPC.HTTP2.Encoding (gzip)
import Proto.Protos.Grpcbin (GRPCBin, EmptyMessage(..), IndexReply(..), IndexReply'Endpoint(..))

main :: IO ()
main = runGrpc defaultTlsSettings defaultSettings handlers

handlers :: [ServiceHandler]
handlers =
  [ unary (RPC :: RPC GRPCBin "empty") gzip handleEmpty
  , unary (RPC :: RPC GRPCBin "index") gzip handleIndex
  , unary (RPC :: RPC GRPCBin "specificError") gzip handleSpecificError
  , unary (RPC :: RPC GRPCBin "randomError") gzip handleRandomError
  , serverStream (RPC :: RPC GRPCBin "dummyServerStream") gzip handleDummyServerStream
  , clientStream (RPC :: RPC GRPCBin "dummyClientStream") gzip handleDummyClientStream
  ]

handleIndex :: UnaryHandler GRPCBin "index"
handleIndex _ input = do
    print ("index"::[Char], input)
    return $ IndexReply "desc" [IndexReply'Endpoint "/path1" "ill-supported" def] def

handleEmpty :: UnaryHandler GRPCBin "empty"
handleEmpty _ input = do
    print ("empty"::[Char], input)
    return $ EmptyMessage def

handleSpecificError :: UnaryHandler GRPCBin "specificError"
handleSpecificError _ input = do
    print ("specificError"::[Char], input)
    _ <- throwIO $ GRPCStatus INTERNAL "noo"
    return $ EmptyMessage def

handleRandomError :: UnaryHandler GRPCBin "randomError"
handleRandomError _ input = do
    print ("randomError"::[Char], input)
    return $ EmptyMessage def

handleDummyServerStream :: ServerStreamHandler GRPCBin "dummyServerStream" Int
handleDummyServerStream _ input = do
    print ("sstream"::[Char], input)
    return $ (10, ServerStream $ \n -> do
        threadDelay 1000000
        if n == 0
        then return Nothing
        else do
            print ("sstream-msg"::[Char])
            return $ Just (n-1, input))

handleDummyClientStream :: ClientStreamHandler GRPCBin "dummyClientStream"
handleDummyClientStream _ = do
    print ("new-cstream"::[Char])
    return $ ClientStream (\input -> print ("cstream"::[Char], input)) (return $ def)
