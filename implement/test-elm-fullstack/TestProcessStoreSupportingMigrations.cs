﻿using ElmFullstack.WebHost.ProcessStoreSupportingMigrations;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Pine;
using System.Collections.Immutable;
using System.Linq;

namespace test_elm_fullstack;

[TestClass]
public class TestProcessStoreSupportingMigrations
{
    [TestMethod]
    public void Test_ProjectFileStoreReaderForAppendedCompositionLogEvent()
    {
        var compositionLogEvent = new CompositionLogRecordInFile.CompositionEvent
        {
            DeployAppConfigAndMigrateElmAppState =
            new ValueInFileStructure { LiteralStringUtf8 = "Actually not a valid value for an app config" }
        };

        var projectionResult = IProcessStoreReader.ProjectFileStoreReaderForAppendedCompositionLogEvent(
            originalFileStore: new EmptyFileStoreReader(),
            compositionLogEvent: compositionLogEvent);

        var processStoreReader = new ProcessStoreReaderInFileStore(projectionResult.projectedReader);

        var compositionLogRecords =
            processStoreReader.EnumerateSerializedCompositionLogRecordsReverse().ToImmutableList();

        Assert.IsTrue(compositionLogRecords.Any());
    }
}
