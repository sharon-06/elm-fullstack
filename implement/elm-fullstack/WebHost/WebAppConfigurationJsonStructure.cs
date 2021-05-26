namespace ElmFullstack
{
    public class WebAppConfigurationJsonStructure
    {
        public RateLimitWindow singleRateLimitWindowPerClientIPv4Address;

        public int? httpRequestEventSizeLimit;

        public FluffySpoon.AspNet.LetsEncrypt.Certes.LetsEncryptOptions letsEncryptOptions;

        public class ConditionalMapFromStringToString
        {
            public string matchingRegexPattern;

            public string resultString;
        }

        public class RateLimitWindow
        {
            public int windowSizeInMs;

            public int limit;
        }
    }
}
