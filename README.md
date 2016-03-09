# AMQP Processor

The intention of this library is to provide an easy to way to plugin any
function and datatype to process messages on a queue.


### Sample usage

The following example expects JSON items to be on the queue in the
following format:

```
{ retries: 0, payload: {itemId: 1, itemBody: "sample item"} }
```

```
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
module Main where

import GHC.Generics
import qualified Data.Aeson as JSON
import qualified Data.Text as T

import AMQP.Processor

data QueueItem = QueueItem
  { itemId :: Int
  , itemBody :: T.Text
  } deriving (Eq, Show, Generic)

instance JSON.FromJSON QueueItem
instance JSON.ToJSON QueueItem

main :: IO ()
main = process "queue_name" retryPolicy $ \i -> do
  putStrLn $ "Processing item: " ++ show i
  return $ ProcessingSuccess

retryPolicy :: Integer -> RetryStatus
retryPolicy 0 = DoRetry 500
retryPolicy 1 = DoRetry 1000
retryPolicy 2 = DoRetry 1500
retryPolicy 3 = DoRetry 1500
retryPolicy 4 = DoRetry 1500
retryPolicy 5 = DoRetry 1500
retryPolicy _ = DontRetry
```
