module Pos.Infra.Reporting.NodeInfo
    ( extendWithNodeInfo
    , getNodeInfo
    , extendRTDesc
    ) where

import           Universum

import           Data.Bits (Bits (..))
import           Formatting (sformat, stext, (%))
import           Network.Info (IPv4 (..), getNetworkInterfaces, ipv4)
import           Serokell.Util.Text (listBuilderJSON)

import           Pos.Infra.Diffusion.Types (Diffusion (..))

-- The bcc-report-server has been switched off and removing code that
-- depends on it makes building other projects like bcc-cole-proxy
-- easier. We leave the API here, but turn all operations into a NO-OP.

extendWithNodeInfo :: MonadIO m => Diffusion m -> reportType -> m reportType
extendWithNodeInfo _oq rt = pure rt

-- | Uses a 'Diffusion' to get a text representation of the current network
-- state as seen by this node. Also includes this node's external IP addresses.
-- FIXME whether to include IP addresses should be decided by the diffusion.
getNodeInfo :: MonadIO m => Diffusion m -> m Text
getNodeInfo diffusion = do
    statusText <- formatStatus diffusion sformat
    (ips :: [Text]) <-
        map show . filter ipExternal . map ipv4 <$> liftIO getNetworkInterfaces
    pure $ sformat outputF (pretty $ listBuilderJSON ips) statusText
  where
    ipExternal (IPv4 w) =
        not $ ipv4Local w || w == 0 || w == 16777343 -- the last is 127.0.0.1
    outputF = ("{ nodeIps: '"%stext%"', peers: '"%stext%"' }")

-- checks if ipv4 is from local range
ipv4Local :: Word32 -> Bool
ipv4Local w =
    or [b1 == 10, b1 == 172 && b2 >= 16 && b2 <= 31, b1 == 192 && b2 == 168]
  where
    b1 = w .&. 0xff
    b2 = (w `shiftR` 8) .&. 0xff

extendRTDesc :: Text -> reportType -> reportType
extendRTDesc _ x = x
