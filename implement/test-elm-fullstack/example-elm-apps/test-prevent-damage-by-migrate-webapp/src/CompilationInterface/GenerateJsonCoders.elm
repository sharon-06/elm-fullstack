module CompilationInterface.GenerateJsonCoders exposing
    ( decodeBackendState
    , encodeBackendState
    )

{-| For documentation of the compilation interface, see <https://github.com/elm-fullstack/elm-fullstack/blob/main/guide/how-to-configure-and-deploy-an-elm-fullstack-app.md#compilationinterfacegeneratejsoncoders-elm-module>
-}

import Backend.StateType
import Json.Decode
import Json.Encode


encodeBackendState : Backend.StateType.State -> Json.Encode.Value
encodeBackendState =
    always (Json.Encode.string "The compiler replaces this function.")


decodeBackendState : Json.Decode.Decoder Backend.StateType.State
decodeBackendState =
    Json.Decode.fail "The compiler replaces this function."
