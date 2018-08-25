{-# LANGUAGE OverloadedStrings #-}

module Network.GRPC.Server.Wai where

import           Data.ByteString.Char8 (ByteString)
import           Data.ByteString.Lazy (fromStrict)
import           Data.Binary.Builder (Builder) 
import qualified Data.List as List
import           Network.GRPC.HTTP2.Types (grpcContentTypeHV, grpcStatusHV, grpcMessageHV)
import           Network.HTTP.Types (status200, status404)
import           Network.Wai (Application, Request(..), rawPathInfo, responseLBS, responseStream)

-- | A Wai Handler for a request.
type WaiHandler =
     Request
  -- ^ Request object.
  -> (Builder -> IO ())
  -- ^ Write a data chunk in the reply.
  -> IO ()
  -- ^ Flush the output.
  -> IO ()

-- | Untyped gRPC Service handler.
data ServiceHandler = ServiceHandler {
    grpcHandlerPath :: ByteString
  -- ^ Path to the Service to be handled.
  , grpcWaiHandler  :: WaiHandler
  -- ^ Actual request handler.
  }

-- | Build a WAI 'Application' from a list of ServiceHandler.
--
-- Currently, gRPC calls are lookuped up by traversing the list of ServiceHandler.
-- This lookup may be inefficient for large amount of servics.
grpcApp :: [ServiceHandler] -> Application
grpcApp services =
    grpcService services err404app
  where
    err404app :: Application
    err404app req rep =
        rep $ responseLBS status404 [] $ fromStrict ("not found: " <> rawPathInfo req)

-- | Build a WAI 'Middleware' from a list of ServiceHandler.
--
-- Currently, gRPC calls are lookuped up by traversing the list of ServiceHandler.
-- This lookup may be inefficient for large amount of services.
grpcService :: [ServiceHandler] -> (Application -> Application)
grpcService services app = \req rep -> do
    case lookupHandler (rawPathInfo req) services of
        Just handler ->
            rep $ responseStream status200 hdrs200 $ handler req
        Nothing ->
            app req rep
  where
    hdrs200 = [
        ("content-type", grpcContentTypeHV)
      , ("trailer", grpcStatusHV)
      , ("trailer", grpcMessageHV)
      ]
    lookupHandler :: ByteString -> [ServiceHandler] -> Maybe WaiHandler
    lookupHandler p plainHandlers = grpcWaiHandler <$>
        List.find (\(ServiceHandler rpcPath _) -> rpcPath == p) plainHandlers
