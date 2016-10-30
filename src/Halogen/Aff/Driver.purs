module Halogen.Aff.Driver
  ( Driver
  , RenderSpec
  , runUI
  , module Exports
  ) where

import Prelude

import Control.Applicative.Free (hoistFreeAp, retractFreeAp)
import Control.Coroutine (($$))
import Control.Coroutine as CR
import Control.Monad.Aff (Aff, runAff, forkAff, forkAll)
import Control.Monad.Aff.AVar (AVAR, AVar, putVar, takeVar, modifyVar)
import Control.Monad.Aff.Unsafe (unsafeCoerceAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Exception (error, throwException)
import Control.Monad.Eff.Ref (Ref, modifyRef, writeRef, readRef, newRef)
import Control.Monad.Error.Class (throwError)
import Control.Monad.Free (foldFree)
import Control.Monad.Fork (fork)
import Control.Monad.Rec.Class (forever)
import Control.Monad.Trans.Class (lift)
import Control.Parallel (sequential, parallel)

import Data.Lazy (force)
import Data.List (List, (:))
import Data.List as L
import Data.Map as M
import Data.Maybe (Maybe(..), maybe)
import Data.Newtype (unwrap)
import Data.Traversable (traverse_, for_, sequence)
import Data.Tuple (Tuple(..))

import Halogen.Aff.Driver.State (ComponentType(..), DriverStateX, DriverState(..), unDriverStateX, initDriverState)
import Halogen.Component (Component, ComponentSlot, unComponent, unComponentSlot)
import Halogen.Data.OrdBox (OrdBox, unOrdBox)
import Halogen.Effects (HalogenEffects)
import Halogen.Query.ChildQuery (ChildQuery, unChildQuery)
import Halogen.Query.ForkF as FF
import Halogen.Query.HalogenM (HalogenM(..), HalogenF(..), HalogenAp(..))

import Halogen.Aff.Driver.State (ComponentType(..)) as Exports

-- | Type alias for driver functions generated by `runUI` - a driver takes an
-- | input of the query algebra (`f`) and returns an `Aff` that returns when
-- | query has been fulfilled.
type Driver f eff = f ~> Aff (HalogenEffects eff)

type DSL s f m eff p o = HalogenF s f m p o (Aff (HalogenEffects eff))

type LifecycleHandlers eff =
  { initializers :: List (Aff (HalogenEffects eff) Unit)
  , finalizers :: List (Aff (HalogenEffects eff) Unit)
  }

handleLifecycle
  :: forall eff r
   . (Ref (LifecycleHandlers eff) -> Aff (HalogenEffects eff) r)
  -> Aff (HalogenEffects eff) r
handleLifecycle f = do
  lchs <- liftEff $ newRef { initializers: L.Nil, finalizers: L.Nil }
  result <- f lchs
  { initializers, finalizers } <- liftEff $ readRef lchs
  sequence $ L.reverse initializers
  forkAll finalizers
  pure result

type RenderSpec h r eff =
  { render
      :: forall f g p
       . (forall x. f x -> Eff (HalogenEffects eff) Unit)
      -> (ComponentSlot h g (Aff (HalogenEffects eff)) p (f Unit) -> Aff (HalogenEffects eff) r)
      -> h (ComponentSlot h g (Aff (HalogenEffects eff)) p (f Unit)) (f Unit)
      -> ComponentType
      -> Maybe r
      -> Aff (HalogenEffects eff) r
  , renderChild
      :: Int
      -> Maybe r
      -> Aff (HalogenEffects eff) r
  }

-- | This function is the main entry point for a Halogen based UI, taking a root
-- | component, initial state, and HTML element to attach the rendered component
-- | to.
-- |
-- | The returned "driver" function can be used to send actions and requests
-- | into the component hierarchy, allowing the outside world to communicate
-- | with the UI.
runUI
  :: forall h r f o eff
   . RenderSpec h r eff
  -> Component h f o (Aff (HalogenEffects eff))
  -> Aff (HalogenEffects eff) (Driver f eff)
runUI renderSpec component = _.driver <$> do
  fresh <- liftEff $ newRef 0
  handleLifecycle \lchs ->
    runComponent (const (pure unit)) fresh lchs Root component
      >>= peekVar
      >>= unDriverStateX \st ->
        -- The record here is a hack around a skolem escape issue. If the typing
        -- rules for records change so this no longer works it may also be
        -- fixable with copious type annotations.
        pure { driver: evalF st.selfRef }

  where

  runComponent
    :: forall f' o'
     . (o' -> Aff (HalogenEffects eff) Unit)
    -> Ref Int
    -> Ref (LifecycleHandlers eff)
    -> ComponentType
    -> Component h f' o' (Aff (HalogenEffects eff))
    -> Aff (HalogenEffects eff) (AVar (DriverStateX h r f' eff))
  runComponent handler fresh lchs componentType = unComponent \component -> do
    keyId <- liftEff $ readRef fresh
    liftEff $ modifyRef fresh (_ + 1)
    var <- initDriverState component componentType handler keyId fresh
    unDriverStateX (render lchs <<< _.selfRef) =<< peekVar var
    addInitializer lchs =<< peekVar var
    pure var

  eval
    :: forall s f' g p o'
     . AVar (DriverState h r s f' g p o' eff)
    -> DSL s f' g eff p o'
    ~> Aff (HalogenEffects eff)
  eval ref = case _ of
    GetState k -> do
      DriverState { state } <- peekVar ref
      pure (k state)
    ModifyState f next -> do
      modifyVar (\(DriverState st) -> DriverState (st { state = f st.state })) ref
      handleLifecycle \lchs -> render lchs ref
      pure next
    Subscribe es next -> do
      let consumer = forever (lift <<< evalF ref =<< CR.await)
      forkAff $ CR.runProcess (unwrap es $$ consumer)
      pure next
    Lift aff ->
      aff
    Halt msg ->
      throwError (error msg)
    GetSlots k -> do
      DriverState { children } <- peekVar ref
      pure $ k $ map unOrdBox $ M.keys children
    CheckSlot p k -> do
      DriverState { mkOrdBox, children } <- peekVar ref
      pure $ k $ M.member (mkOrdBox p) children
    ChildQuery cq ->
      evalChildQuery ref cq
    Raise o a -> do
      DriverState (ds@{ handler, pendingOut }) <- takeVar ref
      case pendingOut of
        Nothing -> do
          putVar ref (DriverState ds)
          handler o
        Just p ->
          putVar ref (DriverState ds { pendingOut = Just (o : p) })
      pure a
    Par (HalogenAp p) ->
      sequential $ retractFreeAp $ hoistFreeAp (parallel <<< evalM ref) p
    Fork f ->
      FF.unFork (\(FF.ForkF fx k) →
        k <<< map unsafeCoerceAff <$> fork (evalM ref fx)) f

  evalChildQuery
    :: forall s f' g p o'
     . AVar (DriverState h r s f' g p o' eff)
    -> ChildQuery g (Aff (HalogenEffects eff)) p
    ~> Aff (HalogenEffects eff)
  evalChildQuery ref = unChildQuery \p k -> do
    DriverState st <- peekVar ref
    case M.lookup (st.mkOrdBox p) st.children of
      Just var -> do
        dsx <- peekVar var
        k (unDriverStateX (\ds -> evalF ds.selfRef) dsx)
      Nothing -> throwError (error "Slot lookup failed for child query")

  evalF
    :: forall s f' g p o'
     . AVar (DriverState h r s f' g p o' eff)
    -> f'
    ~> Aff (HalogenEffects eff)
  evalF ref q = do
    DriverState st <- peekVar ref
    case st.component.eval q of
      HalogenM fx -> foldFree (eval ref) fx

  evalM
    :: forall s f' g p o'
     . AVar (DriverState h r s f' g p o' eff)
    -> HalogenM s f' g p o' (Aff (HalogenEffects eff))
    ~> Aff (HalogenEffects eff)
  evalM ref (HalogenM q) = foldFree (eval ref) q

  render
    :: forall s f' g p o'
     . Ref (LifecycleHandlers eff)
    -> AVar (DriverState h r s f' g p o' eff)
    -> Aff (HalogenEffects eff) Unit
  render lchs var = takeVar var >>= \(DriverState ds) -> do
    childrenVar <- liftEff $ newRef M.empty
    oldChildren <- liftEff $ newRef ds.children
    let
      selfEval = evalF ds.selfRef
      handler :: forall x. f' x -> Aff (HalogenEffects eff) Unit
      handler = void <<< selfEval
      handler' :: forall x. f' x -> Aff (HalogenEffects eff) Unit
      handler' = maybe handler (\_ -> queuingHandler ds.selfRef handler) ds.pendingIn
    rendering <-
      renderSpec.render
        (handleAff <<< selfEval)
        (renderChild handler' ds.fresh ds.mkOrdBox oldChildren childrenVar lchs)
        (ds.component.render ds.state)
        ds.componentType
        ds.rendering
    children <- liftEff $ readRef childrenVar
    liftEff (readRef oldChildren) >>= traverse_ (addFinalizer lchs <=< peekVar)
    putVar var $
      DriverState
        { rendering: Just rendering
        , componentType: ds.componentType
        , component: ds.component
        , state: ds.state
        , children
        , mkOrdBox: ds.mkOrdBox
        , selfRef: ds.selfRef
        , handler: ds.handler
        , pendingIn: ds.pendingIn
        , pendingOut: ds.pendingOut
        , keyId: ds.keyId
        , fresh: ds.fresh
        }

  queuingHandler
    :: forall s f' g p o' x
     . AVar (DriverState h r s f' g p o' eff)
    -> (f' x -> Aff (HalogenEffects eff) Unit)
    -> f' x
    -> Aff (HalogenEffects eff) Unit
  queuingHandler var handler message = do
    DriverState (ds@{ pendingIn }) <- takeVar var
    case pendingIn of
      Nothing -> do
        putVar var (DriverState ds)
        handler message
      Just p ->
        putVar var (DriverState ds { pendingIn = Just (handler message : p) })

  renderChild
    :: forall f' g p
     . (forall x. f' x -> Aff (HalogenEffects eff) Unit)
    -> Ref Int
    -> (p -> OrdBox p)
    -> Ref (M.Map (OrdBox p) (AVar (DriverStateX h r g eff)))
    -> Ref (M.Map (OrdBox p) (AVar (DriverStateX h r g eff)))
    -> Ref (LifecycleHandlers eff)
    -> ComponentSlot h g (Aff (HalogenEffects eff)) p (f' Unit)
    -> Aff (HalogenEffects eff) r
  renderChild handler fresh mkOrdBox childrenInRef childrenOutRef lchs =
    unComponentSlot \p ctor k -> do
      childrenIn <- liftEff $ readRef childrenInRef
      var <- case M.pop (mkOrdBox p) childrenIn of
        Just (Tuple existing childrenIn') -> do
          liftEff $ writeRef childrenInRef childrenIn'
          pure existing
        Nothing ->
          runComponent (maybe (pure unit) handler <<< k) fresh lchs Child (force ctor)
      liftEff $ modifyRef childrenOutRef (M.insert (mkOrdBox p) var)
      unDriverStateX (\st -> renderSpec.renderChild st.keyId st.rendering) =<< peekVar var

  addInitializer
    :: forall f'
     . Ref (LifecycleHandlers eff)
    -> DriverStateX h r f' eff
    -> Aff (HalogenEffects eff) Unit
  addInitializer ref =
    unDriverStateX \st -> do
      case evalF st.selfRef <$> st.component.initializer of
        Just i -> do
          liftEff $ modifyRef ref \lchs ->
            { initializers: handlePending st.selfRef : i : lchs.initializers
            , finalizers: lchs.finalizers
            }
        _ ->
          pure unit

  handlePending
    :: forall s f' g p o'
     . AVar (DriverState h r s f' g p o' eff)
    -> Aff (HalogenEffects eff) Unit
  handlePending ref = do
    DriverState (dsi@{ pendingIn }) <- takeVar ref
    putVar ref (DriverState dsi { pendingIn = Nothing })
    for_ pendingIn (sequence <<< L.reverse)
    DriverState (dso@{ pendingOut, handler }) <- takeVar ref
    putVar ref (DriverState dso { pendingOut = Nothing })
    for_ pendingOut (traverse_ handler <<< L.reverse)


  addFinalizer
    :: forall f'
     . Ref (LifecycleHandlers eff)
    -> DriverStateX h r f' eff
    -> Aff (HalogenEffects eff) Unit
  addFinalizer ref =
    unDriverStateX \st -> do
      for_ (evalF st.selfRef <$> st.component.finalizer) \f ->
        liftEff $ modifyRef ref (\lchs ->
          { initializers: lchs.initializers
          , finalizers: f : lchs.finalizers
          })
      for_ st.children (addFinalizer ref <=< peekVar)

-- | TODO: we could do something more intelligent now this isn't baked into the
-- | virtual-dom rendering. Perhaps write to an avar when an error occurs...
-- | something other than a runtime exception anyway.
handleAff
  :: forall eff a
   . Aff (HalogenEffects eff) a
  -> Eff (HalogenEffects eff) Unit
handleAff = void <<< runAff throwException (const (pure unit))

peekVar :: forall eff a. AVar a -> Aff (avar :: AVAR | eff) a
peekVar v = do
  a <- takeVar v
  putVar v a
  pure a
