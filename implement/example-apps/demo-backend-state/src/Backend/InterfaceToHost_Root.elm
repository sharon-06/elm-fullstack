module Backend.InterfaceToHost_Root exposing
    ( State
    , interfaceToHost_deserializeState
    , interfaceToHost_initState
    , interfaceToHost_processEvent
    , interfaceToHost_serializeState
    , main
    )

import Backend.Main
import Backend.InterfaceToHost_Root.Generated_9c46e930
import Dict
import Set
import Json.Decode
import Json.Encode
import Bytes
import Bytes.Decode
import Bytes.Encode
import Backend.State
import ListDict
import Backend.MigrateState
import Platform
import ElmFullstack exposing (..)


type alias DeserializedState =
    ({ httpRequestsCount : Int, lastHttpRequests : ( List { httpRequestId : String, posixTimeMilli : Int, requestContext : { clientAddress : ( Maybe String ) }, request : { method : String, uri : String, bodyAsBase64 : ( Maybe String ), headers : ( List { name : String, values : ( List String ) } ) } } ), tuple2 : (Int, String), tuple3 : (Int, String, Int), list_custom_type : ( List Backend.State.CustomType ), opaque_custom_type : Backend.State.OpaqueCustomType, recursive_type : Backend.State.RecursiveType, bool : Bool, maybe : ( Maybe String ), result : ( Result String Int ), set : ( Set.Set Int ), dict : ( Dict.Dict Int String ), empty_record : {  }, empty_tuple : (), customTypeInstance : ( Backend.State.CustomTypeWithTypeParameter Int ), record_instance : { field_parameterized : String, field_a : Int }, listDict : ( ListDict.Dict { orig : Int, dest : Int } String ), bytes : Bytes.Bytes })


type alias DeserializedStateWithTaskFramework =
    { stateLessFramework : DeserializedState
    , nextTaskIndex : Int
    , posixTimeMilli : Int
    , createVolatileProcessTasks : Dict.Dict TaskId (CreateVolatileProcessResult -> DeserializedState -> ( DeserializedState, BackendCmds DeserializedState ))
    , requestToVolatileProcessTasks : Dict.Dict TaskId (RequestToVolatileProcessResult -> DeserializedState -> ( DeserializedState, BackendCmds DeserializedState ))
    , terminateVolatileProcessTasks : Dict.Dict TaskId ()
    }


initDeserializedStateWithTaskFramework : DeserializedState -> DeserializedStateWithTaskFramework
initDeserializedStateWithTaskFramework stateLessFramework =
    { stateLessFramework = stateLessFramework
    , nextTaskIndex = 0
    , posixTimeMilli = 0
    , createVolatileProcessTasks = Dict.empty
    , requestToVolatileProcessTasks = Dict.empty
    , terminateVolatileProcessTasks = Dict.empty
    }


type ResponseOverSerialInterface
    = DecodeEventError String
    | DecodeEventSuccess BackendEventResponse


type State
    = DeserializeFailed String
    | DeserializeSuccessful DeserializedStateWithTaskFramework


type BackendEvent
    = HttpRequestEvent ElmFullstack.HttpRequestEventStruct
    | TaskCompleteEvent TaskCompleteEventStruct
    | PosixTimeHasArrivedEvent { posixTimeMilli : Int }
    | InitStateEvent
    | SetStateEvent String
    | MigrateStateEvent String


type alias BackendEventResponse =
    { startTasks : List StartTaskStructure
    , notifyWhenPosixTimeHasArrived : Maybe { minimumPosixTimeMilli : Int }
    , completeHttpResponses : List RespondToHttpRequestStruct
    , migrateResult : Maybe (Result String ())
    }


type alias TaskCompleteEventStruct =
    { taskId : TaskId
    , taskResult : TaskResultStructure
    }


type TaskResultStructure
    = CreateVolatileProcessResponse (Result CreateVolatileProcessErrorStruct CreateVolatileProcessComplete)
    | RequestToVolatileProcessResponse (Result RequestToVolatileProcessError RequestToVolatileProcessComplete)
    | CompleteWithoutResult


type alias StartTaskStructure =
    { taskId : TaskId
    , task : Task
    }


type Task
    = CreateVolatileProcess CreateVolatileProcessLessUpdateStruct
    | RequestToVolatileProcess RequestToVolatileProcessLessUpdateStruct
    | TerminateVolatileProcess TerminateVolatileProcessStruct


type alias CreateVolatileProcessLessUpdateStruct =
    { programCode : String
    }


type alias RequestToVolatileProcessLessUpdateStruct =
    { processId : String
    , request : String
    }


type alias TaskId =
    String


interfaceToHost_initState =
    Backend.Main.backendMain.init
        |> Tuple.first
        |> initDeserializedStateWithTaskFramework
        |> DeserializeSuccessful


interfaceToHost_processEvent hostEvent stateBefore =
    case stateBefore of
        DeserializeFailed _ ->
            ( stateBefore, "[]" )

        DeserializeSuccessful deserializedState ->
            deserializedState
                |> wrapForSerialInterface_processEvent Backend.Main.backendMain.subscriptions hostEvent
                |> Tuple.mapFirst DeserializeSuccessful


interfaceToHost_serializeState = jsonEncodeState >> Json.Encode.encode 0


interfaceToHost_deserializeState = deserializeState


-- Support function-level dead code elimination (https://elm-lang.org/blog/small-assets-without-the-headache) Elm code needed to inform the Elm compiler about our entry points.


main : Program Int State String
main =
    Platform.worker
        { init = \_ -> ( interfaceToHost_initState, Cmd.none )
        , update =
            \event stateBefore ->
                { a = interfaceToHost_processEvent
                , b = interfaceToHost_serializeState
                , c = interfaceToHost_deserializeState
                }
                    |> always ( stateBefore, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


-- Inlined helpers -->


{-| Turn a `Result e a` to an `a`, by applying the conversion
function specified to the `e`.
-}
result_Extra_Extract : (e -> a) -> Result e a -> a
result_Extra_Extract f x =
    case x of
        Ok a ->
            a

        Err e ->
            f e


-- Remember and communicate errors from state deserialization -->


jsonEncodeState : State -> Json.Encode.Value
jsonEncodeState state =
    case state of
        DeserializeFailed error ->
            [ ( "Interface_DeserializeFailed"
              , [ ( "error", error |> Json.Encode.string ) ] |> Json.Encode.object
              )
            ]
                |> Json.Encode.object

        DeserializeSuccessful deserializedState ->
            deserializedState.stateLessFramework |> jsonEncodeDeserializedState


deserializeState : String -> State
deserializeState serializedState =
    serializedState
        |> Json.Decode.decodeString jsonDecodeState
        |> Result.mapError Json.Decode.errorToString
        |> result_Extra_Extract DeserializeFailed


jsonDecodeState : Json.Decode.Decoder State
jsonDecodeState =
    Json.Decode.oneOf
        [ Json.Decode.field "Interface_DeserializeFailed" (Json.Decode.field "error" Json.Decode.string |> Json.Decode.map DeserializeFailed)
        , jsonDecodeDeserializedState |> Json.Decode.map (initDeserializedStateWithTaskFramework >> DeserializeSuccessful)
        ]


----


wrapForSerialInterface_processEvent :
    (DeserializedState -> BackendSubs DeserializedState)
    -> String
    -> DeserializedStateWithTaskFramework
    -> ( DeserializedStateWithTaskFramework, String )
wrapForSerialInterface_processEvent subscriptions serializedEvent stateBefore =
    let
        ( state, response ) =
            case serializedEvent |> Json.Decode.decodeString decodeBackendEvent of
                Err error ->
                    ( stateBefore
                    , ("Failed to deserialize event: " ++ (error |> Json.Decode.errorToString))
                        |> DecodeEventError
                    )

                Ok hostEvent ->
                    stateBefore
                        |> processEvent subscriptions hostEvent
                        |> Tuple.mapSecond DecodeEventSuccess
    in
    ( state, response |> encodeResponseOverSerialInterface |> Json.Encode.encode 0 )


processEvent :
    (DeserializedState -> BackendSubs DeserializedState)
    -> BackendEvent
    -> DeserializedStateWithTaskFramework
    -> ( DeserializedStateWithTaskFramework, BackendEventResponse )
processEvent subscriptions hostEvent stateBefore =
    let
        maybeEventPosixTimeMilli =
            case hostEvent of
                HttpRequestEvent httpRequestEvent ->
                    Just httpRequestEvent.posixTimeMilli

                PosixTimeHasArrivedEvent posixTimeHasArrivedEvent ->
                    Just posixTimeHasArrivedEvent.posixTimeMilli

                _ ->
                    Nothing

        state =
            case maybeEventPosixTimeMilli of
                Nothing ->
                    stateBefore

                Just eventPosixTimeMilli ->
                    { stateBefore | posixTimeMilli = max stateBefore.posixTimeMilli eventPosixTimeMilli }
    in
    processEventLessRememberTime subscriptions hostEvent state


processEventLessRememberTime :
    (DeserializedState -> BackendSubs DeserializedState)
    -> BackendEvent
    -> DeserializedStateWithTaskFramework
    -> ( DeserializedStateWithTaskFramework, BackendEventResponse )
processEventLessRememberTime subscriptions hostEvent stateBefore =
    let
        continueWithState newState =
            ( newState
            , backendEventResponseFromSubscriptions (subscriptions newState.stateLessFramework)
            )

        discardEvent =
            continueWithState stateBefore

        continueWithUpdateToTasks updateToTasks stateBeforeUpdateToTasks =
            let
                ( stateLessFramework, runtimeTasks ) =
                    updateToTasks stateBeforeUpdateToTasks.stateLessFramework
            in
            backendEventResponseFromRuntimeTasksAndSubscriptions
                subscriptions
                runtimeTasks
                { stateBeforeUpdateToTasks | stateLessFramework = stateLessFramework }
    in
    case hostEvent of
        HttpRequestEvent httpRequestEvent ->
            continueWithUpdateToTasks
                ((subscriptions stateBefore.stateLessFramework).httpRequest httpRequestEvent)
                stateBefore

        PosixTimeHasArrivedEvent posixTimeHasArrivedEvent ->
            case (subscriptions stateBefore.stateLessFramework).posixTimeIsPast of
                Nothing ->
                    discardEvent

                Just posixTimeIsPastSub ->
                    if posixTimeHasArrivedEvent.posixTimeMilli < posixTimeIsPastSub.minimumPosixTimeMilli then
                        discardEvent

                    else
                        continueWithUpdateToTasks
                            (posixTimeIsPastSub.update { currentPosixTimeMilli = posixTimeHasArrivedEvent.posixTimeMilli })
                            stateBefore

        TaskCompleteEvent taskCompleteEvent ->
            case taskCompleteEvent.taskResult of
                CreateVolatileProcessResponse createVolatileProcessResponse ->
                    case Dict.get taskCompleteEvent.taskId stateBefore.createVolatileProcessTasks of
                        Nothing ->
                            discardEvent

                        Just taskEntry ->
                            continueWithUpdateToTasks
                                (taskEntry createVolatileProcessResponse)
                                { stateBefore
                                    | createVolatileProcessTasks =
                                        stateBefore.createVolatileProcessTasks |> Dict.remove taskCompleteEvent.taskId
                                }

                RequestToVolatileProcessResponse requestToVolatileProcessResponse ->
                    case Dict.get taskCompleteEvent.taskId stateBefore.requestToVolatileProcessTasks of
                        Nothing ->
                            discardEvent

                        Just taskEntry ->
                            continueWithUpdateToTasks
                                (taskEntry requestToVolatileProcessResponse)
                                { stateBefore
                                    | requestToVolatileProcessTasks =
                                        stateBefore.requestToVolatileProcessTasks |> Dict.remove taskCompleteEvent.taskId
                                }

                CompleteWithoutResult ->
                    continueWithState
                        { stateBefore
                            | terminateVolatileProcessTasks =
                                stateBefore.terminateVolatileProcessTasks |> Dict.remove taskCompleteEvent.taskId
                        }

        InitStateEvent ->
            continueWithUpdateToTasks (always Backend.Main.backendMain.init) stateBefore

        SetStateEvent stateString ->
            let
                ( ( state, responseBeforeAddingMigrateResult ), migrateResult ) =
                    case setStateFromString stateString of
                        Err migrateError ->
                            ( continueWithState
                                stateBefore
                            , Err migrateError
                            )

                        Ok appState ->
                            ( continueWithUpdateToTasks
                                (always ( appState, [] ))
                                stateBefore
                            , Ok ()
                            )
            in
            ( state
            , { responseBeforeAddingMigrateResult | migrateResult = Just migrateResult }
            )

        MigrateStateEvent stateString ->
            let
                ( ( state, responseBeforeAddingMigrateResult ), migrateResult ) =
                    case migrateFromString stateString of
                        Err migrateError ->
                            ( continueWithState
                                stateBefore
                            , Err migrateError
                            )

                        Ok stateAndCmds ->
                            ( continueWithUpdateToTasks
                                (always stateAndCmds)
                                stateBefore
                            , Ok ()
                            )
            in
            ( state
            , { responseBeforeAddingMigrateResult | migrateResult = Just migrateResult }
            )


setStateFromString : String -> Result String DeserializedState
setStateFromString =
    Json.Decode.decodeString Backend.InterfaceToHost_Root.Generated_9c46e930.jsonDecode_2ea38cf1d1
    >> Result.mapError Json.Decode.errorToString

migrateFromString : String -> Result String ( DeserializedState, BackendCmds DeserializedState )
migrateFromString =
    Json.Decode.decodeString Backend.InterfaceToHost_Root.Generated_9c46e930.jsonDecode_2ea38cf1d1
    >> Result.mapError Json.Decode.errorToString
    >> Result.map Backend.MigrateState.migrate


backendEventResponseFromRuntimeTasksAndSubscriptions :
    (DeserializedState -> BackendSubs DeserializedState)
    -> List (BackendCmd DeserializedState)
    -> DeserializedStateWithTaskFramework
    -> ( DeserializedStateWithTaskFramework, BackendEventResponse )
backendEventResponseFromRuntimeTasksAndSubscriptions subscriptions tasks stateBefore =
    tasks
        |> List.foldl
            (\task ( previousState, previousResponse ) ->
                let
                    ( newState, newResponse ) =
                        backendEventResponseFromRuntimeTask task previousState
                in
                ( newState, newResponse :: previousResponse )
            )
            ( stateBefore
            , [ backendEventResponseFromSubscriptions (subscriptions stateBefore.stateLessFramework) ]
            )
        |> Tuple.mapSecond concatBackendEventResponse


backendEventResponseFromSubscriptions : BackendSubs DeserializedState -> BackendEventResponse
backendEventResponseFromSubscriptions subscriptions =
    { startTasks = []
    , completeHttpResponses = []
    , notifyWhenPosixTimeHasArrived =
        subscriptions.posixTimeIsPast
            |> Maybe.map (\posixTimeIsPast -> { minimumPosixTimeMilli = posixTimeIsPast.minimumPosixTimeMilli })
    , migrateResult = Nothing
    }


backendEventResponseFromRuntimeTask :
    BackendCmd DeserializedState
    -> DeserializedStateWithTaskFramework
    -> ( DeserializedStateWithTaskFramework, BackendEventResponse )
backendEventResponseFromRuntimeTask task stateBefore =
    let
        createTaskId stateBeforeCreateTaskId =
            let
                taskId =
                    String.join "-"
                        [ String.fromInt stateBeforeCreateTaskId.posixTimeMilli
                        , String.fromInt stateBeforeCreateTaskId.nextTaskIndex
                        ]
            in
            ( { stateBeforeCreateTaskId
                | nextTaskIndex = stateBeforeCreateTaskId.nextTaskIndex + 1
              }
            , taskId
            )
    in
    case task of
        RespondToHttpRequest respondToHttpRequest ->
            ( stateBefore
            , passiveBackendEventResponse
                |> withCompleteHttpResponsesAdded [ respondToHttpRequest ]
            )

        ElmFullstack.CreateVolatileProcess createVolatileProcess ->
            let
                ( stateAfterCreateTaskId, taskId ) =
                    createTaskId stateBefore
            in
            ( { stateAfterCreateTaskId
                | createVolatileProcessTasks =
                    stateAfterCreateTaskId.createVolatileProcessTasks
                        |> Dict.insert taskId createVolatileProcess.update
              }
            , passiveBackendEventResponse
                |> withStartTasksAdded
                    [ { taskId = taskId
                      , task = CreateVolatileProcess { programCode = createVolatileProcess.programCode }
                      }
                    ]
            )

        ElmFullstack.RequestToVolatileProcess requestToVolatileProcess ->
            let
                ( stateAfterCreateTaskId, taskId ) =
                    createTaskId stateBefore
            in
            ( { stateAfterCreateTaskId
                | requestToVolatileProcessTasks =
                    stateAfterCreateTaskId.requestToVolatileProcessTasks
                        |> Dict.insert taskId requestToVolatileProcess.update
              }
            , passiveBackendEventResponse
                |> withStartTasksAdded
                    [ { taskId = taskId
                      , task =
                            RequestToVolatileProcess
                                { processId = requestToVolatileProcess.processId
                                , request = requestToVolatileProcess.request
                                }
                      }
                    ]
            )

        ElmFullstack.TerminateVolatileProcess terminateVolatileProcess ->
            let
                ( stateAfterCreateTaskId, taskId ) =
                    createTaskId stateBefore
            in
            ( { stateAfterCreateTaskId
                | terminateVolatileProcessTasks =
                    stateAfterCreateTaskId.terminateVolatileProcessTasks |> Dict.insert taskId ()
              }
            , passiveBackendEventResponse
                |> withStartTasksAdded
                    [ { taskId = taskId
                      , task = TerminateVolatileProcess terminateVolatileProcess
                      }
                    ]
            )


concatBackendEventResponse : List BackendEventResponse -> BackendEventResponse
concatBackendEventResponse responses =
    let
        notifyWhenPosixTimeHasArrived =
            responses
                |> List.filterMap .notifyWhenPosixTimeHasArrived
                |> List.map .minimumPosixTimeMilli
                |> List.minimum
                |> Maybe.map (\posixTimeMilli -> { minimumPosixTimeMilli = posixTimeMilli })

        startTasks =
            responses |> List.concatMap .startTasks

        completeHttpResponses =
            responses |> List.concatMap .completeHttpResponses
    in
    { notifyWhenPosixTimeHasArrived = notifyWhenPosixTimeHasArrived
    , startTasks = startTasks
    , completeHttpResponses = completeHttpResponses
    , migrateResult = Nothing
    }


passiveBackendEventResponse : BackendEventResponse
passiveBackendEventResponse =
    { startTasks = []
    , completeHttpResponses = []
    , notifyWhenPosixTimeHasArrived = Nothing
    , migrateResult = Nothing
    }


withStartTasksAdded : List StartTaskStructure -> BackendEventResponse -> BackendEventResponse
withStartTasksAdded startTasksToAdd responseBefore =
    { responseBefore | startTasks = responseBefore.startTasks ++ startTasksToAdd }


withCompleteHttpResponsesAdded : List RespondToHttpRequestStruct -> BackendEventResponse -> BackendEventResponse
withCompleteHttpResponsesAdded httpResponsesToAdd responseBefore =
    { responseBefore | completeHttpResponses = responseBefore.completeHttpResponses ++ httpResponsesToAdd }


decodeBackendEvent : Json.Decode.Decoder BackendEvent
decodeBackendEvent =
    Json.Decode.oneOf
        [ Json.Decode.field "ArrivedAtTimeEvent" (Json.Decode.field "posixTimeMilli" Json.Decode.int)
            |> Json.Decode.map (\posixTimeMilli -> PosixTimeHasArrivedEvent { posixTimeMilli = posixTimeMilli })
        , Json.Decode.field "PosixTimeHasArrivedEvent" (Json.Decode.field "posixTimeMilli" Json.Decode.int)
            |> Json.Decode.map (\posixTimeMilli -> PosixTimeHasArrivedEvent { posixTimeMilli = posixTimeMilli })
        , Json.Decode.field "TaskCompleteEvent" decodeTaskCompleteEventStructure |> Json.Decode.map TaskCompleteEvent
        , Json.Decode.field "HttpRequestEvent" decodeHttpRequestEventStruct |> Json.Decode.map HttpRequestEvent
        , Json.Decode.field "InitStateEvent" (jsonDecodeSucceedWhenNotNull InitStateEvent)
        , Json.Decode.field "SetStateEvent" (Json.Decode.map SetStateEvent Json.Decode.string)
        , Json.Decode.field "MigrateStateEvent" (Json.Decode.map MigrateStateEvent Json.Decode.string)
        ]


decodeTaskCompleteEventStructure : Json.Decode.Decoder TaskCompleteEventStruct
decodeTaskCompleteEventStructure =
    Json.Decode.map2 TaskCompleteEventStruct
        (Json.Decode.field "taskId" Json.Decode.string)
        (Json.Decode.field "taskResult" decodeTaskResult)


decodeTaskResult : Json.Decode.Decoder TaskResultStructure
decodeTaskResult =
    Json.Decode.oneOf
        [ Json.Decode.field "CreateVolatileProcessResponse" (decodeResult decodeCreateVolatileProcessError decodeCreateVolatileProcessComplete)
            |> Json.Decode.map CreateVolatileProcessResponse
        , Json.Decode.field "RequestToVolatileProcessResponse" (decodeResult decodeRequestToVolatileProcessError decodeRequestToVolatileProcessComplete)
            |> Json.Decode.map RequestToVolatileProcessResponse
        , Json.Decode.field "CompleteWithoutResult" (jsonDecodeSucceedWhenNotNull CompleteWithoutResult)
        ]


decodeCreateVolatileProcessError : Json.Decode.Decoder CreateVolatileProcessErrorStruct
decodeCreateVolatileProcessError =
    Json.Decode.map CreateVolatileProcessErrorStruct
        (Json.Decode.field "exceptionToString" Json.Decode.string)


decodeCreateVolatileProcessComplete : Json.Decode.Decoder CreateVolatileProcessComplete
decodeCreateVolatileProcessComplete =
    Json.Decode.map CreateVolatileProcessComplete
        (Json.Decode.field "processId" Json.Decode.string)


decodeRequestToVolatileProcessComplete : Json.Decode.Decoder RequestToVolatileProcessComplete
decodeRequestToVolatileProcessComplete =
    Json.Decode.map3 RequestToVolatileProcessComplete
        (decodeOptionalField "exceptionToString" Json.Decode.string)
        (decodeOptionalField "returnValueToString" Json.Decode.string)
        (Json.Decode.field "durationInMilliseconds" Json.Decode.int)


decodeRequestToVolatileProcessError : Json.Decode.Decoder RequestToVolatileProcessError
decodeRequestToVolatileProcessError =
    Json.Decode.oneOf
        [ Json.Decode.field "ProcessNotFound" (jsonDecodeSucceedWhenNotNull ProcessNotFound)
        ]


decodeHttpRequestEventStruct : Json.Decode.Decoder HttpRequestEventStruct
decodeHttpRequestEventStruct =
    Json.Decode.map4 HttpRequestEventStruct
        (Json.Decode.field "httpRequestId" Json.Decode.string)
        (Json.Decode.field "posixTimeMilli" Json.Decode.int)
        (Json.Decode.field "requestContext" decodeHttpRequestContext)
        (Json.Decode.field "request" decodeHttpRequest)


decodeHttpRequestContext : Json.Decode.Decoder HttpRequestContext
decodeHttpRequestContext =
    Json.Decode.map HttpRequestContext
        (decodeOptionalField "clientAddress" Json.Decode.string)


decodeHttpRequest : Json.Decode.Decoder HttpRequestProperties
decodeHttpRequest =
    Json.Decode.map4 HttpRequestProperties
        (Json.Decode.field "method" Json.Decode.string)
        (Json.Decode.field "uri" Json.Decode.string)
        (decodeOptionalField "bodyAsBase64" Json.Decode.string)
        (Json.Decode.field "headers" (Json.Decode.list decodeHttpHeader))


decodeHttpHeader : Json.Decode.Decoder HttpHeader
decodeHttpHeader =
    Json.Decode.map2 HttpHeader
        (Json.Decode.field "name" Json.Decode.string)
        (Json.Decode.field "values" (Json.Decode.list Json.Decode.string))


encodeResponseOverSerialInterface : ResponseOverSerialInterface -> Json.Encode.Value
encodeResponseOverSerialInterface responseOverSerialInterface =
    (case responseOverSerialInterface of
        DecodeEventError error ->
            [ ( "DecodeEventError", error |> Json.Encode.string ) ]

        DecodeEventSuccess response ->
            [ ( "DecodeEventSuccess", response |> encodeBackendEventResponse ) ]
    )
        |> Json.Encode.object


encodeBackendEventResponse : BackendEventResponse -> Json.Encode.Value
encodeBackendEventResponse response =
    [ ( "notifyWhenPosixTimeHasArrived"
      , response.notifyWhenPosixTimeHasArrived
            |> Maybe.map (\time -> [ ( "minimumPosixTimeMilli", time.minimumPosixTimeMilli |> Json.Encode.int ) ] |> Json.Encode.object)
            |> Maybe.withDefault Json.Encode.null
      )
    , ( "startTasks", response.startTasks |> Json.Encode.list encodeStartTask )
    , ( "completeHttpResponses", response.completeHttpResponses |> Json.Encode.list encodeHttpResponseRequest )
    , ( "migrateResult", response.migrateResult |> jsonEncode__generic_Maybe (jsonEncode__generic_Result Json.Encode.string (always (Json.Encode.object []))) )
    ]
        |> Json.Encode.object


encodeStartTask : StartTaskStructure -> Json.Encode.Value
encodeStartTask startTaskAfterTime =
    Json.Encode.object
        [ ( "taskId", startTaskAfterTime.taskId |> encodeTaskId )
        , ( "task", startTaskAfterTime.task |> encodeTask )
        ]


encodeTaskId : TaskId -> Json.Encode.Value
encodeTaskId =
    Json.Encode.string


encodeTask : Task -> Json.Encode.Value
encodeTask task =
    case task of
        CreateVolatileProcess createVolatileProcess ->
            Json.Encode.object
                [ ( "CreateVolatileProcess"
                  , Json.Encode.object [ ( "programCode", createVolatileProcess.programCode |> Json.Encode.string ) ]
                  )
                ]

        RequestToVolatileProcess requestToVolatileProcess ->
            Json.Encode.object
                [ ( "RequestToVolatileProcess"
                  , Json.Encode.object
                        [ ( "processId", requestToVolatileProcess.processId |> Json.Encode.string )
                        , ( "request", requestToVolatileProcess.request |> Json.Encode.string )
                        ]
                  )
                ]

        TerminateVolatileProcess terminateVolatileProcess ->
            Json.Encode.object
                [ ( "TerminateVolatileProcess"
                  , Json.Encode.object
                        [ ( "processId", terminateVolatileProcess.processId |> Json.Encode.string )
                        ]
                  )
                ]


encodeHttpResponseRequest : RespondToHttpRequestStruct -> Json.Encode.Value
encodeHttpResponseRequest httpResponseRequest =
    Json.Encode.object
        [ ( "httpRequestId", httpResponseRequest.httpRequestId |> Json.Encode.string )
        , ( "response", httpResponseRequest.response |> encodeHttpResponse )
        ]


encodeHttpResponse : HttpResponse -> Json.Encode.Value
encodeHttpResponse httpResponse =
    [ ( "statusCode", httpResponse.statusCode |> Json.Encode.int )
    , ( "headersToAdd", httpResponse.headersToAdd |> Json.Encode.list encodeHttpHeader )
    , ( "bodyAsBase64", httpResponse.bodyAsBase64 |> Maybe.map Json.Encode.string |> Maybe.withDefault Json.Encode.null )
    ]
        |> Json.Encode.object


encodeHttpHeader : HttpHeader -> Json.Encode.Value
encodeHttpHeader httpHeader =
    [ ( "name", httpHeader.name |> Json.Encode.string )
    , ( "values", httpHeader.values |> Json.Encode.list Json.Encode.string )
    ]
        |> Json.Encode.object


jsonEncodeDeserializedState =
    Backend.InterfaceToHost_Root.Generated_9c46e930.jsonEncode_2ea38cf1d1

jsonDecodeDeserializedState =
    Backend.InterfaceToHost_Root.Generated_9c46e930.jsonDecode_2ea38cf1d1


jsonEncode__generic_Result : (a -> Json.Encode.Value) -> (b -> Json.Encode.Value) -> Result a b -> Json.Encode.Value
jsonEncode__generic_Result encodeErr encodeOk valueToEncode =
    case valueToEncode of
        Err valueToEncodeError ->
            [ ( "Err", encodeErr valueToEncodeError ) ] |> Json.Encode.object

        Ok valueToEncodeOk ->
            [ ( "Ok", encodeOk valueToEncodeOk ) ] |> Json.Encode.object


jsonEncode__generic_Maybe : (a -> Json.Encode.Value) -> Maybe a -> Json.Encode.Value
jsonEncode__generic_Maybe encodeJust valueToEncode =
    case valueToEncode of
        Nothing ->
            [ ( "Nothing", [] |> Json.Encode.list identity ) ] |> Json.Encode.object

        Just just ->
            [ ( "Just", encodeJust just ) ] |> Json.Encode.object


decodeResult : Json.Decode.Decoder error -> Json.Decode.Decoder ok -> Json.Decode.Decoder (Result error ok)
decodeResult errorDecoder okDecoder =
    Json.Decode.oneOf
        [ Json.Decode.field "Err" errorDecoder |> Json.Decode.map Err
        , Json.Decode.field "Ok" okDecoder |> Json.Decode.map Ok
        ]


jsonDecodeSucceedWhenNotNull : a -> Json.Decode.Decoder a
jsonDecodeSucceedWhenNotNull valueIfNotNull =
    Json.Decode.value
        |> Json.Decode.andThen
            (\asValue ->
                if asValue == Json.Encode.null then
                    Json.Decode.fail "Is null."

                else
                    Json.Decode.succeed valueIfNotNull
            )


decodeOptionalField : String -> Json.Decode.Decoder a -> Json.Decode.Decoder (Maybe a)
decodeOptionalField fieldName decoder =
    let
        finishDecoding json =
            case Json.Decode.decodeValue (Json.Decode.field fieldName Json.Decode.value) json of
                Ok _ ->
                    -- The field is present, so run the decoder on it.
                    Json.Decode.map Just (Json.Decode.field fieldName decoder)

                Err _ ->
                    -- The field was missing, which is fine!
                    Json.Decode.succeed Nothing
    in
    Json.Decode.value
        |> Json.Decode.andThen finishDecoding
