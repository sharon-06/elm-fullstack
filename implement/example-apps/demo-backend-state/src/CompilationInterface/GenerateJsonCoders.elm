module CompilationInterface.GenerateJsonCoders exposing (..)

{-| For documentation of the compilation interface, see <https://github.com/elm-fullstack/elm-fullstack/blob/main/guide/how-to-configure-and-deploy-an-elm-fullstack-app.md#compilationinterfacegeneratejsoncoders-elm-module>
-}

import Backend.State
import Json.Encode
import CompilationInterface.GenerateJsonCoders.Generated_9c46e930
import Dict
import Set
import Json.Decode
import Json.Encode
import Bytes
import Bytes.Decode
import Bytes.Encode
import Backend.State
import ListDict


jsonEncodeBackendState : Backend.State.State -> Json.Encode.Value
jsonEncodeBackendState =
    CompilationInterface.GenerateJsonCoders.Generated_9c46e930.jsonEncode_2ea38cf1d1
