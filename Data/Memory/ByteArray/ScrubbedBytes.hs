-- |
-- Module      : Data.Memory.ByteArray.ScrubbedBytes
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : Stable
-- Portability : GHC
--
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE CPP #-}
module Data.Memory.ByteArray.ScrubbedBytes
    ( ScrubbedBytes
    ) where

import           GHC.Types
import           GHC.Prim
import           GHC.Ptr
import           Data.Memory.Internal.CompatPrim
import           Data.Memory.ByteArray.Types

-- | SecureMem is a memory chunk which have the properties of:
--
-- * Being scrubbed after its goes out of scope.
--
-- * A Show instance that doesn't actually show any content
--
-- * A Eq instance that is constant time
--
data ScrubbedBytes = ScrubbedBytes (MutableByteArray# RealWorld)

instance Show ScrubbedBytes where
    show _ = "<scrubbed-bytes>"

instance ByteArrayAccess ScrubbedBytes where
    length        = sizeofScrubbedBytes
    withByteArray = withPtr

instance ByteArray ScrubbedBytes where
    allocRet = scrubbedBytesAllocRet

newScrubbedBytes :: Int -> IO ScrubbedBytes
newScrubbedBytes (I# sz)
    | booleanPrim (sz <=# 0#) = error "negative or null size for scrubbed array" -- TODO raise a proper exception
    | otherwise               = IO $ \s ->
        case newAlignedPinnedByteArray# sz 8# s of
            (# s1, mbarr #) ->
                let !scrubber = getScrubber
                    !mba      = ScrubbedBytes mbarr
                 in case mkWeak# mbarr () (scrubber (byteArrayContents# (unsafeCoerce# mbarr)) >> touchScrubbedBytes mba) s1 of
                    (# s2, _ #) -> (# s2, mba #)
  where
        getScrubber :: Addr# -> IO ()
        getScrubber = eitherDivideBy8# sz scrubber64 scrubber8

        scrubber64 :: Int# -> Addr# -> IO ()
        scrubber64 sz64 addr = IO $ \s -> (# loop sz64 addr s, () #)
          where loop :: Int# -> Addr# -> State# RealWorld -> State# RealWorld
                loop n a s
                    | booleanPrim (n ==# 0#) = s
                    | otherwise              =
                        case writeWord64OffAddr# a 0# 0## s of
                            s' -> loop (n -# 1#) (plusAddr# a 8#) s'

        scrubber8 :: Int# -> Addr# -> IO ()
        scrubber8 sz8 addr = IO $ \s -> (# loop sz8 addr s, () #)
          where loop :: Int# -> Addr# -> State# RealWorld -> State# RealWorld
                loop n a s
                    | booleanPrim (n ==# 0#) = s
                    | otherwise              =
                        case writeWord8OffAddr# a 0# 0## s of
                            s' -> loop (n -# 1#) (plusAddr# a 1#) s'

scrubbedBytesAllocRet :: Int -> (Ptr p -> IO a) -> IO (a, ScrubbedBytes)
scrubbedBytesAllocRet sz f = do
    ba <- newScrubbedBytes sz
    r  <- withPtr ba f
    return (r, ba)

sizeofScrubbedBytes :: ScrubbedBytes -> Int
sizeofScrubbedBytes (ScrubbedBytes mba) = I# (sizeofMutableByteArray# mba)

withPtr :: ScrubbedBytes -> (Ptr p -> IO a) -> IO a
withPtr b@(ScrubbedBytes mba) f = do
    a <- f (Ptr (byteArrayContents# (unsafeCoerce# mba)))
    touchScrubbedBytes b
    return a

touchScrubbedBytes :: ScrubbedBytes -> IO ()
touchScrubbedBytes (ScrubbedBytes mba) = IO $ \s -> case touch# mba s of s' -> (# s', () #)
