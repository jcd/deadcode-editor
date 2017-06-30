module deadcode_window;

import std.algorithm : find, remove, countUntil;
import std.range;

import deadcode.edit.bufferview : BufferViewManager, BufferView;
import deadcode.graphics.rendertarget;
import deadcode.gui.controls.button;
import deadcode.gui.label;
import deadcode.gui.layouts.directionallayout;
import deadcode.gui.style.types;
import deadcode.gui.style.stylesheet;
import deadcode.gui.widget;
import deadcode.gui.window;

import bufferviewgroup;
import controls.codeeditor;

class CodeEditorGroup : Widget
{
    private
    {
        Widget _paneSelector;
        Widget _paneView;
        BufferViewGroup _bufferViewGroup;     // reference to model stored in DeadcodeApplication
        BufferViewManager _bufferViewManager;
        CodeEditor[] _editors; // bufferViewID => widget
    }

    @property BufferViewGroup bufferViewGroup() { return _bufferViewGroup; }

    this(BufferViewGroup g, BufferViewManager bm)
    {
        _bufferViewGroup = g;
        _bufferViewManager = bm;
        _paneSelector = new Widget(this);
        _paneSelector.name = "pane-selector";
        _paneView = new Widget(this);
        _paneView.name = "pane-view";
        _paneView.styleOverride.position = CSSPosition.relative;
        styleOverride.position = CSSPosition.relative;

        auto dbg = new Label("Lars");
        dbg.parent = _paneView;
        layout = new DirectionalLayout!false();
        //layout = new GridLayout(GridLayout.Direction.column, 1);
        
        foreach (i; 0..g.size)
        {
            insert(g[i], i);
        }

        showBufferWithID(_bufferViewGroup.currentBufferViewID);
    
        g.onBufferViewAdded.connect(&handleBufferViewAdded);
        g.onBufferViewRemoved.connect(&handleBufferViewRemoved);
    }

    void showBufferWithID(int bufferViewID)
    {
        if (bufferViewID == BufferView.invalidID)
            return;

        foreach (c; _paneView.children)
            c.hide();

        auto cei = lookup(bufferViewID);
        if (cei == -1)
        {
            auto bv = _bufferViewManager[bufferViewID];
            auto nce = new CodeEditor(bv);
            _editors ~= nce;
            nce.parent = _paneView;
            cei = _editors.length - 1;
        }

        _editors[cei].show();
    }
    
    void insert(int bufferViewID, int afterThisIndex)
    {
        auto labelText = _bufferViewManager[bufferViewID].name;

        auto paneButton = new Button(labelText);
        paneButton.onActivated.connectTo((Button) {
            auto idx = _bufferViewGroup.indexOfBufferViewID(bufferViewID);
            
        });
        paneButton.name = labelText;
        paneButton.parent = _paneSelector;
        if (_paneSelector.children.length > 1)
            _paneSelector.moveChildAfter(_paneSelector.children.length - 1, afterThisIndex);
    }

    private void paneButtonActivated(Button b)
    {
        
    }

    override void updateLayout(bool fit, Widget positionReference)
    {
        return super.updateLayout(fit, positionReference);
    }
    
    override void draw()
    {
        super.draw();
    }

    private int lookup(int bufferViewID)
    {
        return _editors.countUntil!(e => e.bufferView.id == bufferViewID);
    }

    private void handleBufferViewAdded(int bufferViewID, int indexInGroup)
    {
        insert(bufferViewID, indexInGroup == 0 ? 0 : indexInGroup - 1);
    }

    private void handleBufferViewRemoved(int bufferViewID, int indexInGroup)
    {
        assert(0);
    }
}

class DeadcodeWindow : Window
{
    private
    {
        BufferViewGroups _bufferViewGroups;  // Model of buffers
        BufferViewManager _bufferViewManager;
        CodeEditorGroup[] _codeEditorGroups; // View of buffers
    }
    
    this(const(char)[] _name, int width, int height, RenderTarget _renderTarget, StyleSheet ss)
    {
        super(_name, width, height, _renderTarget, ss);
        //auto n = new Widget(this);
        //n.layout = new VerticalLayout(true, VerticalLayout.Mode.cullChildren);
        //auto l1 = new Label("Foo");
        //l1.parent = n;
        //auto l2 = new Label("Bar");
        //l2.parent = n;
    }

    void setBufferViewGroups(BufferViewGroups gs, BufferViewManager mgr)
    {
        _bufferViewManager = mgr;
        if (_bufferViewGroups !is null)
        {
            _bufferViewGroups.onGroupAdded.disconnect(&handleBufferViewGroupAdded);
            _bufferViewGroups.onGroupRemoved.disconnect(&handleBufferViewGroupRemoved);
        }

        _bufferViewGroups = gs;
        foreach (ceg; _codeEditorGroups)
        {
            ceg.parent = null; // unparent from window
        }
        
        _codeEditorGroups.length = 0;
        assumeSafeAppend(_codeEditorGroups);

        foreach (g; gs)
        {
            handleBufferViewGroupAdded(g);
        }

        _bufferViewGroups.onGroupAdded.connect(&handleBufferViewGroupAdded);
        _bufferViewGroups.onGroupRemoved.connect(&handleBufferViewGroupRemoved);
    }

    private void handleBufferViewGroupAdded(BufferViewGroup g)
    {
        auto newCeg = new CodeEditorGroup(g, _bufferViewManager);
        newCeg.name = "Group";
        newCeg.parent = this;
    }

    private void handleBufferViewGroupRemoved(BufferViewGroup g)
    {
        auto ceg = _codeEditorGroups.find!(e => e.bufferViewGroup is g);
        if (!ceg.empty)
        {
            ceg[0].parent = null;
            _codeEditorGroups.remove!(e => e.bufferViewGroup is g);
        }
    }
}