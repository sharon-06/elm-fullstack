module Backend.Main exposing
    ( State
    , backendMain
    )

import Base64
import Bytes.Encode
import CompilationInterface.SourceFiles
import ElmFullstack
import FileTree
import Url


type alias State =
    {}


backendMain : ElmFullstack.BackendConfig State
backendMain =
    { init = ( {}, [] )
    , subscriptions = subscriptions
    }


subscriptions : State -> ElmFullstack.BackendSubs State
subscriptions _ =
    { httpRequest = updateForHttpRequestEvent
    , posixTimeIsPast = Nothing
    }


updateForHttpRequestEvent : ElmFullstack.HttpRequestEventStruct -> State -> ( State, ElmFullstack.BackendCmds State )
updateForHttpRequestEvent httpRequestEvent stateBefore =
    let
        response =
            if (httpRequestEvent.request.method |> String.toLower) /= "get" then
                { statusCode = 405
                , bodyAsBase64 = Nothing
                , headersToAdd = []
                }

            else
                case Url.fromString httpRequestEvent.request.uri of
                    Nothing ->
                        { statusCode = 500
                        , bodyAsBase64 =
                            "Failed to parse URL"
                                |> Bytes.Encode.string
                                |> Bytes.Encode.encode
                                |> Base64.fromBytes
                        , headersToAdd = []
                        }

                    Just url ->
                        case httpRequestEvent.request.uri |> String.split "/" |> List.reverse |> List.head of
                            Just "utf8" ->
                                { statusCode = 200
                                , bodyAsBase64 =
                                    CompilationInterface.SourceFiles.file____readme_md.utf8
                                        |> Bytes.Encode.string
                                        |> Bytes.Encode.encode
                                        |> Base64.fromBytes
                                , headersToAdd =
                                    [ { name = "Cache-Control", values = [ "public, max-age=3600" ] }
                                    ]
                                }

                            _ ->
                                case
                                    CompilationInterface.SourceFiles.file_tree____static_content
                                        |> mapFileTreeNodeFromSource
                                        |> FileTree.flatListOfBlobsFromFileTreeNode
                                        |> List.filter (Tuple.first >> (==) (String.split "/" url.path |> List.filter (String.isEmpty >> not)))
                                        |> List.head
                                of
                                    Just ( _, matchingFile ) ->
                                        { statusCode = 200
                                        , bodyAsBase64 = Just matchingFile.base64
                                        , headersToAdd =
                                            [ { name = "Cache-Control", values = [ "public, max-age=3600" ] }
                                            ]
                                        }

                                    Nothing ->
                                        { statusCode = 404
                                        , bodyAsBase64 = Nothing
                                        , headersToAdd = []
                                        }

        httpResponse =
            { httpRequestId = httpRequestEvent.httpRequestId
            , response = response
            }
    in
    ( stateBefore
    , [ ElmFullstack.RespondToHttpRequest httpResponse ]
    )


mapFileTreeNodeFromSource : CompilationInterface.SourceFiles.FileTreeNode a -> FileTree.FileTreeNode a
mapFileTreeNodeFromSource node =
    case node of
        CompilationInterface.SourceFiles.BlobNode blob ->
            FileTree.BlobNode blob

        CompilationInterface.SourceFiles.TreeNode tree ->
            tree |> List.map (Tuple.mapSecond mapFileTreeNodeFromSource) |> FileTree.TreeNode
