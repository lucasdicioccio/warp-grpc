

module Network.GRPC.Server.Helpers where

import qualified Data.ByteString.Char8 as ByteString
import           Data.Maybe (fromMaybe)
import           Network.GRPC.HTTP2.Types (GRPCStatus(..), trailerForStatusCode, grpcStatusH, grpcMessageH)
import           Network.Wai (Request)
import           Network.Wai.Handler.Warp (http2dataTrailers, defaultHTTP2Data, modifyHTTP2Data, HTTP2Data)

-- | Helper to set the GRPCStatus on the trailers reply.
modifyGRPCStatus :: Request -> GRPCStatus -> IO ()
modifyGRPCStatus req = modifyHTTP2Data req . makeGRPCTrailers

makeGRPCTrailers :: GRPCStatus -> (Maybe HTTP2Data -> Maybe HTTP2Data)
makeGRPCTrailers (GRPCStatus s msg) h2data =
    Just $! (fromMaybe defaultHTTP2Data h2data) { http2dataTrailers = trailers }
  where
    trailers = if ByteString.null msg then [status] else [status, message]
    status = (grpcStatusH, trailerForStatusCode s)
    message = (grpcMessageH, msg)
