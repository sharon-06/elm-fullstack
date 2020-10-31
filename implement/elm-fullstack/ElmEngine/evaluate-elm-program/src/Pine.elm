module Pine exposing (..)

import BigInt
import Result.Extra


type PineExpression
    = PineLiteral PineValue
    | PineListExpr (List PineExpression)
    | PineApplication { function : PineExpression, arguments : List PineExpression }
    | PineFunctionOrValue String
    | PineContextExpansionWithName ( String, PineValue ) PineExpression
    | PineIfBlock PineExpression PineExpression PineExpression
    | PineFunction String PineExpression


type PineValue
    = PineStringOrInteger String
    | PineList (List PineValue)
      -- TODO: Replace PineExpressionValue with convention for mapping value to expression.
    | PineExpressionValue PineExpression


type alias PineExpressionContext =
    -- TODO: Test consolidate into simple PineValue
    { commonModel : List PineValue
    , provisionalArgumentStack : List PineValue
    }


addToContext : List PineValue -> PineExpressionContext -> PineExpressionContext
addToContext names context =
    { context | commonModel = context.commonModel ++ names }


evaluatePineExpression : PineExpressionContext -> PineExpression -> Result String PineValue
evaluatePineExpression context expression =
    case expression of
        PineLiteral pineValue ->
            Ok pineValue

        PineListExpr listElements ->
            listElements
                |> List.map (evaluatePineExpression context)
                |> Result.Extra.combine
                |> Result.map PineList
                |> Result.mapError (\error -> "Failed to evaluate list element: " ++ error)

        PineApplication application ->
            case evaluatePineApplication context application of
                Err error ->
                    Err ("Failed application: " ++ error)

                Ok (PineExpressionValue expressionAfterApplication) ->
                    evaluatePineExpression context expressionAfterApplication

                otherResult ->
                    otherResult

        PineFunctionOrValue name ->
            case name of
                "True" ->
                    Ok truePineValue

                "False" ->
                    Ok falsePineValue

                _ ->
                    let
                        beforeCheckForExpression =
                            lookUpNameInContext name context
                                |> Result.mapError
                                    (\error -> "Failed to look up name '" ++ name ++ "': " ++ error)
                    in
                    case beforeCheckForExpression of
                        Ok ( PineExpressionValue expressionFromLookup, contextFromLookup ) ->
                            evaluatePineExpression (addToContext contextFromLookup context) expressionFromLookup

                        _ ->
                            Result.map Tuple.first beforeCheckForExpression

        PineIfBlock condition expressionIfTrue expressionIfFalse ->
            case evaluatePineExpression context condition of
                Err error ->
                    Err ("Failed to evaluate condition: " ++ error)

                Ok conditionValue ->
                    evaluatePineExpression context
                        (if conditionValue == truePineValue then
                            expressionIfTrue

                         else
                            expressionIfFalse
                        )

        PineContextExpansionWithName expansion expressionInExpandedContext ->
            evaluatePineExpression
                { context | commonModel = pineValueFromContextExpansionWithName expansion :: context.commonModel }
                expressionInExpandedContext

        PineFunction argumentName expressionInExpandedContext ->
            case context.provisionalArgumentStack of
                nextArgumentValue :: remainingArgumentValues ->
                    evaluatePineExpression
                        { context | provisionalArgumentStack = remainingArgumentValues }
                        (PineContextExpansionWithName ( argumentName, nextArgumentValue ) expressionInExpandedContext)

                [] ->
                    Ok (PineExpressionValue expression)


pineValueFromContextExpansionWithName : ( String, PineValue ) -> PineValue
pineValueFromContextExpansionWithName ( declName, declValue ) =
    PineList [ PineStringOrInteger declName, declValue ]


lookUpNameInContext : String -> PineExpressionContext -> Result String ( PineValue, List PineValue )
lookUpNameInContext name context =
    case name |> String.split "." of
        [] ->
            Err "nameElements is empty"

        nameFirstElement :: nameRemainingElements ->
            let
                maybeMatchingValue =
                    context.commonModel
                        |> List.filterMap
                            (\contextElement ->
                                case contextElement of
                                    PineStringOrInteger _ ->
                                        Nothing

                                    PineList [ elementLabel, elementValue ] ->
                                        if elementLabel == PineStringOrInteger nameFirstElement then
                                            Just elementValue

                                        else
                                            Nothing

                                    PineList _ ->
                                        Nothing

                                    PineExpressionValue _ ->
                                        Nothing
                            )
                        |> List.head
            in
            case maybeMatchingValue of
                Nothing ->
                    Err ("Did not find '" ++ nameFirstElement ++ "'")

                Just firstNameValue ->
                    if nameRemainingElements == [] then
                        Ok ( firstNameValue, context.commonModel )

                    else
                        case firstNameValue of
                            PineList firstNameList ->
                                lookUpNameInContext (String.join "." nameRemainingElements)
                                    { commonModel = firstNameList, provisionalArgumentStack = [] }

                            _ ->
                                Err ("'" ++ nameFirstElement ++ "' has unexpected type: Not a list.")


evaluatePineApplication : PineExpressionContext -> { function : PineExpression, arguments : List PineExpression } -> Result String PineValue
evaluatePineApplication context application =
    case application.function of
        PineFunctionOrValue functionName ->
            case functionName of
                "PineKernel.listFirstElement" ->
                    evaluatePineApplicationExpectingExactlyOneArgument
                        { mapArg = evaluatePineExpression context
                        , apply =
                            \argument ->
                                case argument of
                                    PineList list ->
                                        list
                                            |> List.head
                                            |> Maybe.withDefault (PineList [])
                                            |> Ok

                                    _ ->
                                        Err "Argument is not a list."
                        }
                        application.arguments

                "List.length" ->
                    evaluatePineApplicationExpectingExactlyOneArgument
                        { mapArg = evaluatePineExpression context
                        , apply =
                            \argument ->
                                case argument of
                                    PineList list ->
                                        Ok (PineStringOrInteger (list |> List.length |> String.fromInt))

                                    _ ->
                                        Err "Argument is not a list."
                        }
                        application.arguments

                "List.drop" ->
                    evaluatePineApplicationExpectingExactlyTwoArguments
                        { mapArg0 = evaluatePineExpression context >> Result.andThen parseAsBigInt >> Result.andThen intFromBigInt
                        , mapArg1 = evaluatePineExpression context
                        , apply =
                            \arg0 arg1 ->
                                case arg1 of
                                    PineList list ->
                                        Ok (PineList (List.drop arg0 list))

                                    _ ->
                                        Err "Unexpected operand for List.drop."
                        }
                        application.arguments

                "String.fromInt" ->
                    case application.arguments of
                        [ argument ] ->
                            evaluatePineExpression context argument

                        _ ->
                            Err
                                ("Unexpected number of arguments for String.fromInt: "
                                    ++ String.fromInt (List.length application.arguments)
                                )

                "(==)" ->
                    evaluatePineApplicationExpectingExactlyTwoArguments
                        { mapArg0 = evaluatePineExpression context
                        , mapArg1 = evaluatePineExpression context
                        , apply =
                            \leftValue rightValue ->
                                Ok
                                    (if leftValue == rightValue then
                                        truePineValue

                                     else
                                        falsePineValue
                                    )
                        }
                        application.arguments

                "(++)" ->
                    evaluatePineApplicationExpectingExactlyTwoArguments
                        { mapArg0 = evaluatePineExpression context
                        , mapArg1 = evaluatePineExpression context
                        , apply =
                            \leftValue rightValue ->
                                case ( leftValue, rightValue ) of
                                    ( PineStringOrInteger leftLiteral, PineStringOrInteger rightLiteral ) ->
                                        Ok (PineStringOrInteger (leftLiteral ++ rightLiteral))

                                    ( PineList leftList, PineList rightList ) ->
                                        Ok (PineList (leftList ++ rightList))

                                    _ ->
                                        Err "Unexpected combination of operands."
                        }
                        application.arguments

                "(+)" ->
                    evaluatePineApplicationExpectingExactlyTwoArguments
                        { mapArg0 = evaluatePineExpression context >> Result.andThen parseAsBigInt
                        , mapArg1 = evaluatePineExpression context >> Result.andThen parseAsBigInt
                        , apply =
                            \leftInt rightInt ->
                                Ok (PineStringOrInteger (BigInt.add leftInt rightInt |> BigInt.toString))
                        }
                        application.arguments

                "(*)" ->
                    evaluatePineApplicationExpectingExactlyTwoArguments
                        { mapArg0 = evaluatePineExpression context >> Result.andThen parseAsBigInt
                        , mapArg1 = evaluatePineExpression context >> Result.andThen parseAsBigInt
                        , apply =
                            \leftInt rightInt ->
                                Ok (PineStringOrInteger (BigInt.mul leftInt rightInt |> BigInt.toString))
                        }
                        application.arguments

                "(//)" ->
                    evaluatePineApplicationExpectingExactlyTwoArguments
                        { mapArg0 = evaluatePineExpression context >> Result.andThen parseAsBigInt
                        , mapArg1 = evaluatePineExpression context >> Result.andThen parseAsBigInt
                        , apply =
                            \leftInt rightInt ->
                                Ok (PineStringOrInteger (BigInt.div leftInt rightInt |> BigInt.toString))
                        }
                        application.arguments

                "not" ->
                    evaluatePineApplicationExpectingExactlyOneArgument
                        { mapArg = evaluatePineExpression context
                        , apply =
                            \argument ->
                                if argument == truePineValue then
                                    Ok falsePineValue

                                else
                                    Ok truePineValue
                        }
                        application.arguments

                _ ->
                    case lookUpNameInContext functionName context of
                        Err lookupError ->
                            Err ("Failed to look up name '" ++ functionName ++ "': " ++ lookupError)

                        Ok ( PineExpressionValue expression, contextFromLookup ) ->
                            case application.arguments |> List.map (evaluatePineExpression context) |> Result.Extra.combine of
                                Err evalArgError ->
                                    Err ("Failed to evaluate argument: " ++ evalArgError)

                                Ok arguments ->
                                    evaluatePineExpression
                                        (addToContext
                                            contextFromLookup
                                            { context
                                                | provisionalArgumentStack = arguments ++ context.provisionalArgumentStack
                                            }
                                        )
                                        expression

                        _ ->
                            Err "Unexpected value for function in appliction: Not an expression."

        _ ->
            Err "Application not implemented yet."


parseAsBigInt : PineValue -> Result String BigInt.BigInt
parseAsBigInt value =
    case value of
        PineStringOrInteger stringOrInt ->
            BigInt.fromIntString stringOrInt
                |> Result.fromMaybe ("Failed to parse as integer: " ++ stringOrInt)

        PineList _ ->
            Err "Unexpected type of value: List"

        PineExpressionValue _ ->
            Err "Unexpected type of value: ExpressionValue"


intFromBigInt : BigInt.BigInt -> Result String Int
intFromBigInt bigInt =
    case bigInt |> BigInt.toString |> String.toInt of
        Nothing ->
            Err "Failed to String.toInt"

        Just int ->
            if String.fromInt int /= BigInt.toString bigInt then
                Err "Integer out of supported range for String.toInt"

            else
                Ok int


evaluatePineApplicationExpectingExactlyTwoArguments :
    { mapArg0 : PineExpression -> Result String arg0
    , mapArg1 : PineExpression -> Result String arg1
    , apply : arg0 -> arg1 -> Result String PineValue
    }
    -> List PineExpression
    -> Result String PineValue
evaluatePineApplicationExpectingExactlyTwoArguments configuration arguments =
    case arguments of
        [ arg0, arg1 ] ->
            case configuration.mapArg0 arg0 of
                Err error ->
                    Err ("Failed to map argument 0: " ++ error)

                Ok mappedArg0 ->
                    case configuration.mapArg1 arg1 of
                        Err error ->
                            Err ("Failed to map argument 1: " ++ error)

                        Ok mappedArg1 ->
                            configuration.apply mappedArg0 mappedArg1

        _ ->
            Err
                ("Unexpected number of arguments for: "
                    ++ String.fromInt (List.length arguments)
                )


evaluatePineApplicationExpectingExactlyOneArgument :
    { mapArg : PineExpression -> Result String arg
    , apply : arg -> Result String PineValue
    }
    -> List PineExpression
    -> Result String PineValue
evaluatePineApplicationExpectingExactlyOneArgument configuration arguments =
    case arguments of
        [ arg ] ->
            case configuration.mapArg arg of
                Err error ->
                    Err ("Failed to map argument: " ++ error)

                Ok mappedArg ->
                    configuration.apply mappedArg

        _ ->
            Err
                ("Unexpected number of arguments for: "
                    ++ String.fromInt (List.length arguments)
                )


truePineValue : PineValue
truePineValue =
    tagValue "True" []


falsePineValue : PineValue
falsePineValue =
    tagValue "False" []


tagValue : String -> List PineValue -> PineValue
tagValue tagName tagArguments =
    PineList [ PineStringOrInteger tagName, PineList tagArguments ]
