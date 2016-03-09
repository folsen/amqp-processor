{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE StandaloneDeriving         #-}

module AMQP.Processor
  ( process
  , RetryStatus(..)
  , ProcessingResponse(..)
  )
  where

import           Control.Concurrent
import           Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import           Control.Exception
import           Control.Lens            ((&), (.~), (^?))
import           Control.Monad
import qualified Data.Aeson              as JSON
import           Data.Aeson.Lens         (key, _Integer)
import qualified Data.Aeson.Types        as JSON (Result (..), parse)
import qualified Data.Map                as Map
import           Data.Maybe
import           Data.Monoid
import           Data.String
import qualified Data.Text               as T
import           GHC.Generics
import           Network.AMQP
import           Network.AMQP.Types
import           System.Environment
import           System.Posix.Signals    (Handler (Catch), installHandler,
                                          sigINT, sigTERM)

type DelayDuration = Int
type RoutingKey = T.Text

newtype QueueName = QueueName { fromQueueName :: String }
  deriving (Eq, Show, Read, IsString)

data RetryStatus = DoRetry Int | DontRetry

data MessagePayload a = MessagePayload
  { retries :: Int
  , payload :: a
  } deriving (Show, Generic)

instance JSON.FromJSON a => JSON.FromJSON (MessagePayload a)
instance JSON.ToJSON a => JSON.ToJSON (MessagePayload a)

data ProcessingResponse = ProcessingSuccess | ProcessingRetry String
  deriving (Show)

data ProcessingOpts = ProcessingOpts
  { processQueueName   :: String
  , processRetryPolicy :: RetryPolicy
  , processWorkerFn    :: JSON.Value -> IO (JSON.Result ProcessingResponse)
  }

type RetryPolicy = Integer -> RetryStatus

defaultRetryPolicy :: Integer -> RetryStatus
defaultRetryPolicy 0 = DoRetry 500
defaultRetryPolicy 1 = DoRetry 1000
defaultRetryPolicy 2 = DoRetry 2000
defaultRetryPolicy 3 = DoRetry 4000
defaultRetryPolicy 4 = DoRetry 8000
defaultRetryPolicy 5 = DoRetry 16000
defaultRetryPolicy _ = DontRetry

process :: JSON.FromJSON a
        => QueueName
        -> RetryPolicy
        -> (a -> IO ProcessingResponse)
        -> IO ()
process q p f =
  processOptions $ ProcessingOpts
    { processQueueName   = fromQueueName q
    , processRetryPolicy = p
    , processWorkerFn    = traverse f . JSON.parse JSON.parseJSON
    }

processOptions :: ProcessingOpts -> IO ()
processOptions opts = do
  -- Exceptions that can happen here are AMQP exceptions,
  -- like losing connection
  catch (subscribeToQueue opts)
        (retryOpening opts)

retryOpening :: ProcessingOpts -> SomeException -> IO ()
retryOpening opts e = do
  putStrLn $ "Exception occurred from AMQP thread (restarting in 5s): " ++ show e
  threadDelay 5000000 -- 5s
  processOptions opts

subscribeToQueue :: ProcessingOpts -> IO ()
subscribeToQueue opts = do
  -- Read AMQP_URL from environment and use that.
  -- If the variable is empty, the defaults will be used (localhost)
  amqpUrl <- lookupEnv "AMQP_URL"
  let connectionOpts = fromURI $ fromMaybe "" amqpUrl
  -- Open connection and add a handler to restart if its closed
  conn <- openConnection'' connectionOpts
  addConnectionClosedHandler conn True (processOptions opts)
  -- Open channel and add handler if any exception occurrs
  chan <- openChannel conn
  addChannelExceptionHandler chan (closeAndRetry conn opts)
  putStrLn "connection opened"

  -- subscribe to the queue
  consumeMsgs chan (T.pack $ processQueueName opts) Ack (workHandler conn opts)

  -- Set up interruption handlers to close the connection on sigint or sigterm
  interruptVar <- newEmptyMVar
  installHandler sigINT  (Catch $ sigHandler interruptVar) Nothing
  installHandler sigTERM (Catch $ sigHandler interruptVar) Nothing
  closeConnectionOnInterrupt conn interruptVar

sigHandler :: MVar Int -> IO ()
sigHandler interruptVar = putMVar interruptVar 1

closeConnectionOnInterrupt :: Connection -> MVar a -> IO ()
closeConnectionOnInterrupt conn var = do
  _ <- readMVar var
  closeConnection conn
  putStrLn "connection closed"

closeAndRetry :: Connection -> ProcessingOpts -> SomeException -> IO ()
closeAndRetry conn opts e = do
  closeConnection conn
  putStrLn "connection closed"
  retryOpening opts e

workHandler :: Connection -> ProcessingOpts -> (Message,Envelope) -> IO ()
workHandler conn opts pkg = do
  forkIO $ catch
    (fnWrapper conn pkg opts)
    (attemptRetry conn pkg opts)
  return ()

fnWrapper :: Connection -> (Message, Envelope) -> ProcessingOpts -> IO ()
fnWrapper conn (msg, env) opts = do
  putStrLn $ "processing message with envelope delivery tag: " ++ show (envDeliveryTag env)
  let eObj = JSON.eitherDecode (msgBody msg)
  case eObj :: Either String (MessagePayload JSON.Value) of
    Left err -> do
      putStrLn $ "message does not contain valid JSON (" ++ err ++ "), throwing it away"
      ackEnv env
    Right obj -> do
      response <- processWorkerFn opts $ payload obj
      case response of
        JSON.Success ProcessingSuccess   -> ackEnv env
        JSON.Success (ProcessingRetry e) -> error e
        JSON.Error err -> do
          putStrLn $ "message payload does not contain valid JSON (" ++ err ++ "), throwing it away"
          ackEnv env

attemptRetry :: Connection -> (Message, Envelope) -> ProcessingOpts -> SomeException -> IO ()
attemptRetry conn (msg, env) opts e = do
  putStrLn $ "Exception in worker task: " ++ show e
  case (msgBody msg) ^? key "retries" . _Integer of
    Just count ->
      case processRetryPolicy opts count of
        DoRetry delay -> do
          let increasedCount = (msgBody msg) & key "retries" .~ JSON.Number (fromIntegral $ count + 1)
          putStrLn $ "Requeuing message to resend in " ++ show delay ++ "ms"
          postDelayed conn (newMsg {msgBody = increasedCount}) delay (T.pack $ processQueueName opts)
        DontRetry -> do
          putStrLn $ "Maximum number of retries have been reached. Throwing message away"
    Nothing ->
      putStrLn "There was a problem decoding and fetching retry count from  msg body in reportAndRequeue. Message will be discarded."
  -- Ack this msg so it gets off the queue it came from, since we're replacing
  -- it on the delayed queue
  ackEnv env

postDelayed :: Connection -> Message -> DelayDuration -> RoutingKey -> IO ()
postDelayed conn msg delayDuration routingKey = do
  chan <- openChannel conn
  let holdQueueName = "delay." <> T.pack (show delayDuration) <> "." <> routingKey
      holdQueueHeaders =
        FieldTable $ Map.fromList [ -- Send to default exchange after TTL expiration
                                    ("x-dead-letter-exchange", FVString "")
                                    -- Routing key to use when resending
                                  , ("x-dead-letter-routing-key", FVString routingKey)
                                    -- Time in milliseconds to hold the
                                    -- message before resending
                                  , ("x-message-ttl", FVInt32 $ fromIntegral delayDuration)
                                    -- Time after the queue will be
                                    -- deleted if unused
                                  , ("x-expires", FVInt32 . fromIntegral $ delayDuration * 2)
                                  ]
      holdQueue = newQueue {queueName = holdQueueName, queueHeaders = holdQueueHeaders}

  -- Make sure queue is set up (also resets TTL for x-expires)
  declareQueue chan holdQueue
  -- Publish the msg to hold on the hold queue
  publishMsg chan "" holdQueueName msg
  closeChannel chan
