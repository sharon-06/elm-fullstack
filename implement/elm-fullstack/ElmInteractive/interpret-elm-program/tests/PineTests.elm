module PineTests exposing (..)

import Expect
import Pine
import Test


pineExpressionEncodeDecodeRoundtrip : Test.Test
pineExpressionEncodeDecodeRoundtrip =
    [ ( "literal empty list", Pine.LiteralExpression (Pine.ListValue []) )
    , ( "literal blob", Pine.LiteralExpression (Pine.BlobValue [ 1, 3, 4 ]) )
    , ( "list empty", Pine.ListExpression [] )
    , ( "application zero args"
      , Pine.ApplicationExpression
            { function = Pine.LiteralExpression (Pine.ListValue [])
            , arguments = []
            }
      )
    , ( "application one arg"
      , Pine.ApplicationExpression
            { function = Pine.LiteralExpression (Pine.ListValue [])
            , arguments = [ Pine.LiteralExpression (Pine.BlobValue [ 1, 3, 4 ]) ]
            }
      )
    , ( "if block"
      , Pine.IfBlockExpression
            { condition = Pine.FunctionOrValueExpression "condition"
            , ifTrue = Pine.FunctionOrValueExpression "trueExpression"
            , ifFalse = Pine.FunctionOrValueExpression "falseExpression"
            }
      )
    , ( "context expansion with name"
      , Pine.ContextExpansionWithNameExpression
            { name = "newName"
            , namedValue = Pine.valueFromString "named value"
            , expression = Pine.FunctionOrValueExpression "expression_using_new_name"
            }
      )
    , ( "simple function expression"
      , Pine.FunctionExpression
            { argumentName = "argument_a"
            , body = Pine.LiteralExpression (Pine.ListValue [])
            }
      )
    , ( "nested function expression"
      , Pine.FunctionExpression
            { argumentName = "argument_a"
            , body =
                Pine.FunctionExpression
                    { argumentName = "argument_b"
                    , body = Pine.LiteralExpression (Pine.ListValue [])
                    }
            }
      )
    ]
        |> List.map
            (\( testName, expression ) ->
                Test.test testName <|
                    \_ ->
                        let
                            encoded =
                                Pine.encodeExpressionAsValue expression
                        in
                        Expect.equal (Ok expression) (Pine.decodeExpressionFromValue encoded)
            )
        |> Test.describe "Pine expression encode decode roundtrip"
