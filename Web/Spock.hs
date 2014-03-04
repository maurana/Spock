{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Web.Spock
    ( -- * Spock's core
      spock, SpockM, SpockAction
      -- * Database
    , PoolOrConn (..), ConnBuilder (..), PoolCfg (..)
      -- * Accessing Database and State
    , HasSpock
    -- * Authorization
    , SessionCfg (..)
    , authedUser, unauthCurrent
      -- * Authorized Routing
    , NoAccessReason (..), UserRights
    , NoAccessHandler, LoadUserFun, CheckRightsFun
    , authed
      -- * General Routing
    , get, post, put, delete, patch, addroute, Http.StdMethod (..)
      -- * Cookies
    , setCookie, setCookie', getCookie
      -- * Other reexports from scotty
    , middleware, matchAny, notFound
    , request, reqHeader, body, param, params, jsonData, files
    , status, addHeader, setHeader, redirect
    , text, html, file, json, source, raw
    , raise, rescue, next
      -- * Internals for extending Spock
    , getSpockHeart, runSpockIO, WebStateM, WebState
    )
where

import Web.Spock.SessionManager
import Web.Spock.Monad
import Web.Spock.Types
import Web.Spock.Cookie

import Control.Applicative
import Control.Monad.Trans
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Resource
import Data.Pool
import Web.Scotty.Trans
import qualified Network.HTTP.Types as Http

-- | Run a spock application using the warp server, a given db storageLayer and an initial state.
-- Spock works with database libraries that already implement connection pooling and
-- with those that don't come with it out of the box. For more see the 'PoolOrConn' type.
spock :: Int -> SessionCfg -> PoolOrConn conn -> st -> SpockM conn sess st () -> IO ()
spock port sessionCfg poolOrConn initialState defs =
    do sessionMgr <- openSessionManager sessionCfg
       connectionPool <-
           case poolOrConn of
             PCConduitPool p ->
                 return (ConduitPool p)
             PCPool p ->
                 return (DataPool p)
             PCConn cb ->
                 let pc = cb_poolConfiguration cb
                 in DataPool <$> createPool (cb_createConn cb) (cb_destroyConn cb)
                                  (pc_stripes pc) (pc_keepOpenTime pc)
                                   (pc_resPerStripe pc)
       let internalState =
               WebState
               { web_dbConn = connectionPool
               , web_sessionMgr = sessionMgr
               , web_state = initialState
               }
           runM m = runResourceT $ runReaderT (runWebStateM m) internalState
           runActionToIO = runM

       scottyT port runM runActionToIO defs

-- | After checking that a login was successfull, register the usersId
-- into the session and create a session cookie for later "authed" requests
-- to work properly
authedUser :: user -> (user -> sess) -> SpockAction conn sess st ()
authedUser user getSessionId =
    do mgr <- getSessMgr
       (sm_createCookieSession mgr) (getSessionId user)

-- | Destroy the current users session
unauthCurrent :: SpockAction conn sess st ()
unauthCurrent =
    do mgr <- getSessMgr
       mSess <- sm_sessionFromCookie mgr
       case mSess of
         Just sess -> liftIO $ (sm_deleteSession mgr) (sess_id sess)
         Nothing -> return ()

-- | Define what happens to non-authorized requests
type NoAccessHandler conn sess st =
    NoAccessReason -> SpockAction conn sess st ()

-- | How should a session be transformed into a user? Can access the database using 'runQuery'
type LoadUserFun conn sess st user =
    sess -> SpockAction conn sess st (Maybe user)

-- | What rights does the current user have? Can access the database using 'runQuery'
type CheckRightsFun conn sess st user =
    user -> [UserRights] -> SpockAction conn sess st Bool

-- | Before the request is performed, you can check if the signed in user has permissions to
-- view the contents of the request. You may want to define a helper function that
-- proxies this function to not pass around 'NoAccessHandler', 'LoadUserFun' and 'CheckRightsFun'
-- all the time.
-- Example:
--
-- > type MyWebMonad a = SpockAction Connection Int () a
-- > newtype MyUser = MyUser { unMyUser :: T.Text }
-- >
-- > http403 msg =
-- >    do status Http.status403
-- >       text (show msg)
-- >
-- > login :: Http.StdMethod
-- >       -> [UserRights]
-- >       -> RoutePattern
-- >       -> (MyUser -> MyWebMonad ())
-- >       -> MyWebMonad ()
-- > login =
-- >     authed http403 myLoadUser myCheckRights
--
authed :: NoAccessHandler conn sess st
       -> LoadUserFun conn sess st user
       -> CheckRightsFun conn sess st user
       -> Http.StdMethod -> [UserRights] -> RoutePattern
       -> (user -> SpockAction conn sess st ())
       -> SpockM conn sess st ()
authed noAccessHandler loadUser checkRights reqTy requiredRights route action =
    addroute reqTy route $
        do mgr <- getSessMgr
           mSess <- fmap sess_data <$> (sm_sessionFromCookie mgr)
           case mSess of
             Just sval ->
                 do mUser <- loadUser sval
                    case mUser of
                      Just user ->
                          do isOk <- checkRights user requiredRights
                             if isOk
                             then action user
                             else noAccessHandler NotEnoughRights
                      Nothing ->
                          noAccessHandler NotLoggedIn
             Nothing ->
                 noAccessHandler NoSession
