module deadcode_events;

import std.variant;

import deadcode.core.event;
import deadcode.core.log : LogLevel;

class StringCommandEvent : Event
{
	private this() {}
    this(string cmdString)
	{
        commandString = cmdString;
	}

    string commandString;
}

class SocketSelectEvent : Event
{
    import std.socket;
    private this() {}
    this(int res)
    {
        result = res;
    }

    socket_t[4] readable;
    socket_t[4] writable;
    socket_t[4] except;
    int result; // 0 == timeout, -1 == interrupt
}

struct ExtensionInfo
{
    import std.datetime;
    import std.range;

    string name;
    bool isEnabled;
    string sourcePath;
    SysTime sourceLastModified;
    string binaryPath;
    SysTime binaryLastModified;
    SysTime sourceLastModifiedForLastFailedBuild;

    @property canCompile() const pure @safe nothrow { return !sourcePath.empty; }
    @property hasBinary() const pure @safe nothrow { return !binaryPath.empty; }
    @property sourceIsDirty() const pure @safe nothrow { return sourceLastModified > binaryLastModified; }
    @property currentBuildFails() const pure @safe nothrow {  return sourceLastModified == sourceLastModifiedForLastFailedBuild;}

    @property bool needsRebuild() const pure @safe nothrow 
    {
        return isEnabled && canCompile && (sourceIsDirty || !hasBinary) && !currentBuildFails;
    }
}

class ExtensionPresenceEvent : Event
{
    private this() {}
    this(immutable(ExtensionInfo)[] m, immutable(ExtensionInfo)[] a, immutable(ExtensionInfo)[] r)
    {
        modified = m;
        added = a;
        removed = r;
    }
    
    immutable(ExtensionInfo)[] modified;
    immutable(ExtensionInfo)[] added;
    immutable(ExtensionInfo)[] removed;
}

class ExtensionBuildFinishedEvent : Event
{
    private this() {}
    this(string n, int exitcde, string binPath)
    {
        name = n;
        exitCode = exitcde;
        binaryPath = binPath;
    }

    string name;
    int exitCode;
    string binaryPath;
}

class LogEvent : Event
{
    private this() {}
    this(LogLevel l, string msg)
    {
        level = l;
        message = msg;
    }

    LogLevel level;
    string message;
}


mixin registerEvents!"Deadcode";
