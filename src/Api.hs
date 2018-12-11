{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{- | This module specifies the API types/routes & exports a Wai
Application to serve it.
-}
module Api
    ( Config(..)
    , app
    )
where

import           Control.Monad.Reader           ( runReaderT )
import           Data.Aeson                     ( ToJSON )
import           Data.Maybe                     ( fromMaybe )
import           Data.Proxy                     ( Proxy(..) )
import           Data.Text                      ( Text )
import           Data.Time.Clock.POSIX          ( POSIXTime )
import           Database.Persist.Sql           ( (==.)
                                                , Entity(..)
                                                , selectList
                                                , selectFirst
                                                , fromSqlKey
                                                )
import           Flow
import           GHC.Generics                   ( Generic )
import           Network.Wai                    ( Application
                                                , Request
                                                )
import           Servant                        ( (:>)
                                                , (:<|>)(..)
                                                , AuthProtect
                                                , Get
                                                , JSON
                                                , Server
                                                , ServerT
                                                , Context(..)
                                                , Handler
                                                , serveWithContext
                                                , hoistServerWithContext
                                                , throwError
                                                , errBody
                                                , err401
                                                )
import           Servant.Server.Experimental.Auth
                                                ( AuthHandler
                                                , AuthServerData
                                                )

import           Schema
import           Types
import           WordpressAuth


-- | Create an API Server with the Given Configuration.
app :: Config -> Application
app c = serveWithContext api (serverContext c) (server c)

server :: Config -> Server API
server c = hoistServerWithContext api context (`runReaderT` c) routes

-- brittany-disable-next-binding
serverContext
    :: Config
    -> Context
            '[ AuthHandler Request (WordpressUserData (Entity User))
             , AuthHandler Request (WordpressUserData (Maybe (Entity User)))
             ]
serverContext config =
       authHandler (wordpressConfig config)
    :. authHandler (optionalWordpressConfig config)
    :. EmptyContext

type instance AuthServerData (AuthProtect "wordpress") = WordpressUserData (Entity User)
type instance AuthServerData (AuthProtect "wordpress-optional") = WordpressUserData (Maybe (Entity User))


wordpressConfig :: Config -> WordpressAuthConfig (Entity User)
wordpressConfig c = WordpressAuthConfig
    { cookieName              = defaultCookieName $ wpSiteUrl c
    , getUserData             = fetchUserData c
    , loggedInKey             = wpLoggedInKey c
    , loggedInSalt            = wpLoggedInSalt c
    , onAuthenticationFailure = replyWith401
    }
  where
    replyWith401
        :: WordpressAuthError -> Handler (WordpressUserData (Entity User))
    replyWith401 err = (\s -> throwError err401 { errBody = s }) $ case err of
        NoCookieHeader      -> "Missing Cookie"
        NoCookieMatches     -> "Missing Cookie"
        CookieParsingFailed -> "Malformed Cookie"
        _                   -> "Invalid Cookie"

optionalWordpressConfig :: Config -> WordpressAuthConfig (Maybe (Entity User))
optionalWordpressConfig c = WordpressAuthConfig
    { cookieName              = defaultCookieName $ wpSiteUrl c
    , getUserData = fmap (fmap (\(x, y, z) -> (Just x, y, z))) . fetchUserData c
    , loggedInKey             = wpLoggedInKey c
    , loggedInSalt            = wpLoggedInSalt c
    , onAuthenticationFailure = const (return $ WordpressUserData Nothing)
    }

fetchUserData
    :: Config
    -> Text
    -> Handler (Maybe (Entity User, Text, [(Text, POSIXTime)]))
fetchUserData c userName = flip runReaderT c . runDB $ do
    maybeUser <- selectFirst [UserLogin ==. userName] []
    case maybeUser of
        Just e  -> Just <$> getSessionTokens e
        Nothing -> return Nothing
  where
    getSessionTokens e@(Entity userId user) = do
        tokenMeta <- selectFirst
            [UserMetaUser ==. userId, UserMetaKey ==. "session_tokens"]
            []
        return (e, userPassword user, maybe [] metaToTokenList tokenMeta)
    metaToTokenList =
        entityVal .> userMetaValue .> fromMaybe "" .> decodeSessionTokens


-- brittany-disable-next-binding
context
    :: Proxy
            '[ AuthHandler Request (WordpressUserData (Entity User))
             , AuthHandler Request (WordpressUserData (Maybe (Entity User)))
             ]
context = Proxy



api :: Proxy API
api = Proxy

-- brittany-disable-next-binding
type API =
         "directory" :> "entries"
                     :> Get '[JSON] [CommunityListing]
    :<|> "private" :> AuthProtect "wordpress"
                   :> Get '[JSON] [CommunityListing]
    :<|> "optional" :> AuthProtect "wordpress-optional"
                    :> Get '[JSON] [CommunityListing]

routes :: ServerT API AppM
routes = getListings :<|> const getListings :<|> const getListings

data CommunityListing
    = CommunityListing
        { listingId :: Int
        , name :: Text
        -- TODO: Add these
        --, slug :: Text
        --, imageUrl :: Text
        --, thumbnailUrl :: Text
        --, createdAt :: UTCTime
        --, updatedAt :: UTCTime
        --, communityStatus :: Text
        --, city :: Text
        --, state :: Text
        --, country :: Text
        --, openToMembership :: Text
        --, openToVisitors :: Text
        }
        deriving (Eq, Show, Generic)

instance ToJSON CommunityListing

getListings :: AppM [CommunityListing]
getListings =
    map
            (\(Entity lId l) -> CommunityListing
                (fromIntegral $ fromSqlKey lId)
                (formItemName l)
            )
        <$> runDB (selectList [FormItemForm ==. 2] [])
