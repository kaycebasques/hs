Literate Haskell module rendered by Haddock.

> -- | Literate Haddock module exercising @.lhs@ documentation generation.
> module HaddockLiterate
>   ( literateGreeting
>   ) where
>
> -- | Format a greeting from a literate @.lhs@ module.
> literateGreeting :: String -> String
> literateGreeting who = "literate:" ++ who
