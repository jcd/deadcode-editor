module builtin_commands;

import deadcode.api;
mixin registerCommands;

void logInfo(ILog log, string message)
{
    log.info(message);
}

void extBuild(IApplication app, string extName)
{
    app.buildExtension(extName);
}

void extLoad(IApplication app, string extName)
{
    app.loadExtension(extName);
}

void extUnload(IApplication app, string extName)
{
    app.unloadExtension(extName);
}

void extScan(IApplication app, bool onlyChanged = true)
{
    app.scanExtensions(onlyChanged);
}

void cmdFind(IApplication app, string pattern)
{
    auto c = app.findCommands(pattern);
    app.log.info(c);
}
