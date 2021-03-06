{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wall            #-}

module Bcc.NodeIPC (startNodeJsIPC) where

import           Control.Arrow ((>>>))
import           Control.Concurrent (forkIO)
import           Control.Monad.Reader (MonadReader)
import           Data.Aeson (FromJSON (parseJSON), ToJSON (toEncoding),
                     defaultOptions, eitherDecode, encode, genericParseJSON,
                     genericToEncoding)
import           Data.Aeson.Types (Options, SumEncoding (ObjectWithSingleField),
                     sumEncoding)
import           Data.Binary.Get (getWord32le, getWord64le, runGet)
import           Data.Binary.Put (putLazyByteString, putWord32le, putWord64le,
                     runPut)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Lazy.Char8 as BSLC
import           Distribution.System (OS (Windows), buildOS)
import           GHC.Generics (Generic)
import           GHC.IO.Handle.FD (fdToHandle)
import           System.Environment (lookupEnv)
import           System.IO (hFlush, hGetLine, hSetNewlineMode,
                     noNewlineTranslation)
import           System.IO.Error (IOError, isEOFError)
import           Universum

import           Pos.Infra.InjectFail (FInject, listFInjects, setFInject)
import           Pos.Infra.Shutdown.Class (HasShutdownContext (..))
import           Pos.Infra.Shutdown.Logic (triggerShutdown)
import           Pos.Infra.Shutdown.Types (ShutdownContext (..), shdnFInjects)
import           Pos.Util.Wlog (WithLogger, logError, logInfo, usingLoggerName)

data MsgIn  = QueryPort | Ping | SetFInject FInject Bool
  deriving (Show, Eq, Generic)
data MsgOut = Started | ReplyPort Word16 | Pong | ParseError Text | FInjects [FInject]
  deriving (Show, Eq, Generic)

opts :: Options
opts = defaultOptions { sumEncoding = ObjectWithSingleField }

instance FromJSON MsgIn  where parseJSON = genericParseJSON opts
instance ToJSON   MsgOut where toEncoding = genericToEncoding opts

startNodeJsIPC ::
    (MonadIO m, WithLogger m, MonadReader ctx m, HasShutdownContext ctx)
    => Word16 -> m ()
startNodeJsIPC port = void $ runMaybeT $ do
  ctx <- view shutdownContext
  fdstring <- liftIO (lookupEnv "NODE_CHANNEL_FD") >>= (pure >>> MaybeT)
  case readEither fdstring of
    Left err -> lift $ logError $ "unable to parse NODE_CHANNEL_FD: " <> err
    Right fd -> liftIO $ do
        handle <- fdToHandle fd
        void $ forkIO $ startIpcListener ctx handle port

startIpcListener :: ShutdownContext -> Handle -> Word16 -> IO ()
startIpcListener ctx handle port = usingLoggerName "NodeIPC" $ flip runReaderT ctx (ipcListener handle port)

readInt64 :: Handle -> IO Word64
readInt64 hnd = do
    bs <- BSL.hGet hnd 8
    pure $ runGet getWord64le bs

readInt32 :: Handle -> IO Word32
readInt32 hnd = do
    bs <- BSL.hGet hnd 4
    pure $ runGet getWord32le bs

readMessage :: (MonadIO m, WithLogger m) => Handle -> m BSL.ByteString
readMessage handle = do
    if buildOS == Windows
        then do
            (int1, int2, blob) <- liftIO $ windowsReadMessage handle
            logInfo $ "int is: " <> (show [int1, int2]) <> " and blob is: " <> (show blob)
            return blob
        else
            liftIO $ linuxReadMessage handle

windowsReadMessage :: Handle -> IO (Word32, Word32, BSL.ByteString)
windowsReadMessage handle = do
    int1 <- readInt32 handle
    int2 <- readInt32 handle
    size <- readInt64 handle
    blob <- BSL.hGet handle $ fromIntegral size
    return (int1, int2, blob)

linuxReadMessage :: Handle -> IO BSL.ByteString
linuxReadMessage handle = do
    line <- hGetLine handle
    return $ BSLC.pack line

sendMessage :: Handle -> BSL.ByteString -> IO ()
sendMessage handle blob = do
    if buildOS == Windows
        then sendWindowsMessage handle 1 0 (blob <> "\n")
        else sendLinuxMessage handle blob
    hFlush handle

sendWindowsMessage :: Handle -> Word32 -> Word32 -> BSL.ByteString -> IO ()
sendWindowsMessage handle int1 int2 blob = do
    BSLC.hPut handle $ runPut $ (putWord32le int1) <> (putWord32le int2) <> (putWord64le $ fromIntegral $ BSL.length blob) <> (putLazyByteString blob)

sendLinuxMessage :: Handle -> BSL.ByteString -> IO ()
sendLinuxMessage = BSLC.hPutStrLn

ipcListener ::
    forall m ctx . (MonadCatch m, MonadIO m, WithLogger m, MonadReader ctx m, HasShutdownContext ctx)
    => Handle -> Word16 -> m ()
ipcListener handle port = do
  liftIO $ hSetNewlineMode handle noNewlineTranslation
  shutCtx <- view shutdownContext
  let
    send :: MsgOut -> m ()
    send cmd = liftIO $ sendMessage handle $ encode cmd
    action :: MsgIn -> m ()
    action QueryPort          = send $ ReplyPort port
    action Ping               = send Pong
    action (SetFInject fi en) = do
      liftIO $ setFInject (shutCtx ^. shdnFInjects) fi en
      send =<< FInjects <$> (liftIO $ listFInjects (shutCtx ^. shdnFInjects))
  let
    loop :: m ()
    loop = do
      send Started
      forever $ do
        line <- readMessage handle
        let
          handleMsgIn :: Either String MsgIn -> m ()
          handleMsgIn (Left err)  = send $ ParseError $ toText err
          handleMsgIn (Right cmd) = action cmd
        handleMsgIn $ eitherDecode line
    handler :: IOError -> m ()
    handler err = do
      logError $ "exception caught in NodeIPC: " <> (show err)
      when (isEOFError err) $ logError "its an eof"
      liftIO $ hFlush stdout
      triggerShutdown
  catch loop handler
