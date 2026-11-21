{-# LANGUAGE OverloadedStrings #-}

-- | Sidebar navigation, breadcrumbs, and sequential Previous/Next pagination.
module Docs.Nav
  ( sortPages
  , renderSidebarHtml
  , renderBreadcrumbsHtml
  , renderPrevNextHtml
  , escapeHtml
  ) where

import Data.List (findIndex, sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Docs.Types

-- | Escape HTML special characters in text content and attribute values.
escapeHtml :: Text -> Text
escapeHtml = T.concatMap esc
  where
    esc '&' = "&amp;"
    esc '<' = "&lt;"
    esc '>' = "&gt;"
    esc '"' = "&quot;"
    esc '\'' = "&#39;"
    esc c = T.singleton c

-- | Deterministically sort pages by @(sectionRank, order, route)@.
sortPages :: [PageMeta] -> [PageMeta]
sortPages = sortOn (\p -> (sectionRank (pmSection p), pmOrder p, pmRoute p))

-- | Render the left-sidebar grouped navigation HTML for a given active route.
renderSidebarHtml :: Text -> [PageMeta] -> Text
renderSidebarHtml activeRoute pages =
  let sorted = sortPages pages
      renderSec sec =
        let secPages = [p | p <- sorted, pmSection p == sec]
         in if null secPages
              then ""
              else
                T.concat
                  [ "<div class=\"nav-group\">"
                  , "<div class=\"nav-group-title\">"
                  , escapeHtml (sectionLabel sec)
                  , "</div>"
                  , "<ul class=\"nav-list\">"
                  , T.concat (map renderItem secPages)
                  , "</ul>"
                  , "</div>"
                  ]
      renderItem p =
        let isActive = pmRoute p == activeRoute
            cls = if isActive then "nav-link active" else "nav-link"
            aria = if isActive then " aria-current=\"page\"" else ""
         in T.concat
              [ "<li class=\"nav-item\">"
              , "<a class=\""
              , cls
              , "\" href=\""
              , escapeHtml (pmUrl p)
              , "\""
              , aria
              , ">"
              , escapeHtml (pmNavTitle p)
              , "</a></li>"
              ]
   in T.concat (map renderSec allSections)

-- | Render top-of-page breadcrumbs for the active page.
renderBreadcrumbsHtml :: PageMeta -> [PageMeta] -> Text
renderBreadcrumbsHtml page allPages =
  let hasIndex = any (\p -> pmRoute p == "index") allPages
      rootCrumb
        | pmRoute page == "index" =
            "<span class=\"breadcrumb-root\">rules_hs</span>"
        | hasIndex =
            "<a class=\"breadcrumb-link\" href=\"/index.html\">rules_hs</a>"
        | otherwise =
            "<span class=\"breadcrumb-root\">rules_hs</span>"
      secCrumb =
        "<span class=\"breadcrumb-sep\" aria-hidden=\"true\">/</span>"
          <> "<span class=\"breadcrumb-section\">"
          <> escapeHtml (sectionLabel (pmSection page))
          <> "</span>"
      leafCrumb
        | pmRoute page == "index" = ""
        | otherwise =
            "<span class=\"breadcrumb-sep\" aria-hidden=\"true\">/</span>"
              <> "<span class=\"breadcrumb-current\" aria-current=\"page\">"
              <> escapeHtml (pmNavTitle page)
              <> "</span>"
   in "<nav class=\"breadcrumbs\" aria-label=\"Breadcrumb\">"
        <> rootCrumb
        <> secCrumb
        <> leafCrumb
        <> "</nav>"

-- | Render sequential Previous / Next footer cards across the ordered site.
renderPrevNextHtml :: Text -> [PageMeta] -> Text
renderPrevNextHtml activeRoute pages =
  let sorted = sortPages pages
   in case findIndex (\p -> pmRoute p == activeRoute) sorted of
        Nothing -> ""
        Just idx ->
          let prevM = if idx > 0 then Just (sorted !! (idx - 1)) else Nothing
              nextM = if idx + 1 < length sorted then Just (sorted !! (idx + 1)) else Nothing
           in if prevM == Nothing && nextM == Nothing
                then ""
                else
                  T.concat
                    [ "<nav class=\"prev-next\" aria-label=\"Sequential page navigation\">"
                    , maybe "<div class=\"prev-next-spacer\"></div>" (renderCard False) prevM
                    , maybe "<div class=\"prev-next-spacer\"></div>" (renderCard True) nextM
                    , "</nav>"
                    ]
  where
    renderCard isNext p =
      let relCls = if isNext then "prev-next-card next-card" else "prev-next-card prev-card"
          dirLabel =
            if isNext
              then "Next &rarr;"
              else "&larr; Previous"
       in T.concat
            [ "<a class=\""
            , relCls
            , "\" href=\""
            , escapeHtml (pmUrl p)
            , "\">"
            , "<span class=\"prev-next-dir\">"
            , dirLabel
            , "</span>"
            , "<span class=\"prev-next-section\">"
            , escapeHtml (sectionLabel (pmSection p))
            , "</span>"
            , "<span class=\"prev-next-title\">"
            , escapeHtml (pmNavTitle p)
            , "</span>"
            , "</a>"
            ]
