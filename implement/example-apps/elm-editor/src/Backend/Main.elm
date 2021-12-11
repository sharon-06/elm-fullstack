module Backend.Main exposing
    ( State
    , backendMain
    )

import Backend.Route
import Backend.VolatileProcess as VolatileProcess
import Base64
import Bytes.Encode
import Common
import CompilationInterface.ElmMake
import CompilationInterface.SourceFiles
import Dict
import ElmFullstack
import FileTree
import Flate
import MonacoHtml
import Set
import Url


type Event
    = HttpRequestEvent ElmFullstack.HttpRequestEventStruct
    | CreateVolatileProcessResponse ElmFullstack.CreateVolatileProcessResult
    | RequestToVolatileProcessResponse String ElmFullstack.RequestToVolatileProcessResult


type alias State =
    { posixTimeMilli : Int
    , volatileProcessesIds : Set.Set String
    , pendingHttpRequests : List ElmFullstack.HttpRequestEventStruct
    , pendingTasksForRequestVolatileProcess : Dict.Dict String { volatileProcessId : String, startPosixTimeMilli : Int }
    }


parallelVolatileProcessesCount : Int
parallelVolatileProcessesCount =
    3


requestToVolatileProcessTimeoutMilliseconds : Int
requestToVolatileProcessTimeoutMilliseconds =
    1000 * 30


backendMain : ElmFullstack.BackendConfig State
backendMain =
    { init = ( initState, [] )
    , subscriptions = subscriptions
    }


initState : State
initState =
    { posixTimeMilli = 0
    , volatileProcessesIds = Set.empty
    , pendingHttpRequests = []
    , pendingTasksForRequestVolatileProcess = Dict.empty
    }


subscriptions : State -> ElmFullstack.BackendSubs State
subscriptions _ =
    { httpRequest = updateForHttpRequestEvent
    , posixTimeIsPast = Nothing
    }


updateForHttpRequestEvent : ElmFullstack.HttpRequestEventStruct -> State -> ( State, ElmFullstack.BackendCmds State )
updateForHttpRequestEvent httpRequestEvent =
    processEvent (HttpRequestEvent httpRequestEvent)


processEvent : Event -> State -> ( State, ElmFullstack.BackendCmds State )
processEvent hostEvent stateBefore =
    let
        ( ( state, toVolatileProcessesCmds ), responseCmds ) =
            updateExceptRequestsToVolatileProcess hostEvent stateBefore
                |> Tuple.mapFirst updatePartRequestsToVolatileProcess
    in
    ( state
    , responseCmds ++ toVolatileProcessesCmds
    )


updatePartRequestsToVolatileProcess : State -> ( State, ElmFullstack.BackendCmds State )
updatePartRequestsToVolatileProcess stateBefore =
    let
        tasksToEnsureEnoughVolatileProcessesCreated =
            if Set.size stateBefore.volatileProcessesIds < parallelVolatileProcessesCount then
                [ ElmFullstack.CreateVolatileProcess
                    { programCode = VolatileProcess.volatileProcessProgramCode
                    , update =
                        \createVolatileProcessResult ->
                            processEvent (CreateVolatileProcessResponse createVolatileProcessResult)
                    }
                ]

            else
                []

        pendingHttpRequestsWithTaskId =
            stateBefore.pendingHttpRequests
                |> List.map (\httpRequest -> ( taskIdForHttpRequest httpRequest, httpRequest ))

        pendingTasksForRequestVolatileProcessAfterTimeLimit =
            stateBefore.pendingTasksForRequestVolatileProcess
                |> Dict.filter
                    (\_ pendingTask ->
                        stateBefore.posixTimeMilli < pendingTask.startPosixTimeMilli + requestToVolatileProcessTimeoutMilliseconds
                    )

        pendingHttpRequestsWithoutPendingRequestToVolatileProcess =
            pendingHttpRequestsWithTaskId
                |> List.filter
                    (\( taskId, _ ) -> pendingTasksForRequestVolatileProcessAfterTimeLimit |> Dict.member taskId |> not)

        freeVolatileProcessesIds =
            stateBefore.volatileProcessesIds
                |> Set.filter
                    (\volatileProcessId ->
                        pendingTasksForRequestVolatileProcessAfterTimeLimit
                            |> Dict.values
                            |> List.any (.volatileProcessId >> (==) volatileProcessId)
                            |> not
                    )

        continueWithoutRequestToVolatileProcess =
            ( stateBefore, tasksToEnsureEnoughVolatileProcessesCreated )
    in
    case pendingHttpRequestsWithoutPendingRequestToVolatileProcess |> List.head of
        Nothing ->
            continueWithoutRequestToVolatileProcess

        Just ( taskId, httpRequestEvent ) ->
            case List.head (Set.toList freeVolatileProcessesIds) of
                Nothing ->
                    continueWithoutRequestToVolatileProcess

                Just volatileProcessId ->
                    let
                        task =
                            ElmFullstack.RequestToVolatileProcess
                                { processId = volatileProcessId
                                , request =
                                    httpRequestEvent.request.bodyAsBase64
                                        |> Maybe.andThen Common.decodeBase64ToString
                                        |> Maybe.withDefault "Error decoding base64"
                                , update =
                                    \requestToVolatileProcessResponse ->
                                        processEvent
                                            (RequestToVolatileProcessResponse taskId requestToVolatileProcessResponse)
                                }

                        pendingTasksForRequestVolatileProcess =
                            pendingTasksForRequestVolatileProcessAfterTimeLimit
                                |> Dict.insert taskId
                                    { startPosixTimeMilli = stateBefore.posixTimeMilli
                                    , volatileProcessId = volatileProcessId
                                    }
                    in
                    ( { stateBefore
                        | pendingTasksForRequestVolatileProcess = pendingTasksForRequestVolatileProcess
                      }
                    , [ task ]
                    )


updateExceptRequestsToVolatileProcess : Event -> State -> ( State, ElmFullstack.BackendCmds State )
updateExceptRequestsToVolatileProcess hostEvent stateBefore =
    case hostEvent of
        HttpRequestEvent httpRequestEvent ->
            updateForHttpRequestEventExceptRequestsToVolatileProcess httpRequestEvent stateBefore

        RequestToVolatileProcessResponse taskId requestToVolatileProcessResponse ->
            updateForRequestToVolatileProcessResult taskId requestToVolatileProcessResponse stateBefore

        CreateVolatileProcessResponse createVolatileProcessResponse ->
            updateForCreateVolatileProcessResult createVolatileProcessResponse stateBefore


updateForHttpRequestEventExceptRequestsToVolatileProcess : ElmFullstack.HttpRequestEventStruct -> State -> ( State, ElmFullstack.BackendCmds State )
updateForHttpRequestEventExceptRequestsToVolatileProcess httpRequestEvent stateBeforeUpdatingTime =
    let
        stateBefore =
            { stateBeforeUpdatingTime | posixTimeMilli = httpRequestEvent.posixTimeMilli }

        bodyFromString =
            Bytes.Encode.string >> Bytes.Encode.encode >> Base64.fromBytes

        staticContentHttpHeaders contentType =
            { cacheMaxAgeMinutes = Just (60 * 4)
            , contentType = contentType
            }

        httpResponseOkWithStringContent stringContent httpResponseHeaders =
            httpResponseOkWithBodyAsBase64 (bodyFromString stringContent) httpResponseHeaders

        httpResponseOkWithBodyAsBase64 bodyAsBase64 { cacheMaxAgeMinutes, contentType } =
            let
                cacheHeaders =
                    case cacheMaxAgeMinutes of
                        Nothing ->
                            []

                        Just maxAgeMinutes ->
                            [ { name = "Cache-Control"
                              , values = [ "public, max-age=" ++ String.fromInt (maxAgeMinutes * 60) ]
                              }
                            , { name = "Content-Type"
                              , values = [ contentType ]
                              }
                            ]
            in
            { statusCode = 200
            , bodyAsBase64 = bodyAsBase64
            , headersToAdd = cacheHeaders
            }

        frontendHtmlDocumentResponse frontendConfig =
            httpResponseOkWithStringContent (frontendHtmlDocument frontendConfig)
                (staticContentHttpHeaders "text/html")

        continueWithStaticHttpResponse httpResponse =
            ( stateBefore
            , [ ElmFullstack.RespondToHttpRequest
                    { httpRequestId = httpRequestEvent.httpRequestId
                    , response = httpResponse
                    }
              ]
            )
    in
    case httpRequestEvent.request.uri |> Url.fromString of
        Nothing ->
            continueWithStaticHttpResponse
                { statusCode = 500
                , bodyAsBase64 = bodyFromString "Failed to parse URL"
                , headersToAdd = []
                }

        Just url ->
            case
                CompilationInterface.SourceFiles.file_tree____static
                    |> mapFileTreeNodeFromSource
                    |> FileTree.flatListOfBlobsFromFileTreeNode
                    |> List.filter (Tuple.first >> (==) (String.split "/" url.path |> List.filter (String.isEmpty >> not)))
                    |> List.head
            of
                Just ( filePath, matchingFile ) ->
                    let
                        contentType =
                            filePath
                                |> List.concatMap (String.split ".")
                                |> List.reverse
                                |> List.head
                                |> Maybe.andThen (Dict.get >> (|>) contentTypeFromStaticFileExtensionDict)
                                |> Maybe.withDefault ""
                    in
                    httpResponseOkWithBodyAsBase64
                        (Just matchingFile.base64)
                        { cacheMaxAgeMinutes = Just 1440, contentType = contentType }
                        |> continueWithStaticHttpResponse

                Nothing ->
                    case url |> Backend.Route.routeFromUrl of
                        Nothing ->
                            frontendHtmlDocumentResponse { debug = False }
                                |> continueWithStaticHttpResponse

                        Just (Backend.Route.StaticFileRoute (Backend.Route.FrontendHtmlDocumentRoute frontendConfig)) ->
                            frontendHtmlDocumentResponse frontendConfig
                                |> continueWithStaticHttpResponse

                        Just (Backend.Route.StaticFileRoute (Backend.Route.FrontendElmJavascriptRoute { debug })) ->
                            httpResponseOkWithBodyAsBase64
                                (Just
                                    (if debug then
                                        CompilationInterface.ElmMake.elm_make____src_Frontend_Main_elm.debug.javascript.base64

                                     else
                                        CompilationInterface.ElmMake.elm_make____src_Frontend_Main_elm.javascript.base64
                                    )
                                )
                                (staticContentHttpHeaders "text/javascript")
                                |> continueWithStaticHttpResponse

                        Just (Backend.Route.StaticFileRoute Backend.Route.MonacoFrameDocumentRoute) ->
                            httpResponseOkWithStringContent monacoHtmlDocument
                                (staticContentHttpHeaders "text/html")
                                |> continueWithStaticHttpResponse

                        Just Backend.Route.ApiRoute ->
                            ( { stateBefore
                                | pendingHttpRequests = httpRequestEvent :: stateBefore.pendingHttpRequests |> List.take 10
                              }
                            , []
                            )


updateForRequestToVolatileProcessResult : String -> ElmFullstack.RequestToVolatileProcessResult -> State -> ( State, ElmFullstack.BackendCmds State )
updateForRequestToVolatileProcessResult taskId requestToVolatileProcessResult stateBefore =
    case
        stateBefore.pendingHttpRequests
            |> List.filter (taskIdForHttpRequest >> (==) taskId)
            |> List.head
    of
        Nothing ->
            ( stateBefore
            , []
            )

        Just httpRequestEvent ->
            let
                bodyFromString =
                    Bytes.Encode.string >> Bytes.Encode.encode >> Base64.fromBytes

                httpResponseInternalServerError errorMessage =
                    { statusCode = 500
                    , bodyAsBase64 = bodyFromString errorMessage
                    , headersToAdd = []
                    }

                ( httpResponse, maybeVolatileProcessToRemoveId ) =
                    case stateBefore.pendingTasksForRequestVolatileProcess |> Dict.get taskId of
                        Nothing ->
                            ( httpResponseInternalServerError
                                ("Error: Did not find entry for task ID '" ++ taskId ++ "'")
                            , stateBefore.pendingTasksForRequestVolatileProcess
                                |> Dict.get taskId
                                |> Maybe.map .volatileProcessId
                            )

                        Just pendingTask ->
                            case requestToVolatileProcessResult of
                                Err ElmFullstack.ProcessNotFound ->
                                    ( httpResponseInternalServerError
                                        ("Error: Volatile process '"
                                            ++ pendingTask.volatileProcessId
                                            ++ "' disappeared. Starting volatile process again... Please retry."
                                        )
                                    , Just pendingTask.volatileProcessId
                                    )

                                Ok requestToVolatileProcessComplete ->
                                    case requestToVolatileProcessComplete.exceptionToString of
                                        Just exceptionToString ->
                                            ( { statusCode = 500
                                              , bodyAsBase64 = bodyFromString ("Exception in volatile process:\n" ++ exceptionToString)
                                              , headersToAdd = []
                                              }
                                            , Nothing
                                            )

                                        Nothing ->
                                            let
                                                ( headersToAdd, bodyAsBase64 ) =
                                                    case requestToVolatileProcessComplete.returnValueToString of
                                                        Nothing ->
                                                            ( [], Nothing )

                                                        Just returnValueToString ->
                                                            let
                                                                deflateEncodedBody =
                                                                    returnValueToString
                                                                        |> Bytes.Encode.string
                                                                        |> Bytes.Encode.encode
                                                                        |> Flate.deflateGZip
                                                            in
                                                            ( [ { name = "Content-Encoding", values = [ "gzip" ] } ]
                                                            , deflateEncodedBody |> Base64.fromBytes
                                                            )
                                            in
                                            ( { statusCode = 200
                                              , bodyAsBase64 = bodyAsBase64
                                              , headersToAdd = headersToAdd
                                              }
                                            , Nothing
                                            )

                volatileProcessesIds =
                    case maybeVolatileProcessToRemoveId of
                        Nothing ->
                            stateBefore.volatileProcessesIds

                        Just volatileProcessToRemoveId ->
                            stateBefore.volatileProcessesIds |> Set.remove volatileProcessToRemoveId
            in
            ( { stateBefore
                | pendingHttpRequests = stateBefore.pendingHttpRequests |> List.filter ((==) httpRequestEvent >> not)
                , volatileProcessesIds = volatileProcessesIds
                , pendingTasksForRequestVolatileProcess = stateBefore.pendingTasksForRequestVolatileProcess |> Dict.remove taskId
              }
            , [ ElmFullstack.RespondToHttpRequest
                    { httpRequestId = httpRequestEvent.httpRequestId
                    , response = httpResponse
                    }
              ]
            )


updateForCreateVolatileProcessResult : ElmFullstack.CreateVolatileProcessResult -> State -> ( State, ElmFullstack.BackendCmds State )
updateForCreateVolatileProcessResult createVolatileProcessResult stateBefore =
    case createVolatileProcessResult of
        Err createVolatileProcessError ->
            let
                bodyFromString =
                    Bytes.Encode.string >> Bytes.Encode.encode >> Base64.fromBytes

                httpResponse =
                    { statusCode = 500
                    , bodyAsBase64 = bodyFromString ("Failed to create volatile process: " ++ createVolatileProcessError.exceptionToString)
                    , headersToAdd = []
                    }

                httpResponses =
                    stateBefore.pendingHttpRequests
                        |> List.map
                            (\httpRequest ->
                                { httpRequestId = httpRequest.httpRequestId
                                , response = httpResponse
                                }
                            )
            in
            ( { stateBefore | pendingHttpRequests = [] }
            , List.map ElmFullstack.RespondToHttpRequest httpResponses
            )

        Ok { processId } ->
            ( { stateBefore
                | volatileProcessesIds = Set.insert processId stateBefore.volatileProcessesIds
              }
            , []
            )


taskIdForHttpRequest : ElmFullstack.HttpRequestEventStruct -> String
taskIdForHttpRequest httpRequestEvent =
    "http-request-api-" ++ httpRequestEvent.httpRequestId


frontendHtmlDocument : { debug : Bool } -> String
frontendHtmlDocument { debug } =
    let
        elmMadeScriptFileName =
            if debug then
                Backend.Route.elmMadeScriptFileNameDebug

            else
                Backend.Route.elmMadeScriptFileNameDefault
    in
    """
<!DOCTYPE HTML>
<html>

<head>
  <meta charset="UTF-8">
  <title>Elm Editor</title>
  <link rel="icon" href="/"""
        ++ Common.faviconPath
        ++ """" type="image/svg+xml">
  <script type="text/javascript" src="""
        ++ elmMadeScriptFileName
        ++ """></script>
</head>

<body>
    <div id="elm-app-container"></div>
</body>

<script type="text/javascript">

var app = Elm.Frontend.Main.init({
    node: document.getElementById('elm-app-container')
});

app.ports.sendMessageToMonacoFrame.subscribe(function(message) {
    document.getElementById('monaco-iframe')?.contentWindow?.dispatchMessage?.(message);
});

function messageFromMonacoFrame(message) {
    app.ports.receiveMessageFromMonacoFrame?.send(message);
}

</script>

</html>
"""


monacoHtmlDocument : String
monacoHtmlDocument =
    MonacoHtml.monacoHtmlDocumentFromCdnUrl (monacoCdnURLs |> List.head |> Maybe.withDefault "Missing URL to CDN")


{-| <https://github.com/microsoft/monaco-editor/issues/583>
-}
monacoCdnURLs : List String
monacoCdnURLs =
    [ "https://unpkg.com/monaco-editor@0.27.0/min"
    , "https://cdn.jsdelivr.net/npm/monaco-editor@0.27/min"
    ]


contentTypeFromStaticFileExtensionDict : Dict.Dict String String
contentTypeFromStaticFileExtensionDict =
    [ ( "svg", "image/svg+xml" )
    , ( "js", "text/javascript" )
    ]
        |> Dict.fromList


mapFileTreeNodeFromSource : CompilationInterface.SourceFiles.FileTreeNode a -> FileTree.FileTreeNode a
mapFileTreeNodeFromSource node =
    case node of
        CompilationInterface.SourceFiles.BlobNode blob ->
            FileTree.BlobNode blob

        CompilationInterface.SourceFiles.TreeNode tree ->
            tree |> List.map (Tuple.mapSecond mapFileTreeNodeFromSource) |> FileTree.TreeNode
