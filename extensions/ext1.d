/+
dub.sdl:
    name "ext1"
    dependency "deadcode-rpc" version=">=0.0.0"
    dependency "deadcode-api" version=">=0.0.0"
    versions "DeadcodeOutOfProcess"
+/
import deadcode.api;
mixin registerCommands;

void testHello(ILog log)
{
    log.info("Hello from test.hello command in app %s", 47);
}
