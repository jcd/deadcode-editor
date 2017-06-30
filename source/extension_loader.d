module extension_loader;

import std.algorithm;
import std.array;
import std.datetime;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.string;
import std.concurrency;

import deadcode.core.eventsource;
import deadcode.core.log : LogLevel;
import deadcode.io.iomanager;
import deadcode.io.file;
import deadcode.util.process;

import deadcode_events : ExtensionBuildFinishedEvent, ExtensionInfo, ExtensionPresenceEvent, DeadcodeEvents, LogEvent;

import deadcode.test;

/** 
*/
class ExtensionManager(EventSink = MainEventSource.OutputRange)
{
    private
    {
        Tid _workerTid;

        EventSink _eventSink;        
        // Use protocols instead of direct file system access.
        // This makes it possible to get extension sources from e.g. github but save
        // executables locally. Also makes it easier to use a mock protocol for testing.
        FileProtocol _sourceProtocol;
        FileProtocol _execProtocol;
        string _extensionsSourcesFolder;
        string _extensionsExecutablesFolder;
        
        enum Request
        {
            stopWorker,
            scanFoldersForAllExtensions,
            scanFoldersForChangedExtensions,
            buildExtensions,
            loadExtensions,
            unloadExtensions,
        }
    }

    this(EventSink eventSink, FileManager filemgr, string extensionsSourcesFolder, string extensionsExecutablesFolder)
    {
        _eventSink = eventSink;
        _extensionsSourcesFolder = extensionsSourcesFolder;
        _extensionsExecutablesFolder = extensionsExecutablesFolder;
        _sourceProtocol = filemgr.getProtocol(extensionsSourcesFolder);
        _execProtocol = filemgr.getProtocol(extensionsExecutablesFolder);
    }

    Tid startWorkerThread()
    {
        enforce(_workerTid == Tid.init);
        _workerTid = spawn(&runWorker, _eventSink, cast(shared)_sourceProtocol, cast(shared) _execProtocol, _extensionsSourcesFolder, _extensionsExecutablesFolder);
        return _workerTid;
    }

    void stopWorkerThread()
    {
        if (_workerTid != Tid.init)
            _workerTid.send(Request.stopWorker);
    }

    void beginScanForAllExtensions()
    {
        enforce(_workerTid != Tid.init);
        _workerTid.send(Request.scanFoldersForAllExtensions);
    }

    void beginScanForChangedExtensions()
    {
        enforce(_workerTid != Tid.init);
        _workerTid.send(Request.scanFoldersForChangedExtensions);
    }

    void buildExtensions(immutable(string)[] names)
    {
        enforce(_workerTid != Tid.init);
        _workerTid.send(Request.buildExtensions);
        _workerTid.send(names);
    }

    void loadExtensions(immutable(string)[] names)
    {
        enforce(_workerTid != Tid.init);
        _workerTid.send(Request.loadExtensions);
        _workerTid.send(names);
    }

    void unloadExtensions(immutable(string)[] names)
    {
        enforce(_workerTid != Tid.init);
        _workerTid.send(Request.unloadExtensions);
        _workerTid.send(names);
    }

    private static void runWorker(EventSink eventSink, shared(FileProtocol) sourceProto, shared(FileProtocol) execProto, string extensionsSourcesFolder, string extensionsExecutablesFolder)
    {
        auto worker = ExtensionManagerWorker!EventSink(eventSink, cast(FileProtocol) sourceProto, cast(FileProtocol) execProto, extensionsSourcesFolder, extensionsExecutablesFolder);
        
        bool running = true;
        while (running)
        {
            auto req = receiveOnly!Request; 
            final switch (req)
            {
                case Request.stopWorker:
                    running = false;
                    break;
                case Request.scanFoldersForAllExtensions:
                    worker.extensions.length = 0;
                    assumeSafeAppend(worker.extensions);
                    goto case Request.scanFoldersForChangedExtensions;
                case Request.scanFoldersForChangedExtensions:
                    immutable(ExtensionInfo)[] modifiedExtensions;
                    immutable(ExtensionInfo)[] addedExtensions;
                    immutable(ExtensionInfo)[] removedExtensions;
                    auto foundExtensions = worker.scanForExtensions();
                    worker.categorizeChangedExtensions(foundExtensions, modifiedExtensions, addedExtensions, removedExtensions);
                    auto ev = DeadcodeEvents.create!ExtensionPresenceEvent(modifiedExtensions, addedExtensions, removedExtensions);
                    eventSink.put(ev);
                    break;
                case Request.buildExtensions:
                    auto names = receiveOnly!(immutable(string)[]);
                    string[] n;
                    n.length = names.length;
                    n[] = names[];
                    worker.buildExtensions(n);
                    break;
                case Request.loadExtensions:
                    auto names = receiveOnly!(immutable(string)[]);
                    string[] n;
                    n.length = names.length;
                    n[] = names[];
                    worker.loadExtensions(n);
                    break;
                case Request.unloadExtensions:
                    auto names = receiveOnly!(immutable(string)[]);
                    string[] n;
                    n.length = names.length;
                    n[] = names[];
                    worker.unloadExtensions(n);
                    break;
            }
        }
    }
}

private struct ExtensionManagerWorker(EventSink = MainEventSource.OutputRange)
{
    EventSink eventSink;

    // Use protocols instead of direct file system access.
    // This makes it possible to get extension sources from e.g. github but save
    // executables locally. Also makes it easier to use a mock protocol for testing.
    FileProtocol sourceProtocol;
    FileProtocol execProtocol;
    string extensionsSourcesFolder;
    string extensionsExecutablesFolder;
    
    ExtensionInfo[] extensions;

    private struct LoadedExtension
    {
        string name;
        string binaryPath;
        Pid pid;
        File logFile;
    }
    
    LoadedExtension[string] loadedExtensions;


    void scanForSources(ref ExtensionInfo[string] result)
    {
        if (!sourceProtocol.exists(new URI(extensionsSourcesFolder)) || !sourceProtocol.isDir(new URI(extensionsSourcesFolder)))
            return;
        
        auto files = sourceProtocol.enumerate(new URI(extensionsSourcesFolder), "*.d", true);
        foreach (f; files)
        {
            auto extensionName = f.path.baseName.stripExtension;
            auto entry = extensionName in result;
            if (entry is null)
            {
                result[extensionName] = ExtensionInfo(extensionName, true, f.path, f.lastModifiedTime); 
            }
            else
            {
                entry.sourcePath = f.path;
                entry.sourceLastModified = f.lastModifiedTime;
            }
        }
    }

    void scanForExecutables(ref ExtensionInfo[string] result)
    {
        if (!execProtocol.exists(new URI(extensionsExecutablesFolder)) || !execProtocol.isDir(new URI(extensionsExecutablesFolder)))
            return;

        auto files = execProtocol.enumerate(new URI(extensionsExecutablesFolder), "*.exe", true);
        foreach (f; files)
        {
            auto extensionName = f.path.stripExtension;
            bool enabled = extensionName.extension != "disabled";
            if (!enabled)
                extensionName = extensionName.stripExtension;
            extensionName = extensionName.baseName();

            auto entry = extensionName in result;
            if (entry is null)
            {
                result[extensionName] = ExtensionInfo(extensionName, enabled, null, SysTime.init, f.path, f.lastModifiedTime); 
            }
            else
            {
                entry.isEnabled = enabled;
                entry.binaryPath = f.path;
                entry.binaryLastModified = f.lastModifiedTime;
            }
        }
    }

    ExtensionInfo[] scanForExtensions()
    {
        ExtensionInfo[string] e;
        scanForSources(e);
        scanForExecutables(e);
        return e.values;
    }

    void categorizeChangedExtensions(ExtensionInfo[] foundExtensions, ref immutable(ExtensionInfo)[] modifiedExtensions, ref immutable(ExtensionInfo)[] addedExtensions, ref immutable(ExtensionInfo)[] removedExtensions)
    {
        struct Helper
        {
            bool isKnown;
            ExtensionInfo info;
        }

        auto foundExts = foundExtensions
            .map!(a => Helper(false, a))
            .array
            .sort!"a.info.name < b.info.name";
        
        auto knownExts = extensions.map!(a => Helper(true, a));

        auto merged = merge!"a.info.name < b.info.name"(knownExts, foundExts);
        auto groups = merged.chunkBy!"a.info.name";
        
        ExtensionInfo[] allExtensions;

        foreach (gTuple; groups)
        {
            auto g = gTuple[1];
            auto a = g.front;
            if (g.count == 1)
            {
                if (!a.isKnown)
                {
                    allExtensions ~= a.info;
                    addedExtensions ~= a.info;
                }
                else
                {
                    removedExtensions ~= a.info;
                }
            }
            else
            {
                g.popFront;
                auto b = g.front;
                b.info.sourceLastModifiedForLastFailedBuild = 
                    a.info.sourceLastModifiedForLastFailedBuild > b.info.sourceLastModifiedForLastFailedBuild ? 
                    a.info.sourceLastModifiedForLastFailedBuild : b.info.sourceLastModifiedForLastFailedBuild;
                allExtensions ~= b.info;
                if (b.info.needsRebuild || a.info.binaryLastModified != b.info.binaryLastModified)
                    modifiedExtensions ~= b.info;
            }
        }

        extensions.length = allExtensions.length;
        assumeSafeAppend(extensions);
        extensions[] = allExtensions[];
    }

    void loadExtensions(string[] names)
    {
        foreach (n; names)
        {
            auto idx = lookup(n);
            if (idx == -1)
                log(LogLevel.error, "Cannot load unknown extensions " ~ n);
            else if (extensions[idx].needsRebuild)
                log(LogLevel.error, "Cannot load extension because it needs rebuild: " ~ n);
            else if (n in loadedExtensions)
                log(LogLevel.error, "Cannot load extension because it is already running: " ~ n);
            else
                loadExtension(n, extensions[idx].binaryPath, ".");
        }
    }

    void loadExtension(string name, string binPath, string workDir)
    {
        import std.path;
        auto info = deadcode.util.process.spawnProcess([buildNormalizedPath(binPath)], name.setExtension("log"));
        loadedExtensions[name] = LoadedExtension(name, binPath, info[0], info[1]);
        log(LogLevel.info, "Loaded extension " ~ name);
    }

    void unloadExtensions(string[] names)
    {
        foreach (n; names)
        {
            auto e = n in loadedExtensions;
            if (e is null)
                log(LogLevel.error, "Cannot unload unknown extensions " ~ n);
            else
            {
                log(LogLevel.info, "Begin unloading extension " ~ n);
                kill(e.pid);
                wait(e.pid);
                log(LogLevel.info, "Done unloading extension " ~ n);
                loadedExtensions.remove(n);
            }            
        }
    }

    void log(LogLevel l, string msg)
    {
        auto ev = DeadcodeEvents.create!LogEvent(l, msg);
        eventSink.put(ev);
    }

    private int lookup(string name)
    {
        // TODO: the array is already sorted so optimize using assueSorted
        return extensions.countUntil!(a => a.name == name);
    }

    void buildExtensions(string[] names)
    {
        string workDir = ".";
        string dubExecutablePath = "dub";

        foreach (n; names)
        {
            auto idx = lookup(n);
            if (idx == -1)
            {
                log(LogLevel.error, "Cannot build unknown extensions " ~ n);
                continue;
            }

            ExtensionInfo* i = &extensions[idx];

            auto result = buildExtension(i.sourcePath, workDir, dubExecutablePath);
            if (result.exitCode == 0)
            {
                auto binaryPath = buildPath(extensionsExecutablesFolder, n).setExtension("exe").chompPrefix("file:");
                //string binaryPath = copyToExecFolder(n, result.resultBinary);
                //if (binaryPath !is null)
                //    i.binaryPath = binaryPath;
                //else
                //    result.exitCode = -1;
            }
            else
            {
                extensions[idx].sourceLastModifiedForLastFailedBuild = i.sourceLastModified;
                log(LogLevel.error, "Error building " ~ i.sourcePath);
            }
            auto ev = DeadcodeEvents.create!ExtensionBuildFinishedEvent(n, result.exitCode, i.binaryPath);
            eventSink.put(ev);
        }
    }

    private string copyToExecFolder(string name, string buildBinaryPath)
    {
        auto target = buildPath(extensionsExecutablesFolder, name).setExtension("exe").chompPrefix("file:");
        try
        {
            copy(buildBinaryPath, target, Yes.preserveAttributes);
            log(LogLevel.info, "Placed build extension at " ~ target);
        }
        catch (FileException e)
        {
            log(LogLevel.error, "Exception when copying final binary " ~ buildBinaryPath ~ ": " ~ e.toString());
            target = null;
        }
        return target;
    }

    auto buildExtension(string sourcePath, string workdir, string dubExecutablePath)
    {
        struct BuildResult
        {
            int exitCode = -1;
            string resultBinary;
        }

        BuildResult result;

        string cmd = dubExecutablePath ~ " build -v --single \"" ~ sourcePath ~ "\" --root=\"" ~ workdir ~ "\"";

        log(LogLevel.info, cmd);
        auto pipes = pipeShell(cmd, Redirect.stdout | Redirect.stderr, null, Config.suppressConsole);
        string binaryPath;

        static void parseTargetPath(string msg, ref string resultPath)
        {
            import std.regex;
            enum re = ctRegex!(r"Copying target from (.+?) to .+");
            auto res = matchFirst(msg, re);
            if (!res.empty)
                resultPath = res[1].idup;
        }

        foreach (line; pipes.stderr.byLine)
        {
            string l = line.idup;
            parseTargetPath(l, binaryPath);
            log(LogLevel.error, l);
        }

        foreach (line; pipes.stdout.byLine)
        {
            string l = line.idup;
            parseTargetPath(l, binaryPath);
            log(LogLevel.info, l);
        }

        int exitCode = wait(pipes.pid);
        result.exitCode = exitCode;
        result.resultBinary = binaryPath;
        return result;
    }
}

version (unittest)
{
    import deadcode.core.event;
    import deadcode.io.mock;

    class MockEventSink
    {
        import core.atomic;

        private int _expectedEvents;
        private int _receivedEvents;
        private void function(shared(MockEventSink)) _onDoneDlg;

        shared this(int expectedEvents, void function(shared(MockEventSink)) onDoneDlg)
        {
            _onDoneDlg = onDoneDlg;
            _expectedEvents = expectedEvents;
        }

        void put(Event e) shared
        {
            if (_expectedEvents == _receivedEvents)
                return;

            if (cast(LogEvent)e is null)
                atomicOp!"+="(_receivedEvents, 1);

            auto ev = cast(ExtensionPresenceEvent) e;
            if (ev !is null)
            {
                atomicOp!"+="(numModified, ev.modified.length);
                atomicOp!"+="(numAdded, ev.added.length);
                atomicOp!"+="(numRemoved, ev.removed.length);
            }

            auto ev2 = cast(ExtensionBuildFinishedEvent) e;
            if (ev2 !is null)
            {
                buildBinaries ~= ev2.binaryPath;
            }

            if (_expectedEvents == _receivedEvents)
                _onDoneDlg(this);
        }
        int numModified;
        int numAdded;
        int numRemoved;
        string[] buildBinaries;
    }
}

version(none)
{
unittest
{
    auto mockSink = new shared MockEventSink(1, (shared(MockEventSink) sink) {
        Assert(0, sink.numModified);
        Assert(0, sink.numAdded);
        Assert(0, sink.numRemoved);
    });

    auto testFileMgr = new FileManager();
    auto mockFileProtocol = new MockFileProtocol();
    mockFileProtocol.existsCallback = (URI url) { return false; };
    testFileMgr.add(mockFileProtocol);

    auto source = new ExtensionManager!(shared MockEventSink)(mockSink, testFileMgr, "mock://test/does_not_exist", "mock://test/does_not_exist");
    source.startWorkerThread();
    source.beginScanForAllExtensions();
}

unittest
{
    auto mockSink = new shared MockEventSink(1, (shared(MockEventSink) sink) {
        Assert(0, sink.numModified);
        Assert(2, sink.numAdded);
        Assert(0, sink.numRemoved);
    });

    auto testFileMgr = new FileManager();
    auto mockFileProtocol = new MockFileProtocol();
    mockFileProtocol.dirMockEntries["mock:"] = [ FileEntry("mock:ext1.d"), FileEntry("mock:ext2.d"), FileEntry("mock:ext1.exec") ];
    testFileMgr.add(mockFileProtocol);

    auto source = new ExtensionManager!(shared MockEventSink)(mockSink, testFileMgr, "mock:", "mock:");
    source.startWorkerThread();
    source.beginScanForAllExtensions();
}


unittest
{
    auto mockSink = new shared MockEventSink(2, (shared(MockEventSink) sink) {
        Assert(1, sink.numModified);
        Assert(2, sink.numAdded);
        Assert(1, sink.numRemoved);
    });

    auto testFileMgr = new FileManager();
    auto mockFileProtocol = new MockFileProtocol();
    mockFileProtocol.dirMockEntries["mock:"] = [ FileEntry("mock:ext1.d"), FileEntry("mock:ext2.d"), FileEntry("mock:ext1.exec") ];
    testFileMgr.add(mockFileProtocol);

    auto source = new ExtensionManager!(shared MockEventSink)(mockSink, testFileMgr, "mock:", "mock:");
    source.startWorkerThread();
    source.beginScanForAllExtensions();
    
    import core.thread;
    Thread.sleep(dur!"msecs"(100)); // brittle!

    mockFileProtocol.dirMockEntries["mock:"] = [ FileEntry("mock:ext1.d", SysTime.init, Clock.currTime)];
    source.beginScanForChangedExtensions();
}
}

// Integration test (uses filesystem)
version (none)
unittest
{
    auto mockSink = new shared MockEventSink(2, (shared(MockEventSink) sink) {
        Assert(1, sink.numAdded);
    });

    auto testFileMgr = new FileManager();
    auto localFileProtocol = new LocalFileProtocol();
    testFileMgr.add(localFileProtocol);

    auto source = new ExtensionManager!(shared MockEventSink)(mockSink, testFileMgr, "file:test/extension_manager/case1", "file:test/extension_manager/case1");
    source.startWorkerThread();
    source.beginScanForAllExtensions();

    import core.thread;
    Thread.sleep(dur!"msecs"(100)); // brittle!

    source.buildExtensions(["ext1"]);
}

//void loadExtensions(Tid owner, string extensionsFolder, string workDir, string dubExecutablePath)
//{
//    auto files = dirEntries(extensionsFolder, SpanMode.breadth).filter!(f => f.name.endsWith(".d"));
//    foreach (f; files)
//    {
//        loadExtension(owner, f.name, workDir, dubExecutablePath);
//    }
//}
//
//void loadExtensions(Tid owner, string extensionPath, string workDir, string dubExecutablePath)
//{
//    auto binPath = extensionPath.setExtension(".dcx");
//    bool buildBinary = true;
//    if (exists(binPath))
//    {
//        SysTime[2] sourceTimes;
//        SysTime[2] binaryTimes;
//        getTimes(extensionPath, sourceTimes[0], sourceTimes[1]); 
//        getTimes(extensionPath, binaryTimes[0], binaryTimes[1]); 
//        buildBinary = sourceTimes[1] >= binaryTimes[1];
//    }
//    
//    if (buildBinary)
//    {
//        string cmd = dubExecutablePath ~ " build -v --single " ~ extensionPath;
//
//        auto pipes = pipeShell(cmd, Redirect.stdout | Redirect.stderr, null, Config.suppressConsole);
//
//        static void parseTargetPath(string msg, ref BuildInfo info)
//        {
//            enum re = ctRegex!(r"Copying target from (.+?) to .+");
//            auto res = matchFirst(msg, re);
//            if (!res.empty)
//                info.binaryPath = res[1].idup;
//        }
//
//        foreach (line; pipes.stderr.byLine)
//        {
//            string l = line.idup;
//            parseTargetPath(l, info);
//            builder.sendLog(pTid, l);
//        }
//
//        foreach (line; pipes.stdout.byLine)
//        {
//            string l = line.idup;
//            parseTargetPath(l, info);
//            builder.sendLog(pTid, l);
//        }
//
//        info.exitCode = wait(pipes.pid);
//        if (info.exitCode == 0)
//        {
//            try
//                copy(info.binaryPath, buildBinary, Yes.preserveAttributes);
//            catch (FileException e)
//                owner.send(e.toString());
//        }
//        else
//        {
//            owner.send(e.toString());
//        }
//    }
//}

//
//private static void build(Tid pTid)
//{
//    string cmd = "dub build -v --build=" ~ status.buildType ~ " --root=\"" ~ status.packageRoot ~ "\"";
//
//    auto pipes = pipeShell(cmd, Redirect.stdout | Redirect.stderr, null, Config.suppressConsole);
//
//    static void parseTargetPath(string msg, ref BuildStatus status)
//    {
//        enum re = ctRegex!(r"Copying target from (.+?) to .+");
//        auto res = matchFirst(msg, re);
//        if (!res.empty)
//            status.target = res[1].idup;
//    }
//
//    foreach (line; pipes.stderr.byLine)
//    {
//        string l = line.idup;
//        parseTargetPath(l, status);
//        builder.sendLog(pTid, l);
//    }
//
//    foreach (line; pipes.stdout.byLine)
//    {
//        string l = line.idup;
//        //			parseTargetPath(l, status);
//        builder.sendLog(pTid, l);
//    }
//
//    status.exitCode = wait(pipes.pid);
//
//    builder.onBuildMessage.emit(format("Build done at %s (exitcode %s)", status.target, status.exitCode), LogLevel.info);
//    builder.onBuildFinished.emit(status);
//
//    // send(pTid, status);
//}
//
