/+
dub.sdl:
    name "example-extension2"
    dependency "deadcode-rpc" version=">=0.0.0"
    dependency "deadcode-api" version=">=0.0.0"
    version "DeadcodeOutOfProcess"
+/

import deadcode.api;
import deadcode.api.rpcclient;
mixin rpcClient;
mixin registerCommands;

void testHello(IApplication app)
{
    app.log(LogLevel.info, "Hello from test.hello command in app2");
}
