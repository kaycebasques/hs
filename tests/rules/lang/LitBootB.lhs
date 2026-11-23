Mutually recursive literate module B importing LitBootA via {-# SOURCE #-}.

> module LitBootB (isLitOdd) where
>
> import {-# SOURCE #-} LitBootA (LitEven (..), isLitEven)
>
> isLitOdd :: Int -> Bool
> isLitOdd 0 = False
> isLitOdd n =
>     let LitEven ev = isLitEven (abs n - 1)
>      in ev
