{-# LANGUAGE OverloadedStrings,
             RecordWildCards,
             ScopedTypeVariables,
             MultiWayIf #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Network.Kontiki.Raft.Leader
-- Copyright   :  (c) 2013, Nicolas Trangez
-- License     :  BSD-like
--
-- Maintainer  :  ikke@nicolast.be
--
-- This module implements the behavior of a node in 
-- `Network.Kontiki.Types.MLeader' mode.
-----------------------------------------------------------------------------
module Network.Kontiki.Raft.Leader where

import Data.List (sortBy)

import qualified Data.Map as Map
import qualified Data.Set as Set

import Data.ByteString.Char8 ()

import Control.Monad (when)

import Control.Lens hiding (Index)

import Network.Kontiki.Log
import Network.Kontiki.Types
import Network.Kontiki.Monad
import Network.Kontiki.Raft.Utils

-- | Handles `RequestVote'.
handleRequestVote :: (Functor m, Monad m)
                  => MessageHandler RequestVote a Leader m
handleRequestVote sender RequestVote{..} = do
    currentTerm <- use lCurrentTerm

    if rvTerm > currentTerm
        then stepDown sender rvTerm
        else do
            logS "Not granting vote"
            send sender $ RequestVoteResponse { rvrTerm = currentTerm
                                              , rvrVoteGranted = False
                                              }
            currentState

-- | Handle `RequestVoteResponse'.
handleRequestVoteResponse :: (Functor m, Monad m)
                          => MessageHandler RequestVoteResponse a Leader m
handleRequestVoteResponse sender RequestVoteResponse{..} = do
    currentTerm <- use lCurrentTerm

    if rvrTerm > currentTerm
        then stepDown sender rvrTerm
        else currentState

-- | Handles `AppendEntries'.
handleAppendEntries :: (Functor m, Monad m)
                    => MessageHandler (AppendEntries a) a Leader m
handleAppendEntries sender AppendEntries{..} = do
    currentTerm <- use lCurrentTerm

    if aeTerm > currentTerm
        then stepDown sender aeTerm
        else currentState

-- | Handles `AppendEntriesResponse'.
handleAppendEntriesResponse :: (Functor m, Monad m)
                            => MessageHandler AppendEntriesResponse a Leader m
handleAppendEntriesResponse sender AppendEntriesResponse{..} = do
    currentTerm <- use lCurrentTerm

    if | aerTerm < currentTerm -> do
           logS "Ignoring old AppendEntriesResponse"
           currentState
       | aerTerm > currentTerm -> stepDown sender aerTerm
       | not aerSuccess -> do
           lNextIndex %= Map.alter (\i -> Just $ maybe index0 prevIndex i) sender
           currentState
       | otherwise -> do
           lastIndices <- use lLastIndex
           let li = maybe index0 id (Map.lookup sender lastIndices)
           -- Ignore if this is an old message
           when (aerLastIndex >= li) $ do
               lLastIndex %= Map.insert sender aerLastIndex
               lNextIndex %= Map.insert sender aerLastIndex
           currentState

-- | Handles `ElectionTimeout'.
handleElectionTimeout :: (Functor m, Monad m)
                      => TimeoutHandler ElectionTimeout a Leader m
handleElectionTimeout = currentState

-- | Handles `HeartbeatTimeout'.
handleHeartbeatTimeout :: (Functor m, Monad m, MonadLog m a)
                       => TimeoutHandler HeartbeatTimeout a Leader m
handleHeartbeatTimeout = do
    resetHeartbeatTimeout

    currentTerm <- use lCurrentTerm

    lastEntry <- logLastEntry

    nodeId <- view configNodeId
    lLastIndex %= Map.insert nodeId (maybe index0 eIndex lastEntry)

    lastIndices <- Map.elems `fmap` use lLastIndex
    let sorted = sortBy (\a b -> compare b a) lastIndices
    quorum <- quorumSize
    let quorumIndex = sorted !! (quorum - 1)

    -- TODO Check paper. CommitIndex can only be in current term if there's
    -- a prior accepted item in the same term?

    e <- logEntry quorumIndex
    let commitIndex =
            if maybe term0 eTerm e >= currentTerm
                then quorumIndex
                else index0

    nodes <- view configNodes
    let otherNodes = filter (/= nodeId) (Set.toList nodes)
    mapM_ (sendAppendEntries lastEntry commitIndex) otherNodes

    currentState

-- | Sends `AppendEntries' to a particular `NodeId'.
sendAppendEntries :: (Monad m, MonadLog m a)
                  => Maybe (Entry a) -- ^ `Entry' to append
                  -> Index           -- ^ `Index' up to which the `Follower' should commit
                  -> NodeId          -- ^ `NodeId' to send to
                  -> TransitionT a LeaderState m ()
sendAppendEntries lastEntry commitIndex node = do
    currentTerm <- use lCurrentTerm

    nextIndices <- use lNextIndex

    let lastIndex = maybe index0 eIndex lastEntry
        lastTerm = maybe term0 eTerm lastEntry
        nextIndex = (Map.!) nextIndices node

    let getEntries acc idx
            | idx <= nextIndex = return acc
            | otherwise = do
                entry <- logEntry idx
                -- TODO Handle failure
                getEntries (maybe undefined id entry : acc) (prevIndex idx)

    entries <- getEntries [] lastIndex

    nodeId <- view configNodeId

    if null entries
        then send node AppendEntries { aeTerm = currentTerm
                                     , aeLeaderId = nodeId
                                     , aePrevLogIndex = lastIndex
                                     , aePrevLogTerm = lastTerm
                                     , aeEntries = []
                                     , aeCommitIndex = commitIndex
                                     }
        else do
            e <- logEntry (prevIndex $ eIndex $ head entries)
            send node AppendEntries { aeTerm = currentTerm
                                    , aeLeaderId = nodeId
                                    , aePrevLogIndex = maybe index0 eIndex e
                                    , aePrevLogTerm = maybe term0 eTerm e
                                    , aeEntries = entries
                                    , aeCommitIndex = commitIndex
                                    }

-- | `Handler' for `MLeader' mode.
handle :: (Functor m, Monad m, MonadLog m a)
       => Handler a Leader m
handle = handleGeneric
            handleRequestVote
            handleRequestVoteResponse
            handleAppendEntries
            handleAppendEntriesResponse
            handleElectionTimeout
            handleHeartbeatTimeout

-- | Transitions into `MLeader' mode by broadcasting heartbeat `AppendEntries'
-- to all nodes and changing state to `LeaderState'. 
stepUp :: (Functor m, Monad m, MonadLog m a)
       => Term -- ^ `Term' of the `Leader'
       -> TransitionT a f m SomeState
stepUp t = do
    logS "Becoming leader"

    resetHeartbeatTimeout

    e <- logLastEntry
    let lastIndex = maybe index0 eIndex e
        lastTerm = maybe term0 eTerm e

    nodeId <- view configNodeId

    broadcast $ AppendEntries { aeTerm = t
                              , aeLeaderId = nodeId
                              , aePrevLogIndex = lastIndex
                              , aePrevLogTerm = lastTerm
                              , aeEntries = []
                              , aeCommitIndex = index0
                              }

    nodes <- view configNodes
    let ni = Map.fromList $ map (\n -> (n, succIndex lastIndex)) (Set.toList nodes)
        li = Map.fromList $ map (\n -> (n, index0)) (Set.toList nodes)

    return $ wrap $ LeaderState { _lCurrentTerm = t
                                , _lNextIndex = ni
                                , _lLastIndex = li
                                }
