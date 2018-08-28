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
main = runGrpc defaultTlsSettings defaultSettings handlers [gzip]

handlers :: [ServiceHandler]
handlers =
  [ unary (RPC :: RPC GRPCBin "empty") handleEmpty
  , unary (RPC :: RPC GRPCBin "index") handleIndex
  , unary (RPC :: RPC GRPCBin "specificError") handleSpecificError
  , unary (RPC :: RPC GRPCBin "randomError") handleRandomError
  , unary (RPC :: RPC GRPCBin "dummyUnary") handleDummyUnary
  , serverStream (RPC :: RPC GRPCBin "dummyServerStream") handleDummyServerStream
  , clientStream (RPC :: RPC GRPCBin "dummyClientStream") handleDummyClientStream
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

handleDummyUnary :: UnaryHandler GRPCBin "dummyUnary"
handleDummyUnary _ input = pure input

handleDummyServerStream :: ServerStreamHandler GRPCBin "dummyServerStream" Int
handleDummyServerStream _ input = do
    print ("sstream-start"::[Char], input)
    return $ (10, ServerStream $ \n -> do
        threadDelay 1000000
        if n == 0
        then print ("sstream-end"::[Char]) >> return Nothing
        else do
            print ("sstream-msg"::[Char], n)
            return $ Just (n-1, def))

handleDummyClientStream :: ClientStreamHandler GRPCBin "dummyClientStream" Int
handleDummyClientStream _ = do
    print ("cstream-start"::[Char])
    return $ (0, ClientStream
                     (\n input -> print ("cstream-msg"::[Char], n, input) >> return (n+1))
                     (\n -> print ("cstream-end"::[Char], n) >> return def))
