module bufferviewgroup;

import std.algorithm;
import std.exception : enforce;
import std.range;

import deadcode.core.signals;
import deadcode.edit.bufferview : BufferView;

class BufferViewGroup
{
    private
    {
        int[] _bufferViews;
        int _currentIndex;
    }

    // (bufferViewID, index in group)
    mixin Signal!(int, int) onBufferViewAdded;
    mixin Signal!(int, int) onBufferViewRemoved;

    int opIndex(int i) const pure @safe 
    {
        return _bufferViews[i];
    }

    int indexOfBufferViewID(int id) const pure @safe nothrow
    {
        return _bufferViews.countUntil(id);
    }

    @property int size() const pure @safe nothrow { return _bufferViews.length; }

    @property int currentIndex() const pure @safe nothrow 
    { 
        return _currentIndex;
    }
    
    @property void currentIndex(int i) pure @safe nothrow
    {
        _currentIndex = i;
    }
    
    @property int currentBufferViewID() const pure @safe nothrow 
    { 
        if (_bufferViews.empty)
            return BufferView.invalidID;
        return _bufferViews[_currentIndex];
    }

    void add(int bufferViewID)
    {
        _bufferViews ~= bufferViewID;
        onBufferViewAdded.emit(bufferViewID, _bufferViews.length - 1);
    }
}

class BufferViewGroups
{
    private
    {
        BufferViewGroup[] _bufferViewGroups;
        int _currentIndex;
    }

    mixin Signal!(BufferViewGroup) onGroupAdded;
    mixin Signal!(BufferViewGroup) onGroupRemoved;

    this()
    {
        _bufferViewGroups ~= new BufferViewGroup();
    }

    int opApply(scope int delegate(ref BufferViewGroup) dg)
    {
        int result = 0;

        for (int i = 0; i < _bufferViewGroups.length; i++)
        {
            result = dg(_bufferViewGroups[i]);
            if (result)
                break;
        }
        return result;
    }    

    @property int currentIndex() const pure @safe nothrow 
    { 
        return _currentIndex;
    }

    @property void currentIndex(int i) pure @safe 
    {
        enforce(_bufferViewGroups.length > i && i >= 0);
        _currentIndex = i;
    }

    @property inout(BufferViewGroup) currentBufferViewGroup() inout pure @safe nothrow
    {
        return _bufferViewGroups[_currentIndex];
    }

    // current groups current bufferview id
    @property int currentBufferViewID() const pure @safe nothrow 
    { 
        return currentBufferViewGroup.currentBufferViewID;
    }

    @property void currentBufferViewID(int id) pure @safe nothrow 
    {
        foreach (idx, g; _bufferViewGroups)
        {
            auto bvIdx = g.indexOfBufferViewID(id);
            if (bvIdx != -1)
            {
                _currentIndex = idx;
                g.currentIndex = bvIdx;
                break;
            }
        }
    }

}
