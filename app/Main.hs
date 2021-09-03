{-# LANGUAGE OverloadedStrings #-}
module Main where


import           Control.Monad                   (void, when)
import           Data.ByteString.Lazy            (ByteString)
import           Data.Either                     (isLeft)
import           Data.IOMap                      (IOMap)
import qualified Data.IOMap                      as HM
import           Data.Int                        (Int64)
import           Data.Streaming.Network.Internal (HostPreference (Host))
import           Network.HTTP.Types              (status200)
import           Network.Wai                     (Application, responseLBS,
                                                  strictRequestBody)
import qualified Network.Wai.Handler.Warp        as W (defaultSettings,
                                                       runSettings, setHost,
                                                       setPort)
import           Network.Wai.Handler.WebSockets  (websocketsOr)
import qualified Network.WebSockets              as WS (Connection,
                                                        DataMessage (..),
                                                        ServerApp,
                                                        acceptRequest,
                                                        defaultConnectionOptions,
                                                        receiveDataMessage,
                                                        sendDataMessage)
import           Network.WebSockets.Connection   as WS (pingThread)
import           Options.Applicative             (Parser (..), auto, execParser,
                                                  fullDesc, help, helper, info,
                                                  long, metavar, option,
                                                  progDesc, short, strOption,
                                                  value)
import           UnliftIO                        (Async, MonadIO (..),
                                                  MonadUnliftIO, TVar, async,
                                                  atomically, cancel, newTVarIO,
                                                  readTVar, tryIO, waitCatch,
                                                  writeTVar)

data Options = Options
  { getHost :: String
  , getPort :: Int
  }

parser :: Parser Options
parser = Options <$> strOption (long "host"
                                <> short 'H'
                                <> metavar "HOST"
                                <> help "Http2ws server host."
                                <> value "127.0.0.1")
                 <*> option auto (long "port"
                                  <> short 'p'
                                  <> metavar "PORT"
                                  <> help "Http2ws server port."
                                  <> value 8000 )

main :: IO ()
main = execParser opts >>= program
  where
    opts = info (helper <*> parser)
      (fullDesc
       <> progDesc "Http2ws Server" )

program :: Options -> IO ()
program opts = do
  connHandle <- HM.empty
  gen <- newTVarIO 0

  W.runSettings settings
    $ websocketsOr WS.defaultConnectionOptions (wsApp connHandle gen) (webApp connHandle)

  where port = getPort opts
        host = getHost opts
        settings = W.setPort port . W.setHost (Host host) $ W.defaultSettings

webApp :: ConnHandle -> Application
webApp connHandle req respond = do
  wb <- strictRequestBody req
  void $ async $ sendData connHandle wb
  respond $ responseLBS status200 [] "{\"result\": \"OK\"}"

wsApp :: ConnHandle -> TVar Int64 -> WS.ServerApp
wsApp connHandle gen pendingConn = do
  conn <- WS.acceptRequest pendingConn
  io0 <- async $ WS.pingThread conn 30 (return ())
  io1 <- async $ void $ WS.receiveDataMessage conn
  idx <- genNextId gen
  HM.insert idx (conn, io0) connHandle
  void $ waitCatch io0
  cancel io1
  HM.delete idx connHandle


type ConnHandle = IOMap Int64 (WS.Connection, Async ())

genNextId :: MonadIO m => TVar Int64 -> m Int64
genNextId gen = atomically $ do
  v <- readTVar gen
  writeTVar gen (v + 1)
  return v


sendData :: MonadUnliftIO m => ConnHandle -> ByteString -> m ()
sendData connHandle bs =
  HM.elems connHandle
    >>= mapM_ (sendOneData bs)

sendOneData :: MonadUnliftIO m => ByteString -> (WS.Connection, Async ()) -> m ()
sendOneData bs (conn, io) = void $ async $ do
  r <- liftIO $ tryIO $ WS.sendDataMessage conn (WS.Text bs Nothing)

  when (isLeft r) $ cancel io
