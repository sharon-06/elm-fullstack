using System;
using System.Collections.Concurrent;
using System.Linq;
using FluffySpoon.AspNet.LetsEncrypt;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Pine;

namespace ElmFullstack.WebHost;

public class StartupPublicApp
{
    private readonly ILogger<StartupPublicApp> _logger;

    static TimeSpan NotifyTimeHasArrivedMaximumDistance => TimeSpan.FromSeconds(10);

    public StartupPublicApp(ILogger<StartupPublicApp> logger)
    {
        _logger = logger;

        _logger.LogTrace("Testing LogTrace");
        _logger.LogDebug("Testing LogDebug");
    }

    public void ConfigureServices(IServiceCollection services)
    {
        var serviceProvider = services.BuildServiceProvider();
        var config = serviceProvider.GetService<IConfiguration>();

        var getDateTimeOffset = serviceProvider.GetService<Func<DateTimeOffset>>();

        if (getDateTimeOffset == null)
        {
            getDateTimeOffset = () => DateTimeOffset.UtcNow;
            services.AddSingleton(getDateTimeOffset);
        }

        var webAppAndElmAppConfig = serviceProvider.GetService<WebAppAndElmAppConfig>();

        if (webAppAndElmAppConfig == null)
        {
            throw new Exception("Missing reference to the web app config.");
        }

        {
            var letsEncryptOptions = webAppAndElmAppConfig.WebAppConfiguration?.letsEncryptOptions;

            if (letsEncryptOptions == null)
            {
                _logger.LogInformation("I did not find 'letsEncryptOptions' in the configuration. I continue without Let's Encrypt.");
            }
            else
            {
                _logger.LogInformation("I found 'letsEncryptOptions' in the configuration.");
                services.AddFluffySpoonLetsEncryptRenewalService(letsEncryptOptions);
                services.AddFluffySpoonLetsEncryptFileCertificatePersistence();
                services.AddFluffySpoonLetsEncryptMemoryChallengePersistence();
            }
        }

        Asp.ConfigureServices(services);
    }

    public void Configure(
        IApplicationBuilder app,
        IWebHostEnvironment env,
        WebAppAndElmAppConfig webAppAndElmAppConfig,
        Func<DateTimeOffset> getDateTimeOffset,
        IHostApplicationLifetime appLifetime)
    {
        if (env.IsDevelopment())
        {
            app.UseDeveloperExceptionPage();
        }

        var state = new PublicAppState(webAppAndElmAppConfig: webAppAndElmAppConfig, getDateTimeOffset: getDateTimeOffset);

        appLifetime.ApplicationStopping.Register(() =>
        {
            state.applicationStoppingCancellationTokenSource.Cancel();
            _logger?.LogInformation("Public app noticed ApplicationStopping.");
        });

        if (webAppAndElmAppConfig.WebAppConfiguration?.letsEncryptOptions != null)
            app.UseFluffySpoonLetsEncryptChallengeApprovalMiddleware();


        state.ProcessEventTimeHasArrived();

        app
            .Use(async (context, next) => await Asp.MiddlewareFromWebAppConfig(webAppAndElmAppConfig.WebAppConfiguration, context, next))
            .Run(state.Run);
    }

    class PublicAppState
    {
        long nextHttpRequestIndex = 0;

        int createVolatileProcessAttempts = 0;

        readonly ConcurrentDictionary<string, InterfaceToHost.HttpResponse> appTaskCompleteHttpResponse = new();

        readonly ConcurrentDictionary<string, VolatileProcess> volatileProcesses = new();

        readonly public System.Threading.CancellationTokenSource applicationStoppingCancellationTokenSource = new();

        readonly WebAppAndElmAppConfig webAppAndElmAppConfig;
        readonly Func<DateTimeOffset> getDateTimeOffset;

        readonly System.Threading.Timer notifyTimeHasArrivedTimer;

        readonly object nextTimeToNotifyLock = new();

        DateTimeOffset? lastAppEventTimeHasArrived = null;
        InterfaceToHost.NotifyWhenPosixTimeHasArrivedRequestStructure? nextTimeToNotify = null;

        public PublicAppState(
            WebAppAndElmAppConfig webAppAndElmAppConfig,
            Func<DateTimeOffset> getDateTimeOffset)
        {
            this.webAppAndElmAppConfig = webAppAndElmAppConfig;
            this.getDateTimeOffset = getDateTimeOffset;

            if (webAppAndElmAppConfig.InitOrMigrateCmds != null)
                ForwardTasksFromResponseCmds(webAppAndElmAppConfig.InitOrMigrateCmds);

            notifyTimeHasArrivedTimer = new System.Threading.Timer(
                callback: _ =>
                {
                    if (applicationStoppingCancellationTokenSource.IsCancellationRequested)
                    {
                        notifyTimeHasArrivedTimer?.Dispose();
                        return;
                    }

                    lock (nextTimeToNotifyLock)
                    {
                        if (applicationStoppingCancellationTokenSource.IsCancellationRequested)
                        {
                            notifyTimeHasArrivedTimer?.Dispose();
                            return;
                        }

                        var localNextTimeToNotify = nextTimeToNotify;

                        if (localNextTimeToNotify != null && localNextTimeToNotify.minimumPosixTimeMilli <= getDateTimeOffset().ToUnixTimeMilliseconds())
                        {
                            nextTimeToNotify = null;
                            ProcessEventTimeHasArrived();
                            return;
                        }
                    }

                    if (!lastAppEventTimeHasArrived.HasValue ||
                        NotifyTimeHasArrivedMaximumDistance <= (getDateTimeOffset() - lastAppEventTimeHasArrived.Value))
                    {
                        ProcessEventTimeHasArrived();
                    }
                },
                state: null,
                dueTime: TimeSpan.Zero,
                period: TimeSpan.FromMilliseconds(10));
        }

        public async System.Threading.Tasks.Task Run(HttpContext context)
        {
            var currentDateTime = getDateTimeOffset();
            var timeMilli = currentDateTime.ToUnixTimeMilliseconds();
            var httpRequestIndex = System.Threading.Interlocked.Increment(ref nextHttpRequestIndex);

            var httpRequestId = timeMilli.ToString() + "-" + httpRequestIndex.ToString();

            var httpRequestEvent =
                await AsPersistentProcessInterfaceHttpRequestEvent(context, httpRequestId, currentDateTime);

            var httpRequestInterfaceEvent = new InterfaceToHost.AppEventStructure
            {
                HttpRequestEvent = httpRequestEvent,
            };

            var preparedProcessEvent = PrepareProcessEventAndResultingRequests(httpRequestInterfaceEvent);

            if (webAppAndElmAppConfig.WebAppConfiguration?.httpRequestEventSizeLimit < preparedProcessEvent.serializedInterfaceEvent?.Length)
            {
                context.Response.StatusCode = StatusCodes.Status413RequestEntityTooLarge;
                await context.Response.WriteAsync("Request is too large.");
                return;
            }

            preparedProcessEvent.processEventAndResultingRequests();

            var waitForHttpResponseClock = System.Diagnostics.Stopwatch.StartNew();

            while (true)
            {
                if (appTaskCompleteHttpResponse.TryRemove(httpRequestId, out var httpResponse))
                {
                    var headerContentType =
                        httpResponse.headersToAdd
                        ?.FirstOrDefault(header => header.name?.ToLowerInvariant() == "content-type")
                        ?.values?.FirstOrDefault();

                    context.Response.StatusCode = httpResponse.statusCode;

                    foreach (var headerToAdd in httpResponse.headersToAdd.EmptyIfNull())
                        context.Response.Headers[headerToAdd.name] = new Microsoft.Extensions.Primitives.StringValues(headerToAdd.values);

                    if (headerContentType != null)
                        context.Response.ContentType = headerContentType;

                    ReadOnlyMemory<byte>? contentAsByteArray = null;

                    if (httpResponse?.bodyAsBase64 != null)
                    {
                        var buffer = new byte[httpResponse.bodyAsBase64.Length * 3 / 4];

                        if (!Convert.TryFromBase64String(httpResponse.bodyAsBase64, buffer, out var bytesWritten))
                        {
                            throw new FormatException(
                                "Failed to convert from base64. bytesWritten=" + bytesWritten +
                                ", input.length=" + httpResponse.bodyAsBase64.Length + ", input:\n" +
                                httpResponse.bodyAsBase64);
                        }

                        contentAsByteArray = buffer.AsMemory(0, bytesWritten);
                    }

                    context.Response.ContentLength = contentAsByteArray?.Length ?? 0;

                    if (contentAsByteArray != null)
                        await context.Response.Body.WriteAsync(contentAsByteArray.Value);

                    break;
                }

                if (60 <= waitForHttpResponseClock.Elapsed.TotalSeconds)
                    throw new TimeoutException(
                        "The app did not return a HTTP response within " +
                        (int)waitForHttpResponseClock.Elapsed.TotalSeconds +
                        " seconds.");

                System.Threading.Thread.Sleep(100);
            }
        }

        public void ProcessEventTimeHasArrived()
        {
            var currentTime = getDateTimeOffset();

            lastAppEventTimeHasArrived = currentTime;

            ProcessEventAndResultingRequests(new InterfaceToHost.AppEventStructure
            {
                ArrivedAtTimeEvent = new InterfaceToHost.ArrivedAtTimeEventStructure
                (
                    posixTimeMilli: currentTime.ToUnixTimeMilliseconds()
                )
            });
        }

        (string serializedInterfaceEvent, Action processEventAndResultingRequests) PrepareProcessEventAndResultingRequests(
            InterfaceToHost.AppEventStructure interfaceEvent)
        {
            var serializedInterfaceEvent =
                Newtonsoft.Json.JsonConvert.SerializeObject(
                    interfaceEvent, InterfaceToHost.AppEventStructure.JsonSerializerSettings);

            var processEvent = new Action(() =>
            {
                if (applicationStoppingCancellationTokenSource.IsCancellationRequested)
                    return;

                try
                {
                    var serializedResponse = webAppAndElmAppConfig.ProcessEventInElmApp(serializedInterfaceEvent);

                    try
                    {
                        var structuredResponse =
                            Newtonsoft.Json.JsonConvert.DeserializeObject<InterfaceToHost.ResponseOverSerialInterface>(
                                serializedResponse);

                        if (structuredResponse.DecodeEventSuccess == null)
                        {
                            throw new Exception("Hosted app failed to decode the event: " + structuredResponse.DecodeEventError);
                        }

                        var notifyWhenPosixTimeHasArrived = structuredResponse.DecodeEventSuccess.notifyWhenPosixTimeHasArrived;

                        if (notifyWhenPosixTimeHasArrived != null)
                        {
                            System.Threading.Tasks.Task.Run(() =>
                            {
                                lock (nextTimeToNotifyLock)
                                {
                                    nextTimeToNotify = notifyWhenPosixTimeHasArrived;
                                }
                            });
                        }

                        ForwardTasksFromResponseCmds(structuredResponse.DecodeEventSuccess);
                    }
                    catch (Exception parseException)
                    {
                        throw new Exception(
                            "Failed to parse event response from app. Looks like the loaded elm app is not compatible with the interface.\nResponse from app follows:\n" + serializedResponse,
                            parseException);
                    }
                }
                catch (Exception) when (applicationStoppingCancellationTokenSource.IsCancellationRequested)
                {
                    return;
                }
            });

            return (serializedInterfaceEvent, processEvent);
        }

        void PerformProcessTaskAndFeedbackEvent(InterfaceToHost.StartTask taskWithId)
        {
            var taskResult = PerformProcessTask(taskWithId.task);

            var interfaceEvent = new InterfaceToHost.AppEventStructure
            {
                TaskCompleteEvent = new InterfaceToHost.ResultFromTaskWithId
                (
                    taskId: taskWithId.taskId,
                    taskResult: taskResult
                )
            };

            ProcessEventAndResultingRequests(interfaceEvent);
        }

        void ProcessEventAndResultingRequests(InterfaceToHost.AppEventStructure interfaceEvent)
        {
            var prepareProcessEvent = PrepareProcessEventAndResultingRequests(interfaceEvent);

            prepareProcessEvent.processEventAndResultingRequests();
        }

        void ForwardTasksFromResponseCmds(InterfaceToHost.AppEventResponseStructure response)
        {
            foreach (var startTask in response.startTasks)
            {
                System.Threading.Tasks.Task.Run(() => PerformProcessTaskAndFeedbackEvent(startTask), applicationStoppingCancellationTokenSource.Token);
            }

            foreach (var completeHttpResponse in response.completeHttpResponses)
            {
                appTaskCompleteHttpResponse[completeHttpResponse.httpRequestId] = completeHttpResponse.response;
            }
        }

        InterfaceToHost.TaskResult PerformProcessTask(InterfaceToHost.Task task)
        {
            var createVolatileProcess = task?.CreateVolatileProcess;
            var requestToVolatileProcess = task?.RequestToVolatileProcess;
            var terminateVolatileProcess = task?.TerminateVolatileProcess;

            if (createVolatileProcess != null)
            {
                try
                {
                    var volatileProcess = new VolatileProcess(GetBlobWithSHA256, createVolatileProcess.programCode);

                    var volatileProcessId = System.Threading.Interlocked.Increment(ref createVolatileProcessAttempts).ToString();

                    volatileProcesses[volatileProcessId] = volatileProcess;

                    var completeStructure = new InterfaceToHost.CreateVolatileProcessComplete
                    (
                        processId: volatileProcessId
                    );

                    return new InterfaceToHost.TaskResult
                    {
                        CreateVolatileProcessResponse = new InterfaceToHost.Result<InterfaceToHost.CreateVolatileProcessErrorStructure, InterfaceToHost.CreateVolatileProcessComplete>
                        {
                            Ok = completeStructure,
                        },
                    };
                }
                catch (Exception createVolatileProcessException)
                {
                    return new InterfaceToHost.TaskResult
                    (
                        CreateVolatileProcessResponse:
                        new InterfaceToHost.Result<InterfaceToHost.CreateVolatileProcessErrorStructure, InterfaceToHost.CreateVolatileProcessComplete>
                        {
                            Err = new InterfaceToHost.CreateVolatileProcessErrorStructure
                            (
                                exceptionToString: createVolatileProcessException.ToString()
                            ),
                        }
                    );
                }
            }

            if (terminateVolatileProcess != null)
            {
                volatileProcesses.TryRemove(terminateVolatileProcess.processId, out var volatileProcess);

                return new InterfaceToHost.TaskResult
                {
                    CompleteWithoutResult = new object(),
                };
            }

            if (requestToVolatileProcess != null)
            {
                var response = PerformProcessTaskRequestToVolatileProcess(requestToVolatileProcess);

                return new InterfaceToHost.TaskResult
                {
                    RequestToVolatileProcessResponse = response,
                };
            }

            throw new NotImplementedException("Unexpected task structure.");
        }

        byte[]? GetBlobWithSHA256(byte[] sha256)
        {
            var matchFromSourceComposition =
                webAppAndElmAppConfig?.SourceComposition == null ? null :
                Composition.FindComponentByHash(webAppAndElmAppConfig.SourceComposition, sha256);

            if (matchFromSourceComposition != null)
            {
                if (matchFromSourceComposition.BlobContent == null)
                    throw new Exception(CommonConversion.StringBase16FromByteArray(sha256) + " is not a blob");

                return matchFromSourceComposition.BlobContent.ToArray();
            }

            return BlobLibrary.GetBlobWithSHA256(sha256);
        }

        InterfaceToHost.Result<InterfaceToHost.RequestToVolatileProcessError, InterfaceToHost.RequestToVolatileProcessComplete>
            PerformProcessTaskRequestToVolatileProcess(
            InterfaceToHost.RequestToVolatileProcessStruct requestToVolatileProcess)
        {
            if (!volatileProcesses.TryGetValue(requestToVolatileProcess.processId, out var volatileProcess))
            {
                return new InterfaceToHost.Result<InterfaceToHost.RequestToVolatileProcessError, InterfaceToHost.RequestToVolatileProcessComplete>
                (
                    Err: new InterfaceToHost.RequestToVolatileProcessError
                    (
                        ProcessNotFound: new object()
                    )
                );
            }

            var stopwatch = System.Diagnostics.Stopwatch.StartNew();

            var fromVolatileProcessResult = volatileProcess.ProcessRequest(requestToVolatileProcess.request);

            stopwatch.Stop();

            return new InterfaceToHost.Result<InterfaceToHost.RequestToVolatileProcessError, InterfaceToHost.RequestToVolatileProcessComplete>
            {
                Ok = new InterfaceToHost.RequestToVolatileProcessComplete
                (
                    exceptionToString: fromVolatileProcessResult.Exception?.ToString(),
                    returnValueToString: fromVolatileProcessResult.ReturnValue?.ToString(),
                    durationInMilliseconds: stopwatch.ElapsedMilliseconds
                )
            };
        }
    }

    static async System.Threading.Tasks.Task<InterfaceToHost.HttpRequestEvent> AsPersistentProcessInterfaceHttpRequestEvent(
        HttpContext httpContext,
        string httpRequestId,
        DateTimeOffset time)
    {
        return new InterfaceToHost.HttpRequestEvent
        (
            posixTimeMilli: time.ToUnixTimeMilliseconds(),
            httpRequestId: httpRequestId,
            requestContext: new InterfaceToHost.HttpRequestContext
            (
                clientAddress: httpContext.Connection.RemoteIpAddress?.ToString()
            ),

            request: await Asp.AsPersistentProcessInterfaceHttpRequest(httpContext.Request)
        );
    }
}

public record WebAppAndElmAppConfig(
    WebAppConfigurationJsonStructure? WebAppConfiguration,
    Func<string, string> ProcessEventInElmApp,
    Composition.Component SourceComposition,
    InterfaceToHost.AppEventResponseStructure? InitOrMigrateCmds);
