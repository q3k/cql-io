-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE TemplateHaskell #-}

module Database.CQL.IO.Cluster.Policies
    ( Policy (..)
    , Result (..)
    , handler_
    , random
    , roundRobin
    , constant
    ) where

import Control.Applicative
import Control.Concurrent.STM
import Control.Lens ((^.), view, over, makeLenses)
import Data.Map.Strict (Map)
import Database.CQL.IO.Cluster.Host
import Network.Socket (SockAddr)
import System.Random.MWC

import qualified Data.Map.Strict as Map

type HostMap = TVar Hosts

data Hosts = Hosts
    { _alive :: Map SockAddr Host
    , _other :: Map SockAddr Host
    }

makeLenses ''Hosts

data Result
    = Accepted
    | Rejected
    | Ignored
    deriving (Eq, Ord, Show)

data Policy = Policy
    { handler :: HostEvent -> IO Result
    , getHost :: IO (Maybe Host)
    }

handler_ :: Policy -> HostEvent -> IO ()
handler_ p e = handler p e >> return ()

-- | Always return the host that first became available.
constant :: IO Policy
constant = do
    r <- newTVarIO Nothing
    return $ Policy (ins r) (readTVarIO r)
  where
    ins r (HostAdded h) = atomically $ do
        x <- readTVar r
        case x of
            Nothing -> writeTVar r (Just h) >> return Accepted
            _       -> return Ignored
    ins _ _ = return Ignored

-- | Iterate over all hosts.
roundRobin :: IO Policy
roundRobin = do
    hhh <- newTVarIO emptyHosts
    ctr <- newTVarIO 0
    return $ Policy (onEvent hhh) (pickHost hhh ctr)
  where
    pickHost hhh ctr = atomically $ do
        m <- view alive <$> readTVar hhh
        k <- readTVar ctr
        writeTVar ctr $ if k < Map.size m - 1 then succ k else 0
        if k < Map.size m
            then return . Just . snd $ Map.elemAt k m
            else return Nothing

-- | Return hosts randomly.
random :: IO Policy
random = do
    hhh <- newTVarIO emptyHosts
    gen <- createSystemRandom
    return $ Policy (onEvent hhh) (pickHost hhh gen)
  where
    pickHost hhh gen = do
        h <- view alive <$> readTVarIO hhh
        let pickRandom = uniformR (0, Map.size h - 1) gen
        if Map.null h
            then return Nothing
            else Just . snd . flip Map.elemAt h <$> pickRandom

-----------------------------------------------------------------------------
-- Defaults

emptyHosts :: Hosts
emptyHosts = Hosts Map.empty Map.empty

onEvent :: HostMap -> HostEvent -> IO Result
onEvent r (HostAdded h) = atomically $ do
    m <- readTVar r
    case get (h^.hostAddr) m of
        Nothing -> do
            writeTVar r (over alive (Map.insert (h^.hostAddr) h) m)
            return Accepted
        _  -> return Ignored
onEvent r (HostRemoved s) = atomically $ do
    h <- readTVar r
    if Map.member s (h^.alive)
        then writeTVar r (over alive (Map.delete s) h)
        else writeTVar r (over other (Map.delete s) h)
    return Accepted
onEvent r (HostUp s) = atomically $ do
    h <- readTVar r
    case get s h of
        Nothing -> return ()
        Just  x -> do
            writeTVar (x^.status) StatusUp
            writeTVar r (over alive (Map.insert s x) . over other (Map.delete s) $ h)
    return Accepted
onEvent r (HostDown s) = atomically $ do
    h <- readTVar r
    case get s h of
        Nothing -> return ()
        Just  x -> do
            writeTVar (x^.status) StatusDown
            writeTVar r (over other (Map.insert s x) . over alive (Map.delete s) $ h)
    return Accepted

get :: SockAddr -> Hosts -> Maybe Host
get a h = Map.lookup a (h^.alive) <|> Map.lookup a (h^.other)
