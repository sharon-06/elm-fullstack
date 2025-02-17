module ElmFullstack exposing (..)

{-| The `ElmFullstack` module provides the types to build backend app declarations.
The type declarations in this module mirror the interface of the Elm Fullstack executable file and enable type-checking for compatibility.
-}


{-| Describe a complete backend app. A backend app can handle HTTP requests or spawn volatile processes to integrate other software
components.
The `BackendConfig` type does not include migrations because their types, by definition, can vary independently of the other types.
-}
type alias BackendConfig state =
    { init : ( state, BackendCmds state )
    , subscriptions : state -> BackendSubs state
    }


type alias BackendSubs state =
    { httpRequest : HttpRequestEventStruct -> state -> ( state, BackendCmds state )
    , posixTimeIsPast :
        Maybe
            { minimumPosixTimeMilli : Int
            , update : { currentPosixTimeMilli : Int } -> state -> ( state, BackendCmds state )
            }
    }


type alias BackendCmds state =
    List (BackendCmd state)


type BackendCmd state
    = RespondToHttpRequest RespondToHttpRequestStruct
    | CreateVolatileProcess (CreateVolatileProcessStruct state)
    | RequestToVolatileProcess (RequestToVolatileProcessStruct state)
    | TerminateVolatileProcess TerminateVolatileProcessStruct


type alias HttpRequestEventStruct =
    { httpRequestId : String
    , posixTimeMilli : Int
    , requestContext : HttpRequestContext
    , request : HttpRequestProperties
    }


type alias HttpRequestContext =
    { clientAddress : Maybe String
    }


type alias HttpRequestProperties =
    { method : String
    , uri : String
    , bodyAsBase64 : Maybe String
    , headers : List HttpHeader
    }


type alias RespondToHttpRequestStruct =
    { httpRequestId : String
    , response : HttpResponse
    }


type alias HttpResponse =
    { statusCode : Int
    , bodyAsBase64 : Maybe String
    , headersToAdd : List HttpHeader
    }


type alias HttpHeader =
    { name : String
    , values : List String
    }


type alias CreateVolatileProcessStruct state =
    { programCode : String
    , update : CreateVolatileProcessResult -> state -> ( state, BackendCmds state )
    }


type alias CreateVolatileProcessResult =
    Result CreateVolatileProcessErrorStruct CreateVolatileProcessComplete


type alias CreateVolatileProcessErrorStruct =
    { exceptionToString : String
    }


type alias CreateVolatileProcessComplete =
    { processId : String }


type alias RequestToVolatileProcessStruct state =
    { processId : String
    , request : String
    , update : RequestToVolatileProcessResult -> state -> ( state, BackendCmds state )
    }


type alias RequestToVolatileProcessResult =
    Result RequestToVolatileProcessError RequestToVolatileProcessComplete


type RequestToVolatileProcessError
    = ProcessNotFound


type alias RequestToVolatileProcessComplete =
    { exceptionToString : Maybe String
    , returnValueToString : Maybe String
    , durationInMilliseconds : Int
    }


type alias TerminateVolatileProcessStruct =
    { processId : String }
