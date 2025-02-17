using System.Collections.Immutable;
using System.Net;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace test_elm_fullstack;

[TestClass]
public class TestExampleApps
{
    [TestMethod]
    public void Example_app_minimal_backend_hello_world()
    {
        var webAppSource =
            TestSetup.AppConfigComponentFromFiles(
                TestSetup.GetElmAppFromDirectoryPath(
                    ImmutableList.Create(".", "..", "..", "..", "..", "example-apps", "minimal-backend-hello-world")));

        using var testSetup = WebHostAdminInterfaceTestSetup.Setup(deployAppConfigAndInitElmState: webAppSource);
        using var server = testSetup.StartWebHost();
        using var publicAppClient = testSetup.BuildPublicAppHttpClient();

        var httpResponse =
            publicAppClient.GetAsync("").Result;

        var responseContentAsString =
            httpResponse.Content.ReadAsStringAsync().Result;

        Assert.AreEqual(
            HttpStatusCode.OK,
            httpResponse.StatusCode,
            "Response status code should be OK.\nresponseContentAsString:\n" + responseContentAsString);

        Assert.AreEqual(
            "Hello, World!",
            responseContentAsString,
            "response content as string");
    }
}
