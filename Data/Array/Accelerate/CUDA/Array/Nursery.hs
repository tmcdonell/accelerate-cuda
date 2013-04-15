{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ViewPatterns #-}
-- |
-- Module      : Data.Array.Accelerate.CUDA.Array.Nursery
-- Copyright   : [2008..2010] Manuel M T Chakravarty, Gabriele Keller, Sean Lee
--               [2009..2013] Manuel M T Chakravarty, Gabriele Keller, Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.CUDA.Array.Nursery (

  Nursery(..), NRS, new, lookup, insert, flush,

) where

-- friends
import Data.Array.Accelerate.CUDA.FullList              ( FullList )
import qualified Data.Array.Accelerate.CUDA.FullList    as FL
import qualified Data.Array.Accelerate.CUDA.Debug       as D

-- libraries
import Prelude                                          hiding ( lookup )
import Data.IORef
import Data.IntMap                                      ( IntMap )
import Control.Exception                                ( bracket_ )
import System.Mem.Weak                                  ( Weak )
import Foreign.CUDA.Ptr                                 ( DevicePtr )

import qualified Foreign.CUDA.Driver                    as CUDA
import qualified Data.IntMap.Strict                     as IM


-- The nursery is a place to store device memory arrays that are no longer
-- needed. If a new array is requested of a similar size, we might return an
-- array from the nursery instead of calling into the CUDA API to allocate fresh
-- memory.
--
-- Note that pointers are also related to a specific context, so we must include
-- that when looking up the map.
--
-- Note that since there might be many arrays for the same size, each entry in
-- the map keeps a (non-empty) list of device pointers.
--

type NRS        = IORef ( IntMap (FullList CUDA.Context (DevicePtr ())) )
data Nursery    = Nursery {-# UNPACK #-} !NRS
                          {-# UNPACK #-} !(Weak NRS)


-- If the array in the nursery (m) is less than 10% larger than the requested
-- size (n), consider that a reasonable slop and use the array.
--
{-# INLINE overprovision #-}
overprovision :: Int -> Int -> Bool
overprovision n m = round (fromIntegral n * 1.10 :: Double) >= m


-- Generate a fresh nursery
--
new :: IO Nursery
new = do
  let nrs = IM.empty
  ref    <- newIORef nrs
  weak   <- nrs `seq` mkWeakIORef ref (flush ref)
  return $! Nursery ref weak


-- Look for a chunk of memory in the nursery of a given size (or a little bit
-- larger). If found, it is removed from the nursery and a pointer to it
-- returned.
--
{-# INLINE lookup #-}
lookup :: Int -> CUDA.Context -> Nursery -> IO (Maybe (DevicePtr ()))
lookup !n !ctx (Nursery !ref _) = do
  atomicModifyIORef' ref $ \nrs ->
    case IM.lookupGE n nrs of
      Nothing     -> trace "lookup/not found" (nrs, Nothing)
      Just (m,fl)
        | not (overprovision n m) -> trace "lookup/not found" (nrs, Nothing)
        | otherwise               ->
            case FL.lookupDelete ctx fl of
              (Nothing, _) -> trace "lookup/no context" (nrs, Nothing)
              (ptr, fl')   -> trace "lookup/found" (IM.update (const fl') m nrs, ptr)


-- Add a device pointer to the nursery.
--
{-# INLINE insert #-}
insert :: Int -> CUDA.Context -> NRS -> DevicePtr a -> IO ()
insert !n !ctx !ref (CUDA.castDevPtr -> !ptr) =
  let
      f Nothing   = Just $ FL.singleton ctx ptr
      f (Just xs) = Just $ FL.cons ctx ptr xs
  in
  trace ("insert: " ++ showBytes n) $ modifyIORef' ref (IM.alter f n)


-- Delete all entries from the nursery and free all associated device memory.
--
flush :: NRS -> IO ()
flush !ref
  = trace "flush nursery"
  $ do nrs <- readIORef ref
       mapM_ (FL.mapM_ (\ctx ptr -> bracket_ (CUDA.push ctx) CUDA.pop (CUDA.free ptr))) (IM.elems nrs)
       writeIORef ref IM.empty


-- Debug
-- -----

{-# INLINE showBytes #-}
showBytes :: Int -> String
showBytes x = D.showFFloatSIBase (Just 0) 1024 (fromIntegral x :: Double) "B"

{-# INLINE trace #-}
trace :: String -> a -> a
trace msg next = D.trace D.dump_gc ("nrs: " ++ msg) next

