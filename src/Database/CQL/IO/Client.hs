-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}

module Database.CQL.IO.Client
    ( Settings (..)
    , Pool
    , Client
    , defSettings
    , mkPool
    , runClient
    , send
    , receive
    , request
    , command
    , supportedOptions
    , uncompressed
    , compression
    , cache
    , cacheLookup
    ) where

import Control.Applicative
import Control.Concurrent.Async.Class
import Control.Exception
import Control.Monad.IO.Class
import Control.Monad.Reader
import Data.ByteString (ByteString)
import Data.ByteString.Lazy hiding (ByteString, pack, unpack, elem)
import Data.Pool hiding (Pool)
import Data.Text.Lazy (Text)
import Data.Time
import Data.Word
import Database.CQL.Protocol
import Database.CQL.IO.Cache (Cache)
import Network
import System.IO

import qualified Data.Pool             as P
import qualified Database.CQL.IO.Cache as Cache

type EventHandler = Event -> IO ()

data Settings = Settings
    { setVersion     :: !CqlVersion
    , setCompression :: !Compression
    , setHost        :: !String
    , setPort        :: !Word16
    , setIdleTimeout :: !NominalDiffTime
    , setPoolSize    :: !Word32
    , cacheSize      :: !Int
    , setOnEvent     :: EventHandler
    }

data Pool = Pool
    { sets :: !Settings
    , pool :: !(P.Pool Handle)
    }

data Env = Env
    { conn       :: !Handle
    , settings   :: !Settings
    , queryCache :: !(Cache Text ByteString)
    }

newtype Client a = Client
    { client :: ReaderT Env IO a
    } deriving ( Functor
               , Applicative
               , Monad
               , MonadIO
               , MonadReader Env
               )

instance Async Client Client where
    async = Client . async . client

defSettings :: Settings
defSettings = let handler = const $ return () in
    Settings Cqlv300 noCompression "localhost" 9042 60 4 128 handler

mkPool :: (MonadIO m) => Settings -> m Pool
mkPool s = liftIO $ do
    validateSettings
    Pool s <$> createPool
        connInit
        hClose
        (if setPoolSize s < 4 then 1 else 4)
        (setIdleTimeout s)
        (setPoolSize s)
  where
    validateSettings = do
        Supported ca _ <- supportedOptions (setHost s) (setPort s)
        let c = algorithm (setCompression s)
        unless (c == None || c `elem` ca) $
            fail $ "Compression method not supported, only: " ++ show ca

    connInit = do
        con <- connectTo (setHost s) (PortNumber . fromIntegral . setPort $ s)
        let cmp = setCompression s
        let req = Startup (setVersion s) (algorithm cmp)
        intSend cmp con req
        res <- intReceive cmp con :: IO (Response () ())
        case res of
            RsError _ e -> throw e
            RsEvent _ e -> setOnEvent s e >> return con
            _           -> return con

runClient :: (MonadIO m) => Pool -> Client a -> m a
runClient p a = liftIO $ withResource (pool p) $ \c ->
    runReaderT (client a) . Env c (sets p) =<< Cache.new 1024

supportedOptions :: (MonadIO m) => String -> Word16 -> m Supported
supportedOptions h p = liftIO $
    bracket (connectTo h (PortNumber (fromIntegral p))) hClose $ \c -> do
        intSend noCompression c Options
        b <- intReceive noCompression c :: IO (Response () ())
        case b of
            RsSupported _ s -> return s
            RsError     _ e -> throw e
            _               -> fail "unexpected response"

send :: (Request a) => a -> Client ()
send r = do
    c <- compression
    h <- connection
    liftIO $ intSend c h r

receive :: (Tuple a, Tuple b) => Client (Response a b)
receive = do
    c <- compression
    h <- connection
    r <- liftIO $ intReceive c h
    case r of
        RsError _ e -> throw e
        RsEvent _ e -> do
            f <- asks (setOnEvent . settings)
            liftIO $ f e
            receive
        _           -> return r

request :: (Request r, Tuple a, Tuple b) => r -> Client (Response a b)
request a = send a >> receive

command :: (Request r) => r -> Client ()
command r = void (request r :: Client (Response () ()))

uncompressed :: Client a -> Client a
uncompressed m = do
    s <- asks settings
    local (\e -> e { settings = s { setCompression = noCompression } }) m

compression :: Client Compression
compression = asks (setCompression . settings)

cache :: QueryString a b -> QueryId a b -> Client ()
cache (QueryString k) (QueryId v) = asks queryCache >>= Cache.add k v

cacheLookup :: QueryString a b -> Client (Maybe (QueryId a b))
cacheLookup (QueryString k) = do
    c <- asks queryCache
    v <- Cache.lookup k c
    return (QueryId <$> v)

------------------------------------------------------------------------------
-- Internal

intSend :: (Request a) => Compression -> Handle -> a -> IO ()
intSend f h r = do
    let s = StreamId 1
    c <- case getOpCode r rqCode of
            OcStartup -> return noCompression
            OcOptions -> return noCompression
            _         -> return f
    a <- either (fail "failed to create request") return (pack c False s r)
    hPut h a

intReceive :: (Tuple a, Tuple b) => Compression -> Handle -> IO (Response a b)
intReceive a c = do
    b <- hGet c 8
    h <- case header b of
            Left  e -> fail $ "failed to read response header: " ++ e
            Right h -> return h
    case headerType h of
        RqHeader -> fail "unexpected request header"
        RsHeader -> do
            let len = lengthRepr (bodyLength h)
            x <- hGet c (fromIntegral len)
            case unpack a h x of
                Left  e -> fail $ "failed to read response body: " ++ e
                Right r -> return r

connection :: Client Handle
connection = asks conn
